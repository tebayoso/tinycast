import Foundation

/// What a run does with its result once the model has answered.
enum QuickActionResultMode: String, CaseIterable, Sendable {
    case replace
    /// Moves the caret to each changed span and types only the correction.
    case typeChanges
    case preview
}

struct QuickActionSettings: Equatable, Sendable {
    /// Only what the reader chose: an absent action takes its default, so a default may move later.
    var previewChoices: [BuiltInQuickAction: Bool] = [:]
    /// A separate key rather than a third preview value, so the stored Bools keep their meaning.
    private(set) var typedChangeChoices: Set<BuiltInQuickAction> = []

    /// BCP-47, e.g. `es-419`. Empty means the Mac's own language.
    var targetLanguage: String = ""
    private(set) var instructionOverrides: [BuiltInQuickAction: String] = [:]

    func previewsResult(_ action: QuickAction) -> Bool {
        switch action {
        case .builtIn(let builtIn): return previewsResult(builtIn)
        case .custom(let custom): return custom.previewsResult
        }
    }

    func previewsResult(_ action: BuiltInQuickAction) -> Bool {
        if action.alwaysPreviews { return true }
        return previewChoices[action] ?? !action.replacesDirectlyByDefault
    }

    mutating func setPreviewsResult(_ previews: Bool, for action: BuiltInQuickAction) {
        guard !action.alwaysPreviews else { return }
        previewChoices[action] = previews
    }

    func resultMode(_ action: QuickAction) -> QuickActionResultMode {
        switch action {
        case .builtIn(let builtIn): return resultMode(builtIn)
        case .custom(let custom): return custom.previewsResult ? .preview : .replace
        }
    }

    func resultMode(_ action: BuiltInQuickAction) -> QuickActionResultMode {
        if previewsResult(action) { return .preview }
        return action.offersTypedChanges && typedChangeChoices.contains(action)
            ? .typeChanges : .replace
    }

    mutating func setResultMode(_ mode: QuickActionResultMode, for action: BuiltInQuickAction) {
        guard !action.alwaysPreviews else { return }
        setPreviewsResult(mode == .preview, for: action)
        if mode == .typeChanges, action.offersTypedChanges {
            typedChangeChoices.insert(action)
        } else {
            typedChangeChoices.remove(action)
        }
    }

    func instructionOverride(for action: QuickAction) -> String? {
        action.builtInAction.flatMap(instructionOverride)
    }

    func instructionOverride(for action: BuiltInQuickAction) -> String? {
        instructionOverrides[action]
    }

    mutating func setInstructionOverride(_ instructions: String?, for action: BuiltInQuickAction) {
        guard !action.usesTranslationFramework else { return }
        instructionOverrides[action] = instructions
    }

    /// Round-trips through `UserDefaults`; an unknown key is an action that no longer exists.
    var storedPreviewChoices: [String: Bool] {
        get { Dictionary(uniqueKeysWithValues: previewChoices.map { ($0.rawValue, $1) }) }
        set {
            previewChoices = Dictionary(
                uniqueKeysWithValues: newValue.compactMap { key, value in
                    BuiltInQuickAction(rawValue: key).map { ($0, value) }
                })
        }
    }

    var storedTypedChangeChoices: [String] {
        get { typedChangeChoices.map(\.rawValue).sorted() }
        set {
            typedChangeChoices = Set(
                newValue.compactMap(BuiltInQuickAction.init).filter(\.offersTypedChanges))
        }
    }

    var storedInstructionOverrides: [String: String] {
        get { Dictionary(uniqueKeysWithValues: instructionOverrides.map { ($0.rawValue, $1) }) }
        set {
            instructionOverrides = Dictionary(
                uniqueKeysWithValues: newValue.compactMap { key, value in
                    guard let action = BuiltInQuickAction(rawValue: key),
                        !action.usesTranslationFramework
                    else { return nil }
                    return (action, value)
                })
        }
    }
}
