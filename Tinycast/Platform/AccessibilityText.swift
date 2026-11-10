import AppKit
// `@preconcurrency` downgrades AX diagnostics: the attribute keys are constant C globals.
@preconcurrency import ApplicationServices

/// Always against a named process: the system-wide focus answers with ours.
enum AccessibilityText {
    /// Generous for a responsive app, short enough that a wedged one can't stall the main actor.
    private static let timeout: Float = 1

    /// The two have different fixes; collapsing them tells a reader to select what they selected.
    enum Selection: Equatable {
        case text(String)
        case noFocusedElement
        case empty
    }

    static func focusedElement(in app: NSRunningApplication) -> AXUIElement? {
        let application = AXUIElementCreateApplication(app.processIdentifier)
        // Per element and never inherited, so the focused element needs its own against a hang.
        AXUIElementSetMessagingTimeout(application, timeout)
        activateManualAccessibility(of: application)
        var focusedValue: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                application,
                kAXFocusedUIElementAttribute as CFString,
                &focusedValue) == .success,
            let focusedValue,
            CFGetTypeID(focusedValue) == AXUIElementGetTypeID()
        else { return nil }

        let element = focusedValue as! AXUIElement
        AXUIElementSetMessagingTimeout(element, timeout)
        return element
    }

    static func read(in app: NSRunningApplication) -> Selection {
        guard let element = focusedElement(in: app) else { return .noFocusedElement }
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            &value)
        if status == .success, let text = value as? String, !text.isEmpty {
            return .text(restoringLineBreaks(text, in: element) ?? text)
        }
        guard let web = webSelection(in: element), !web.isEmpty else { return .empty }
        return .text(restoringLineBreaks(web, in: element) ?? web)
    }

    /// A narrower question, for callers that can act on the text but not on why there is none.
    static func selection(in app: NSRunningApplication) -> String? {
        guard case .text(let text) = read(in: app) else { return nil }
        return text
    }

    /// Chromium builds its tree only once asked, so Chrome and Electron answer nothing until this.
    private static func activateManualAccessibility(of application: AXUIElement) {
        AXUIElementSetAttributeValue(
            application, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    /// Chromium's selected text drops paragraph breaks its `AXValue` keeps; a replace joins them.
    private static func restoringLineBreaks(
        _ selection: String, in element: AXUIElement
    ) -> String? {
        var marker: CFTypeRef?
        var value: CFTypeRef?
        var rangeValue: CFTypeRef?
        var range = CFRange()
        guard
            AXUIElementCopyAttributeValue(
                element, kAXSelectedTextMarkerRangeAttribute as CFString, &marker) == .success,
            let marker, CFGetTypeID(marker) == AXTextMarkerRangeGetTypeID(),
            AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
                == .success,
            let text = value as? String,
            AXUIElementCopyAttributeValue(
                element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
            let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID(),
            AXValueGetValue(rangeValue as! AXValue, .cfRange, &range)
        else { return nil }
        return lineBreaksRestored(
            selection, from: text, range: NSRange(location: range.location, length: range.length))
    }

    /// Rule 1: a value that trails the editor is not the selection, so only the same text passes.
    static func lineBreaksRestored(
        _ selection: String, from value: String, range: NSRange
    ) -> String? {
        guard let bounds = Range(range, in: value) else { return nil }
        let candidate = String(value[bounds])
        guard candidate != selection,
            candidate.filter({ !$0.isNewline }) == selection.filter({ !$0.isNewline })
        else { return nil }
        return candidate
    }

    /// Browsers have no `AXSelectedText`: web selection exists only as an opaque marker range.
    private static func webSelection(in element: AXUIElement) -> String? {
        var range: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                element,
                kAXSelectedTextMarkerRangeAttribute as CFString,
                &range) == .success,
            let range,
            CFGetTypeID(range) == AXTextMarkerRangeGetTypeID()
        else { return nil }

        var value: CFTypeRef?
        guard
            AXUIElementCopyParameterizedAttributeValue(
                element,
                kAXStringForTextMarkerRangeParameterizedAttribute as CFString,
                range,
                &value) == .success
        else { return nil }
        return value as? String
    }
}
