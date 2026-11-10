import AppKit
import Carbon.HIToolbox

/// Its own shape, not a caller's result type, so the injector stays owned by no one feature.
struct InjectedText: Equatable, Sendable {
    let text: String
    /// Leaves the caret this many characters back from the end; nil leaves it after the text.
    let cursorOffsetFromEnd: Int?

    init(_ text: String, cursorOffsetFromEnd: Int? = nil) {
        self.text = text
        self.cursorOffsetFromEnd = cursorOffsetFromEnd
    }

    /// UTF-16 distance from the start of the inserted text to where the caret should land.
    var caretPrefixLength: Int {
        let offset = min(max(cursorOffsetFromEnd ?? 0, 0), text.count)
        return text[..<text.index(text.endIndex, offsetBy: -offset)].utf16.count
    }
}

enum AccessibilityReplacement: Equatable {
    case delivered
    case unavailable
    case rejected

    /// `.rejected` means the document is not the one we measured, so events would edit the wrong text.
    var fallsBackToEvents: Bool { self == .unavailable }
}

/// The two judgements a replacement makes, kept pure so the harness can drive both tiers.
enum TextReplacementPolicy {
    enum KeywordState: Equatable {
        case matched(NSRange)
        case pending
        case rejected
    }

    /// Too little text yet is a renderer still catching up; enough text but wrong is a real mismatch.
    static func keywordState(
        value: String, selectedRange: NSRange, keyword: String
    ) -> KeywordState {
        guard selectedRange.length == 0,
            let selectedStringRange = Range(selectedRange, in: value)
        else { return .rejected }
        let beforeCursor = value[..<selectedStringRange.lowerBound]
        guard beforeCursor.count >= keyword.count else { return .pending }
        let start = beforeCursor.index(beforeCursor.endIndex, offsetBy: -keyword.count)
        guard beforeCursor[start...].lowercased() == keyword.lowercased() else { return .rejected }
        return .matched(NSRange(start..<beforeCursor.endIndex, in: value))
    }

    /// Chromium answers `.success` and applies nothing, so the value has to read back as we wrote it.
    static func confirmsReplacement(
        originalValue: String,
        replacementRange: NSRange,
        insertedText: String,
        observedValue: String?
    ) -> Bool {
        guard let observedValue,
            let stringRange = Range(replacementRange, in: originalValue)
        else { return false }
        var expected = originalValue
        expected.replaceSubrange(stringRange, with: insertedText)
        return observedValue == expected
    }
}

@MainActor
final class DeliveryCompletion {
    private let onDelivered: @MainActor () -> Void
    private let onFailed: @MainActor () -> Void
    private(set) var isConfirmed = false
    private var isSettled = false

    init(
        onDelivered: @escaping @MainActor () -> Void = {},
        onFailed: @escaping @MainActor () -> Void = {}
    ) {
        self.onDelivered = onDelivered
        self.onFailed = onFailed
    }

    func confirm() {
        guard !isSettled else { return }
        isSettled = true
        isConfirmed = true
        onDelivered()
    }

    /// Driven from a `defer`, so a delivery that returned early still says so instead of vanishing.
    func settle() {
        guard !isSettled else { return }
        isSettled = true
        onFailed()
    }
}

@MainActor
final class TextInjector {
    typealias AutomaticGeneration = UInt

    private let clipboardManager: ClipboardManager
    private let settings: AppSettings
    private let deliveryQueue: DeliveryQueue
    private var automaticGeneration: AutomaticGeneration = 0
    private var activePasteboardLease: TemporaryPasteboardLease?

    init(
        clipboardManager: ClipboardManager, settings: AppSettings,
        deliveryQueue: DeliveryQueue = DeliveryQueue()
    ) {
        self.clipboardManager = clipboardManager
        self.settings = settings
        self.deliveryQueue = deliveryQueue
    }

    /// A paste is still in flight, or we still hold the pasteboard it borrowed.
    var isDelivering: Bool { !deliveryQueue.isIdle || activePasteboardLease != nil }

    func drain() async { await deliveryQueue.drain() }

    func prepareInteractiveExpansion(target: InjectionTarget?) -> Bool {
        if let editor = target?.ownEditor { return editor.isEditable }
        guard targetAcceptsInjection(target?.externalApp), Permissions.ensureAccessibility() else {
            target?.restoreFocus()
            return false
        }
        return true
    }

    func beginAutomaticExpansion(target: InjectionTarget?) -> AutomaticGeneration? {
        cancelAutomaticExpansion()
        guard expansionIsAllowed(generation: automaticGeneration, target: target) else { return nil }
        return automaticGeneration
    }

    func cancelAutomaticExpansion(target: InjectionTarget? = nil) {
        automaticGeneration &+= 1
        deliveryQueue.cancelAutomatic()
        target?.restoreFocus()
    }

    func prepareForTermination() {
        automaticGeneration &+= 1
        deliveryQueue.cancelAll()
        finishPendingPasteboardOwnership()
    }

    func cancelArgumentPrompt(
        automaticGeneration: AutomaticGeneration?,
        target: InjectionTarget?
    ) {
        if automaticGeneration != nil {
            cancelAutomaticExpansion(target: target)
        } else {
            target?.restoreFocus()
        }
    }

    /// A hotkey's target comes from `frontmostApplication`, which can be Tinycast itself.
    private func targetAcceptsInjection(_ targetApp: NSRunningApplication?) -> Bool {
        guard let targetApp,
            !targetApp.isTerminated,
            targetApp.bundleIdentifier != Bundle.main.bundleIdentifier,
            !IsSecureEventInputEnabled()
        else { return false }
        return true
    }

    private func automaticExpansionIsAllowed(
        generation: AutomaticGeneration,
        targetApp: NSRunningApplication?
    ) -> Bool {
        guard generation == automaticGeneration,
            settings.snippetsEnabled,
            Permissions.isAccessibilityTrusted(),
            targetAcceptsInjection(targetApp)
        else { return false }
        return true
    }

    /// In process there is nothing to grant, activate or post: our own view is the whole contract.
    private func expansionIsAllowed(
        generation: AutomaticGeneration,
        target: InjectionTarget?
    ) -> Bool {
        switch target {
        case .ownEditor(let editor):
            return generation == automaticGeneration && settings.snippetsEnabled && editor.isEditable
        case .external(let app):
            return automaticExpansionIsAllowed(generation: generation, targetApp: app)
        case nil:
            return false
        }
    }

    func captureExpansionContext(
        target: InjectionTarget?,
        clipboardHistory: [String]
    ) -> SnippetTemplateEngine.ExpansionContext {
        SnippetTemplateEngine.ExpansionContext(
            clipboardHistory: clipboardHistory,
            selection: selection(in: target),
            now: Date(),
            calendar: Calendar.current,
            locale: Locale.current,
            timeZone: .current)
    }

    /// The caller must know there *is* a selection: a zero-length one inserts at the caret instead.
    func replaceSelection(
        with text: String,
        in targetApp: NSRunningApplication?,
        onDelivered: @escaping @MainActor () -> Void = {},
        onFailed: @escaping @MainActor () -> Void = {}
    ) {
        deliver(
            InjectedText(text), target: targetApp.map(InjectionTarget.external),
            expectedKeyword: nil, keywordLength: 0,
            automaticGeneration: nil, onDelivered: onDelivered, onFailed: onFailed)
    }

    /// Types only `edits` over a selection still reading `original`; the caller awaits the keys.
    func retypeSelection(
        _ original: String, as modified: String, edits: [RetypeEdit],
        in targetApp: NSRunningApplication?
    ) async -> Bool {
        activate(targetApp)
        guard prepareInteractiveExpansion(target: targetApp.map(InjectionTarget.external)) else {
            return false
        }
        let result = RetypeResult()
        let job = deliveryQueue.enqueue(isAutomatic: false) { [weak self] in
            result.delivered =
                await self?.performRetype(
                    original, as: modified, edits: edits, targetApp: targetApp) ?? false
        }
        // The keys run on the queue's task, so the caller's cancellation has to be passed along.
        await withTaskCancellationHandler {
            await deliveryQueue.drain()
        } onCancel: {
            Task { @MainActor [weak self] in self?.deliveryQueue.cancel(job) }
        }
        return result.delivered
    }

    /// A cancelled queue job never runs its operation, so the answer lives outside it.
    private final class RetypeResult {
        var delivered = false
    }

    private enum RetypeOutcome {
        case delivered
        /// Nothing was typed and the selection is where it was, so a plain replace may still run.
        case untouched
        case failed
    }

    private struct RetypeAnchor {
        let element: AXUIElement
        let range: NSRange
    }

    private func performRetype(
        _ original: String, as modified: String, edits: [RetypeEdit],
        targetApp: NSRunningApplication?
    ) async -> Bool {
        guard finishPendingPasteboardOwnership(),
            await activateAndWaitForTarget(targetApp, automaticGeneration: nil),
            deliveryIsAllowed(
                automaticGeneration: nil, targetApp: targetApp,
                promptForInteractiveAccessibility: true),
            let targetApp
        else { return false }

        let outcome: RetypeOutcome
        if let anchor = retypeAnchor(for: original, in: targetApp) {
            outcome =
                RetypeEdit.placedKeystrokes(edits) <= RetypeEdit.maxKeystrokes
                ? await retypeByPlacingCaret(edits, anchor: anchor, targetApp: targetApp)
                : .untouched
        } else {
            switch AccessibilityText.read(in: targetApp) {
            case .text(original):
                outcome =
                    RetypeEdit.walkedKeystrokes(edits) <= RetypeEdit.maxKeystrokes
                    ? await retypeByWalkingCaret(edits, targetApp: targetApp)
                    : .untouched
            case .noFocusedElement:
                outcome = .untouched
            case .text, .empty:
                // A moved or collapsed selection is where a replace would land, so neither runs.
                outcome = .failed
            }
        }

        switch outcome {
        case .delivered: return true
        case .failed: return false
        case .untouched:
            let completion = DeliveryCompletion()
            await performDelivery(
                InjectedText(modified), targetApp: targetApp, expectedKeyword: nil,
                keywordLength: 0, automaticGeneration: nil, completion: completion)
            return completion.isConfirmed
        }
    }

    /// Rule 1: a renderer's selection is written by keys, never set over AX, so it gets no anchor.
    private func retypeAnchor(
        for original: String, in targetApp: NSRunningApplication
    ) -> RetypeAnchor? {
        guard let element = AccessibilityText.focusedElement(in: targetApp),
            !usesTextMarkerSelection(element),
            isAttributeSettable(kAXSelectedTextRangeAttribute, in: element),
            let value = stringValue(in: element),
            let range = selectedRange(in: element),
            let stringRange = Range(range, in: value),
            value[stringRange] == original
        else { return nil }
        return RetypeAnchor(element: element, range: range)
    }

    /// Last edit first, so each placed range still means what it did in the original selection.
    private func retypeByPlacingCaret(
        _ edits: [RetypeEdit], anchor: RetypeAnchor, targetApp: NSRunningApplication
    ) async -> RetypeOutcome {
        var typedAny = false
        for edit in edits.reversed() {
            let range = NSRange(
                location: anchor.range.location + edit.originalUTF16Offset,
                length: edit.deleted.utf16.count)
            guard
                deliveryIsAllowed(
                    automaticGeneration: nil, targetApp: targetApp,
                    promptForInteractiveAccessibility: false),
                setSelectedRange(range, in: anchor.element),
                await retypeConverges(
                    afterKeys: 0, { self.selectedString(in: anchor.element) == edit.deleted })
            else {
                if typedAny { return .failed }
                return setSelectedRange(anchor.range, in: anchor.element) ? .untouched : .failed
            }
            typedAny = true
            guard await typeRetypeEdit(edit, targetApp: targetApp) else { return .failed }
            let caret = NSRange(location: range.location + edit.inserted.utf16.count, length: 0)
            // Typed keys queue behind each other but not behind AX, so the next placement waits.
            guard
                await retypeLanded(
                    at: caret, afterKeys: edit.inserted.count, in: anchor.element)
            else { return .failed }
        }
        return .delivered
    }

    /// A smart quote or autocorrection can change the typed length, so a still caret also lands.
    private func retypeLanded(
        at caret: NSRange, afterKeys keys: Int, in element: AXUIElement
    ) async -> Bool {
        if await retypeConverges(afterKeys: keys, { self.selectedRange(in: element) == caret }) {
            return true
        }
        guard let settled = selectedRange(in: element), settled.length == 0,
            await wait(for: Self.retypeSettleInterval)
        else { return false }
        return selectedRange(in: element) == settled
    }

    /// First edit first: arrows move relative to wherever the last correction left the caret.
    private func retypeByWalkingCaret(
        _ edits: [RetypeEdit], targetApp: NSRunningApplication
    ) async -> RetypeOutcome {
        guard let collapse = makeKeyEvents(code: CGKeyCode(kVK_LeftArrow)),
            await postEventGroups([collapse], targetApp: targetApp, automaticGeneration: nil)
        else { return .untouched }
        for edit in edits {
            guard
                let skip = makeRepeatedKeyEvents(
                    code: CGKeyCode(kVK_RightArrow), count: edit.skippedCharacters),
                await postEventGroups(skip, targetApp: targetApp, automaticGeneration: nil),
                await selectWalkedSpan(edit.deleted, queuedKeys: skip.count, targetApp: targetApp),
                await typeRetypeEdit(edit, targetApp: targetApp)
            else { return .failed }
        }
        return await wait(for: .milliseconds(100)) ? .delivered : .failed
    }

    /// Chromium's AX text drops a paragraph break the caret still stops at, so a miss steps on.
    private static let walkRealignSteps = [1, 1, 1, -4]

    /// Each retry collapses to the last attempt's start and moves one stop before selecting again.
    private func selectWalkedSpan(
        _ span: String, queuedKeys: Int, targetApp: NSRunningApplication
    ) async -> Bool {
        guard
            let select = makeRepeatedKeyEvents(
                code: CGKeyCode(kVK_RightArrow), flags: .maskShift, count: span.count),
            let collapse = makeKeyEvents(code: CGKeyCode(kVK_LeftArrow))
        else { return false }
        let retries = Self.walkRealignSteps.compactMap { step in
            makeRepeatedKeyEvents(
                code: CGKeyCode(step > 0 ? kVK_RightArrow : kVK_LeftArrow), count: abs(step)
            ).map { [collapse] + $0 }
        }
        var queued = queuedKeys
        for move in [[]] + retries {
            guard
                await postEventGroups(
                    move + select, targetApp: targetApp, automaticGeneration: nil)
            else { return false }
            queued += move.count + select.count
            if await retypeConverges(
                afterKeys: queued, { AccessibilityText.selection(in: targetApp) == span })
            {
                return true
            }
            queued = 0
        }
        return false
    }

    /// One character per keystroke, as a keyboard sends them; a pure deletion presses Delete.
    private func typeRetypeEdit(_ edit: RetypeEdit, targetApp: NSRunningApplication) async -> Bool {
        var events: [[CGEvent]] = []
        if edit.inserted.isEmpty {
            guard let delete = makeKeyEvents(code: CGKeyCode(kVK_Delete)) else { return false }
            events = [delete]
        }
        for character in edit.inserted {
            guard let keystrokes = makeUnicodeEvents(String(character)) else { return false }
            events += keystrokes
        }
        return await postEventGroups(events, targetApp: targetApp, automaticGeneration: nil)
    }

    /// A busy editor can still be applying keys already posted, so the wait grows with their count.
    private func retypeConverges(afterKeys keys: Int, _ condition: () -> Bool) async -> Bool {
        let attempts = min(
            Self.retypeConvergenceAttempts + keys * Self.retypeAttemptsPerKey,
            Self.retypeMaximumAttempts)
        for _ in 0..<attempts {
            if condition() { return true }
            guard await wait(for: Self.retypeConvergenceInterval) else { return false }
        }
        return condition()
    }

    /// Slower than keyword convergence: a web renderer answers about a key it just applied late.
    private static let retypeConvergenceAttempts = 40
    private static let retypeAttemptsPerKey = 2
    private static let retypeMaximumAttempts = 400
    private static let retypeConvergenceInterval = Duration.milliseconds(10)
    private static let retypeSettleInterval = Duration.milliseconds(100)

    /// A changed span is selected before it is typed over, so this must read what it covers.
    private func selectedString(in element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                element, kAXSelectedTextAttribute as CFString, &value) == .success
        else { return nil }
        return value as? String
    }

    private func makeRepeatedKeyEvents(
        code: CGKeyCode, flags: CGEventFlags = [], count: Int
    ) -> [[CGEvent]]? {
        var events: [[CGEvent]] = []
        events.reserveCapacity(count)
        for _ in 0..<count {
            guard let pair = makeKeyEvents(code: code, flags: flags) else { return nil }
            events.append(pair)
        }
        return events
    }

    /// A `changeCount` that never moves means nothing was selected, not that the old clipboard won.
    func copySelection(from targetApp: NSRunningApplication?) async -> String? {
        await deliveryQueue.drain()
        guard finishPendingPasteboardOwnership(),
            await activateAndWaitForTarget(targetApp, automaticGeneration: nil),
            deliveryIsAllowed(
                automaticGeneration: nil, targetApp: targetApp,
                promptForInteractiveAccessibility: true)
        else { return nil }
        return await copySelection(from: targetApp, pasteboard: NSPasteboard.general)
    }

    /// Split for the harness, which drives a stub pasteboard rather than another app.
    func copySelection(
        from targetApp: NSRunningApplication?, pasteboard: any PasteboardAccess
    ) async -> String? {
        // A second borrow would snapshot the first's copy and read its restore as a selection.
        guard !isBorrowingCopy, let original = PasteboardSnapshot(pasteboard: pasteboard) else {
            return nil
        }
        isBorrowingCopy = true
        clipboardManager.pauseCapture()
        defer {
            restore(original, to: pasteboard)
            clipboardManager.resumeCapture()
            isBorrowingCopy = false
        }

        Paster.postCommandC(toPid: targetApp?.processIdentifier)
        for _ in 0..<Self.copyPollAttempts {
            guard await wait(for: Self.copyPollInterval) else { return nil }
            guard pasteboard.changeCount != original.changeCount else { continue }
            guard let copied = PasteboardSnapshot(pasteboard: pasteboard),
                let data = copied.firstStringData
            else { return nil }
            return String(bytes: data, encoding: .utf8)
        }
        return nil
    }

    private func restore(_ snapshot: PasteboardSnapshot, to pasteboard: any PasteboardAccess) {
        guard let items = snapshot.pasteboardItems() else { return }
        pasteboard.clearContents()
        guard pasteboard.writeObjects(items) else { return }
        clipboardManager.synchronizeAfterTinycastPasteboardMutation(
            changeCount: pasteboard.changeCount)
    }

    private var isBorrowingCopy = false

    /// A copy lands well inside a second; past that the app was never going to answer.
    private static let copyPollAttempts = 40
    private static let copyPollInterval = Duration.milliseconds(25)

    func deliver(
        _ injected: InjectedText,
        target: InjectionTarget?,
        expectedKeyword: String?,
        keywordLength: Int,
        automaticGeneration: AutomaticGeneration?,
        isValid: @escaping @MainActor () -> Bool = { true },
        onDelivered: @escaping @MainActor () -> Void = {},
        onFailed: @escaping @MainActor () -> Void = {}
    ) {
        let targetApp = target?.externalApp
        activate(targetApp)
        if let automaticGeneration {
            guard expansionIsAllowed(generation: automaticGeneration, target: target) else { return }
        } else {
            guard prepareInteractiveExpansion(target: target) else {
                onFailed()
                return
            }
        }

        deliveryQueue.enqueue(isAutomatic: automaticGeneration != nil) { [weak self] in
            guard let self else { return }
            let completion = DeliveryCompletion(onDelivered: onDelivered, onFailed: onFailed)
            guard isValid() else { completion.settle(); return }
            if let editor = target?.ownEditor {
                await self.deliverInProcess(
                    injected,
                    into: editor,
                    expectedKeyword: expectedKeyword,
                    keywordLength: keywordLength,
                    automaticGeneration: automaticGeneration,
                    isValid: isValid,
                    completion: completion)
                return
            }
            await self.performDelivery(
                injected,
                targetApp: targetApp,
                expectedKeyword: expectedKeyword,
                keywordLength: keywordLength,
                automaticGeneration: automaticGeneration,
                completion: completion)
        }
    }

    /// Needs no grant, activation or pasteboard, but the keyword still converges on Rule 2.
    private func deliverInProcess(
        _ injected: InjectedText,
        into editor: any InjectableTextView,
        expectedKeyword: String?,
        keywordLength: Int,
        automaticGeneration: AutomaticGeneration?,
        isValid: @MainActor () -> Bool,
        completion: DeliveryCompletion
    ) async {
        defer { completion.settle() }
        for _ in 0..<Self.convergenceAttempts {
            // The tap runs ahead of AppKit, so looking before the wait reads a stale view as a miss.
            if keywordLength > 0 {
                guard await wait(for: Self.convergenceInterval) else { return }
            }
            guard isValid(),
                inProcessDeliveryIsAllowed(automaticGeneration: automaticGeneration, editor: editor)
            else { return }
            switch editor.keywordReplacementState(
                expectedKeyword: expectedKeyword, keywordLength: keywordLength)
            {
            case .matched(let range):
                editor.inject(injected, over: range)
                completion.confirm()
                return
            case .rejected:
                return
            case .pending:
                continue
            }
        }
    }

    private func inProcessDeliveryIsAllowed(
        automaticGeneration: AutomaticGeneration?,
        editor: any InjectableTextView
    ) -> Bool {
        guard let automaticGeneration else { return editor.isEditable }
        return expansionIsAllowed(generation: automaticGeneration, target: .ownEditor(editor))
    }

    private func performDelivery(
        _ injected: InjectedText,
        targetApp: NSRunningApplication?,
        expectedKeyword: String?,
        keywordLength: Int,
        automaticGeneration: AutomaticGeneration?,
        completion: DeliveryCompletion
    ) async {
        defer { completion.settle() }
        guard finishPendingPasteboardOwnership(),
            await activateAndWaitForTarget(
                targetApp,
                automaticGeneration: automaticGeneration),
            deliveryIsAllowed(
                automaticGeneration: automaticGeneration,
                targetApp: targetApp,
                promptForInteractiveAccessibility: true)
        else { return }

        let accessibilityReplacement = await replaceUsingAccessibility(
            injected,
            targetApp: targetApp,
            expectedKeyword: expectedKeyword,
            keywordLength: keywordLength,
            automaticGeneration: automaticGeneration)
        if accessibilityReplacement == .delivered {
            completion.confirm()
            return
        }
        guard accessibilityReplacement.fallsBackToEvents else { return }

        guard
            await deliverUsingEvents(
                injected.text,
                keywordLength: keywordLength,
                targetApp: targetApp,
                automaticGeneration: automaticGeneration)
        else { return }

        guard let offset = injected.cursorOffsetFromEnd, offset > 0 else {
            completion.confirm()
            return
        }
        for index in 0..<offset {
            guard
                deliveryIsAllowed(
                    automaticGeneration: automaticGeneration,
                    targetApp: targetApp,
                    promptForInteractiveAccessibility: false),
                postKey(code: CGKeyCode(kVK_LeftArrow), targetApp: targetApp)
            else { return }
            if index < offset - 1,
                !(await wait(for: .milliseconds(8)))
            {
                return
            }
        }
        completion.confirm()
    }

    private func deliverUsingEvents(
        _ text: String,
        keywordLength: Int,
        targetApp: NSRunningApplication?,
        automaticGeneration: AutomaticGeneration?
    ) async -> Bool {
        let isShortSingleLine =
            text.count <= 100
            && !text.contains("\n")
            && !text.contains("\r")
        if isShortSingleLine {
            return await deliverUsingUnicodeEvents(
                text,
                keywordLength: keywordLength,
                targetApp: targetApp,
                automaticGeneration: automaticGeneration)
        }

        guard let lease = beginTemporaryPasteboardLease(text) else {
            return await deliverUsingUnicodeEvents(
                text,
                keywordLength: keywordLength,
                targetApp: targetApp,
                automaticGeneration: automaticGeneration)
        }
        activePasteboardLease = lease
        defer { finish(lease) }

        guard let deletionEvents = makeDeletionEvents(count: keywordLength),
            await wait(for: .milliseconds(80)),
            lease.isOwned,
            deliveryIsAllowed(
                automaticGeneration: automaticGeneration,
                targetApp: targetApp,
                promptForInteractiveAccessibility: false),
            await postEventGroups(
                deletionEvents,
                targetApp: targetApp,
                automaticGeneration: automaticGeneration),
            await waitAfterKeywordDeletion(keywordLength),
            lease.isOwned,
            deliveryIsAllowed(
                automaticGeneration: automaticGeneration,
                targetApp: targetApp,
                promptForInteractiveAccessibility: false)
        else { return false }

        let stateBeforePaste = accessibilityTextState(in: targetApp)
        Paster.postCommandV(toPid: targetApp?.processIdentifier)
        return await waitForPasteConfirmation(
            previousState: stateBeforePaste,
            pasteboardLease: lease,
            targetApp: targetApp,
            automaticGeneration: automaticGeneration)
    }

    private func deliverUsingUnicodeEvents(
        _ text: String,
        keywordLength: Int,
        targetApp: NSRunningApplication?,
        automaticGeneration: AutomaticGeneration?
    ) async -> Bool {
        guard let insertionEvents = makeUnicodeEvents(text),
            let deletionEvents = makeDeletionEvents(count: keywordLength),
            deliveryIsAllowed(
                automaticGeneration: automaticGeneration,
                targetApp: targetApp,
                promptForInteractiveAccessibility: false),
            await postEventGroups(
                deletionEvents,
                targetApp: targetApp,
                automaticGeneration: automaticGeneration),
            await waitAfterKeywordDeletion(keywordLength),
            await postEventGroups(
                insertionEvents,
                targetApp: targetApp,
                automaticGeneration: automaticGeneration)
        else { return false }

        return await wait(for: .milliseconds(100))
    }

    /// Each group is one keystroke, spaced so a target that stops accepting them halts the rest.
    private func postEventGroups(
        _ events: [[CGEvent]],
        targetApp: NSRunningApplication?,
        automaticGeneration: AutomaticGeneration?
    ) async -> Bool {
        for index in events.indices {
            guard
                deliveryIsAllowed(
                    automaticGeneration: automaticGeneration,
                    targetApp: targetApp,
                    promptForInteractiveAccessibility: false)
            else { return false }
            post(events[index], targetApp: targetApp)
            if index < events.count - 1,
                !(await wait(for: .milliseconds(8)))
            {
                return false
            }
        }
        return true
    }

    private func waitAfterKeywordDeletion(_ keywordLength: Int) async -> Bool {
        if keywordLength == 0 { return true }
        return await wait(for: .milliseconds(40))
    }

    private func beginTemporaryPasteboardLease(_ text: String) -> TemporaryPasteboardLease? {
        clipboardManager.prepareForTinycastPasteboardMutation()
        return TemporaryPasteboardLease.begin(
            text: text,
            pasteboard: NSPasteboard.general
        ) { [clipboardManager] changeCount in
            clipboardManager.synchronizeAfterTinycastPasteboardMutation(
                changeCount: changeCount)
        }
    }

    @discardableResult
    private func finishPendingPasteboardOwnership() -> Bool {
        guard let lease = activePasteboardLease else { return true }
        for _ in 0..<3 where lease.isOwned { finish(lease) }
        return !lease.isOwned
    }

    private func finish(_ lease: TemporaryPasteboardLease) {
        switch lease.restoreIfOwned() {
        case .restored(let changeCount):
            // Keeps the poller from recording the restored original as a second copy.
            clipboardManager.synchronizeAfterTinycastPasteboardMutation(changeCount: changeCount)
        case .superseded:
            break
        case .failed:
            // Still ours, so leave `activePasteboardLease` in place for the retry below.
            if lease.isOwned { return }
        }
        if activePasteboardLease === lease { activePasteboardLease = nil }
    }

    private func deliveryIsAllowed(
        automaticGeneration: AutomaticGeneration?,
        targetApp: NSRunningApplication?,
        promptForInteractiveAccessibility: Bool
    ) -> Bool {
        if let automaticGeneration {
            guard
                automaticExpansionIsAllowed(
                    generation: automaticGeneration,
                    targetApp: targetApp),
                let targetApp,
                targetApp.isActive,
                NSWorkspace.shared.frontmostApplication?.processIdentifier
                    == targetApp.processIdentifier
            else { return false }
            return true
        }
        // Re-checked before every post, so a target that went away or went secure stops delivery.
        guard targetAcceptsInjection(targetApp), let targetApp,
            targetApp.isActive,
            NSWorkspace.shared.frontmostApplication?.processIdentifier
                == targetApp.processIdentifier
        else { return false }
        return promptForInteractiveAccessibility
            ? Permissions.ensureAccessibility()
            : Permissions.isAccessibilityTrusted()
    }

    private struct AccessibilityTextState: Equatable {
        let value: String
        let selectedRange: NSRange
    }

    private func activateAndWaitForTarget(
        _ targetApp: NSRunningApplication?,
        automaticGeneration: AutomaticGeneration?
    ) async -> Bool {
        guard let targetApp else {
            return deliveryIsAllowed(
                automaticGeneration: automaticGeneration,
                targetApp: nil,
                promptForInteractiveAccessibility: false)
        }
        activate(targetApp)
        for _ in 0..<50 {
            if targetApp.isActive,
                NSWorkspace.shared.frontmostApplication?.processIdentifier
                    == targetApp.processIdentifier
            {
                return true
            }
            if let automaticGeneration,
                !automaticExpansionIsAllowed(
                    generation: automaticGeneration,
                    targetApp: targetApp)
            {
                return false
            }
            guard await wait(for: .milliseconds(20)) else { return false }
        }
        return false
    }

    private struct AccessibilityTarget {
        let element: AXUIElement
        let value: String
        let originalRange: NSRange
        let replacementRange: NSRange
    }

    private enum AccessibilityTargetState {
        case ready(AccessibilityTarget)
        case pending
        case unavailable
        case rejected
    }

    /// Rule 1: a renderer surface answers about its own model, so it is never written to over AX.
    private func replaceUsingAccessibility(
        _ injected: InjectedText,
        targetApp: NSRunningApplication?,
        expectedKeyword: String?,
        keywordLength: Int,
        automaticGeneration: AutomaticGeneration?
    ) async -> AccessibilityReplacement {
        guard let targetApp else { return .unavailable }
        let state = await accessibilityTarget(
            in: targetApp,
            expectedKeyword: expectedKeyword,
            keywordLength: keywordLength,
            automaticGeneration: automaticGeneration)
        guard case .ready(let target) = state else {
            if case .rejected = state { return .rejected }
            return .unavailable
        }

        guard setSelectedRange(target.replacementRange, in: target.element) else {
            return .unavailable
        }
        guard
            AXUIElementSetAttributeValue(
                target.element,
                kAXSelectedTextAttribute as CFString,
                injected.text as CFString) == .success
        else {
            _ = setSelectedRange(target.originalRange, in: target.element)
            return .unavailable
        }

        let observed = stringValue(in: target.element)
        guard
            TextReplacementPolicy.confirmsReplacement(
                originalValue: target.value,
                replacementRange: target.replacementRange,
                insertedText: injected.text,
                observedValue: observed)
        else {
            _ = setSelectedRange(target.originalRange, in: target.element)
            // An untouched value is a tier that did nothing; anything else moved text we cannot name.
            return observed == target.value ? .unavailable : .rejected
        }

        _ = setSelectedRange(
            NSRange(
                location: target.replacementRange.location + injected.caretPrefixLength, length: 0),
            in: target.element)
        return .delivered
    }

    /// Rule 2: a renderer applies the keystroke before it says so, so a short lag is not a mismatch.
    private func accessibilityTarget(
        in targetApp: NSRunningApplication,
        expectedKeyword: String?,
        keywordLength: Int,
        automaticGeneration: AutomaticGeneration?
    ) async -> AccessibilityTargetState {
        for attempt in 0..<Self.convergenceAttempts {
            let state = inspectAccessibilityTarget(
                in: targetApp,
                expectedKeyword: expectedKeyword,
                keywordLength: keywordLength)
            guard case .pending = state else { return state }
            guard attempt < Self.convergenceAttempts - 1,
                automaticGeneration != nil,
                deliveryIsAllowed(
                    automaticGeneration: automaticGeneration,
                    targetApp: targetApp,
                    promptForInteractiveAccessibility: false),
                await wait(for: Self.convergenceInterval)
            else { return .unavailable }
        }
        return .unavailable
    }

    private func inspectAccessibilityTarget(
        in targetApp: NSRunningApplication,
        expectedKeyword: String?,
        keywordLength: Int
    ) -> AccessibilityTargetState {
        guard let element = AccessibilityText.focusedElement(in: targetApp),
            !usesTextMarkerSelection(element),
            isAttributeSettable(kAXSelectedTextRangeAttribute, in: element),
            isAttributeSettable(kAXSelectedTextAttribute, in: element),
            let value = stringValue(in: element),
            let originalRange = selectedRange(in: element)
        else { return .unavailable }

        guard keywordLength > 0 else {
            // Offsets its own value cannot address are a broken tier, not proof the document moved.
            guard Range(originalRange, in: value) != nil else { return .unavailable }
            return .ready(
                AccessibilityTarget(
                    element: element, value: value, originalRange: originalRange,
                    replacementRange: originalRange))
        }
        guard let expectedKeyword, expectedKeyword.count == keywordLength else { return .rejected }
        switch TextReplacementPolicy.keywordState(
            value: value, selectedRange: originalRange, keyword: expectedKeyword)
        {
        case .matched(let replacementRange):
            return .ready(
                AccessibilityTarget(
                    element: element, value: value, originalRange: originalRange,
                    replacementRange: replacementRange))
        case .pending: return .pending
        case .rejected: return .rejected
        }
    }

    /// Web content and Monaco expose selection only as markers; their `AXValue` trails or is empty.
    private func usesTextMarkerSelection(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                element,
                kAXSelectedTextMarkerRangeAttribute as CFString,
                &value) == .success,
            let value
        else { return false }
        return CFGetTypeID(value) == AXTextMarkerRangeGetTypeID()
    }

    /// A renderer, or AppKit handing us our own keystroke, converges in single-digit milliseconds.
    private static let convergenceAttempts = 8
    private static let convergenceInterval = Duration.milliseconds(5)

    private func waitForPasteConfirmation(
        previousState: AccessibilityTextState?,
        pasteboardLease: TemporaryPasteboardLease,
        targetApp: NSRunningApplication?,
        automaticGeneration: AutomaticGeneration?
    ) async -> Bool {
        var readStateAfterPaste = false
        for attempt in 0..<80 {
            guard pasteboardLease.isOwned,
                deliveryIsAllowed(
                    automaticGeneration: automaticGeneration,
                    targetApp: targetApp,
                    promptForInteractiveAccessibility: false)
            else { return false }

            if let previousState,
                let currentState = accessibilityTextState(in: targetApp)
            {
                readStateAfterPaste = true
                if currentState != previousState { return true }
            }
            if PasteConfirmationPolicy.acceptsUnconfirmedDelivery(
                attempt: attempt,
                hadPreviousState: previousState != nil,
                readStateAfterPaste: readStateAfterPaste)
            {
                return true
            }
            guard await wait(for: .milliseconds(25)) else { return false }
        }
        return false
    }

    private func accessibilityTextState(
        in targetApp: NSRunningApplication?
    ) -> AccessibilityTextState? {
        guard let targetApp,
            let element = AccessibilityText.focusedElement(in: targetApp),
            !usesTextMarkerSelection(element),
            let value = stringValue(in: element),
            let selectedRange = selectedRange(in: element)
        else { return nil }
        return AccessibilityTextState(value: value, selectedRange: selectedRange)
    }

    private func stringValue(in element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                element,
                kAXValueAttribute as CFString,
                &value) == .success
        else { return nil }
        return value as? String
    }

    private func selectedRange(in element: AXUIElement) -> NSRange? {
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                element,
                kAXSelectedTextRangeAttribute as CFString,
                &value) == .success,
            let value,
            CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }

        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    private func setSelectedRange(_ range: NSRange, in element: AXUIElement) -> Bool {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let value = AXValueCreate(.cfRange, &cfRange) else { return false }
        return AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            value) == .success
    }

    private func isAttributeSettable(_ attribute: String, in element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        guard
            AXUIElementIsAttributeSettable(
                element,
                attribute as CFString,
                &settable) == .success
        else { return false }
        return settable.boolValue
    }

    private func activate(_ targetApp: NSRunningApplication?) {
        guard targetApp?.isTerminated == false else { return }
        targetApp?.activate()
    }

    private func selection(in target: InjectionTarget?) -> String {
        switch target {
        case .ownEditor(let editor): return editor.injectableSelection
        case .external(let app): return selectedText(in: app) ?? ""
        case nil: return ""
        }
    }

    private func selectedText(in targetApp: NSRunningApplication?) -> String? {
        guard Permissions.isAccessibilityTrusted(), let targetApp else { return nil }
        return AccessibilityText.selection(in: targetApp)
    }

    private func makeUnicodeEvents(_ text: String) -> [[CGEvent]]? {
        guard !text.isEmpty else { return [] }
        var groups: [[CGEvent]] = []
        for chunk in UnicodeTypingChunk.split(text) {
            guard let pair = makeUnicodeEvent(chunk) else { return nil }
            groups.append(pair)
        }
        return groups
    }

    private func makeUnicodeEvent(_ chunk: [UniChar]) -> [CGEvent]? {
        let source = CGEventSource(stateID: .combinedSessionState)
        var characters = chunk
        guard
            let down = CGEvent(
                keyboardEventSource: source,
                virtualKey: 0,
                keyDown: true),
            let up = CGEvent(
                keyboardEventSource: source,
                virtualKey: 0,
                keyDown: false)
        else { return nil }
        // The source inherits held modifiers, and a hotkey's are still down while this types.
        down.flags = []
        up.flags = []
        tag(down)
        tag(up)
        down.keyboardSetUnicodeString(
            stringLength: characters.count,
            unicodeString: &characters)
        up.keyboardSetUnicodeString(
            stringLength: characters.count,
            unicodeString: &characters)
        return [down, up]
    }

    private func makeDeletionEvents(count: Int) -> [[CGEvent]]? {
        var events: [[CGEvent]] = []
        events.reserveCapacity(count)
        for _ in 0..<count {
            guard let pair = makeKeyEvents(code: CGKeyCode(kVK_Delete)) else { return nil }
            events.append(pair)
        }
        return events
    }

    private func makeKeyEvents(
        code: CGKeyCode,
        flags: CGEventFlags = []
    ) -> [CGEvent]? {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard
            let down = CGEvent(
                keyboardEventSource: source,
                virtualKey: code,
                keyDown: true),
            let up = CGEvent(
                keyboardEventSource: source,
                virtualKey: code,
                keyDown: false)
        else { return nil }
        down.flags = flags
        up.flags = flags
        tag(down)
        tag(up)
        return [down, up]
    }

    private func postKey(code: CGKeyCode, targetApp: NSRunningApplication?) -> Bool {
        guard let events = makeKeyEvents(code: code) else { return false }
        post(events, targetApp: targetApp)
        return true
    }

    private func tag(_ event: CGEvent) {
        event.setIntegerValueField(
            .eventSourceUserData,
            value: Paster.tinycastEventTag)
    }

    private func post(_ events: [CGEvent], targetApp: NSRunningApplication?) {
        for event in events { post(event, targetApp: targetApp) }
    }

    private func post(_ event: CGEvent, targetApp: NSRunningApplication?) {
        if let pid = targetApp?.processIdentifier {
            event.postToPid(pid)
        } else {
            event.post(tap: .cghidEventTap)
        }
    }

    private func wait(for duration: Duration) async -> Bool {
        do {
            try await Task.sleep(for: duration)
            return !Task.isCancelled
        } catch {
            return false
        }
    }
}

/// Blink keeps one key event's text in a fixed four-unit array, so Chromium drops everything past it.
enum UnicodeTypingChunk {
    static let maxUTF16Units = 4

    /// Split on scalar boundaries: a lone surrogate half is not text, and a scalar always fits four.
    static func split(_ text: String) -> [[UniChar]] {
        var chunks: [[UniChar]] = []
        var current: [UniChar] = []
        current.reserveCapacity(maxUTF16Units)
        for scalar in text.unicodeScalars {
            if current.count + UTF16.width(scalar) > maxUTF16Units {
                chunks.append(current)
                current = []
            }
            UTF16.encode(scalar) { current.append($0) }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}

enum PasteConfirmationPolicy {
    static func acceptsUnconfirmedDelivery(
        attempt: Int,
        hadPreviousState: Bool,
        readStateAfterPaste: Bool
    ) -> Bool {
        attempt >= 15 && (!hadPreviousState || !readStateAfterPaste)
    }
}

@MainActor
final class DeliveryQueue {
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var tail: (id: UUID, task: Task<Void, Never>)?
    private var automaticTaskID: UUID?

    var isIdle: Bool { tasks.isEmpty }

    @discardableResult
    func enqueue(
        isAutomatic: Bool,
        operation: @escaping @MainActor () async -> Void
    ) -> UUID {
        let id = UUID()
        let predecessor = tail?.task
        let task = Task { @MainActor [weak self] in
            await predecessor?.value
            guard let self else { return }
            defer { self.finish(id: id) }
            guard !Task.isCancelled else { return }
            await operation()
        }
        tasks[id] = task
        tail = (id, task)
        if isAutomatic { automaticTaskID = id }
        return id
    }

    /// Cooperative: a running job stops at its next spaced keystroke, whose wait sees the cancel.
    func cancel(_ id: UUID) {
        tasks[id]?.cancel()
    }

    func cancelAutomatic() {
        guard let automaticTaskID else { return }
        tasks[automaticTaskID]?.cancel()
        self.automaticTaskID = nil
    }

    func cancelAll() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        tail = nil
        automaticTaskID = nil
    }

    func drain() async {
        await tail?.task.value
    }

    private func finish(id: UUID) {
        tasks.removeValue(forKey: id)
        if automaticTaskID == id { automaticTaskID = nil }
        if tail?.id == id { tail = nil }
    }
}

@MainActor
protocol PasteboardAccess: AnyObject {
    var changeCount: Int { get }
    var pasteboardItems: [NSPasteboardItem]? { get }
    @discardableResult func clearContents() -> Int
    func writeObjects(_ objects: [any NSPasteboardWriting]) -> Bool
}

extension NSPasteboard: PasteboardAccess {}

@MainActor
final class TemporaryPasteboardLease {
    enum RestoreResult: Equatable {
        case restored(changeCount: Int)
        case superseded
        case failed
    }

    private let pasteboard: any PasteboardAccess
    private let ownedChangeCount: Int
    private let original: PasteboardSnapshot
    private var isFinished = false

    var isOwned: Bool {
        !isFinished && pasteboard.changeCount == ownedChangeCount
    }

    private init(
        pasteboard: any PasteboardAccess,
        ownedChangeCount: Int,
        original: PasteboardSnapshot
    ) {
        self.pasteboard = pasteboard
        self.ownedChangeCount = ownedChangeCount
        self.original = original
    }

    static func begin(
        text: String,
        pasteboard: any PasteboardAccess,
        onMutation: (Int) -> Void = { _ in }
    ) -> TemporaryPasteboardLease? {
        guard let snapshot = PasteboardSnapshot(pasteboard: pasteboard),
            let temporaryItem = PasteboardSnapshot.temporaryItem(carrying: text),
            let originalItems = snapshot.pasteboardItems(),
            pasteboard.changeCount == snapshot.changeCount
        else { return nil }

        pasteboard.clearContents()
        guard pasteboard.writeObjects([temporaryItem]) else {
            if originalItems.isEmpty || pasteboard.writeObjects(originalItems) {
                onMutation(pasteboard.changeCount)
            }
            return nil
        }
        let ownedChangeCount = pasteboard.changeCount
        onMutation(ownedChangeCount)
        return TemporaryPasteboardLease(
            pasteboard: pasteboard,
            ownedChangeCount: ownedChangeCount,
            original: snapshot)
    }

    /// The lent board holds nothing of the original, so restoring rewrites the snapshot whole.
    func restoreIfOwned() -> RestoreResult {
        guard !isFinished else { return .superseded }
        guard pasteboard.changeCount == ownedChangeCount else {
            isFinished = true
            return .superseded
        }
        guard let items = original.pasteboardItems() else { return .failed }
        pasteboard.clearContents()
        isFinished = true
        guard items.isEmpty || pasteboard.writeObjects(items) else { return .failed }
        return .restored(changeCount: pasteboard.changeCount)
    }
}

@MainActor
struct PasteboardSnapshot {
    struct Item {
        let values: [(type: NSPasteboard.PasteboardType, data: Data)]
    }

    let items: [Item]
    let changeCount: Int

    var firstStringData: Data? {
        items.first?.values.first { $0.type == .string }?.data
    }

    init?(pasteboard: any PasteboardAccess) {
        let changeCount = pasteboard.changeCount
        var items: [Item] = []
        for pasteboardItem in pasteboard.pasteboardItems ?? [] {
            var values: [(type: NSPasteboard.PasteboardType, data: Data)] = []
            for type in pasteboardItem.types {
                guard let data = pasteboardItem.data(forType: type) else { return nil }
                values.append((type: type, data: data))
            }
            items.append(Item(values: values))
        }
        guard pasteboard.changeCount == changeCount else { return nil }
        self.items = items
        self.changeCount = changeCount
    }

    /// A kept `public.html` is the flavour a Chromium editor prefers, so we lend the text alone.
    static func temporaryItem(carrying text: String) -> NSPasteboardItem? {
        let item = NSPasteboardItem()
        guard item.setString(text, forType: .string),
            item.setData(Data(), forType: ClipboardManager.internalType)
        else { return nil }
        return item
    }

    func pasteboardItems() -> [NSPasteboardItem]? {
        var pasteboardItems: [NSPasteboardItem] = []
        pasteboardItems.reserveCapacity(items.count)
        for item in items {
            let pasteboardItem = NSPasteboardItem()
            for value in item.values {
                guard pasteboardItem.setData(value.data, forType: value.type) else { return nil }
            }
            pasteboardItems.append(pasteboardItem)
        }
        return pasteboardItems
    }
}
