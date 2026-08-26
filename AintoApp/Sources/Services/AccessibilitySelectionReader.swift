import AppKit
import ApplicationServices

/// Reads selected text without changing the system clipboard when the focused
/// application exposes the standard macOS Accessibility text attributes.
enum AccessibilitySelectionReader {
    typealias AttributeReader = (
        AXUIElement,
        CFString,
        UnsafeMutablePointer<CFTypeRef?>
    ) -> AXError
    typealias ParameterizedAttributeReader = (
        AXUIElement,
        CFString,
        CFTypeRef,
        UnsafeMutablePointer<CFTypeRef?>
    ) -> AXError

    private static var selectedTextMarkerRange: CFString {
        "AXSelectedTextMarkerRange" as CFString
    }

    private static var stringForTextMarkerRange: CFString {
        "AXStringForTextMarkerRange" as CFString
    }

    static func selectedText(from application: NSRunningApplication) -> String? {
        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        return selectedText(applicationElement: applicationElement)
    }

    static func selectedText(
        applicationElement: AXUIElement,
        readAttribute: AttributeReader = AXUIElementCopyAttributeValue,
        readParameterizedAttribute: ParameterizedAttributeReader =
            AXUIElementCopyParameterizedAttributeValue
    ) -> String? {
        var focusedValue: CFTypeRef?
        guard readAttribute(
            applicationElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        ) == .success,
            let focusedValue,
            CFGetTypeID(focusedValue) == AXUIElementGetTypeID()
        else { return nil }

        let focusedElement = unsafeDowncast(focusedValue, to: AXUIElement.self)
        var selectedValue: CFTypeRef?
        if readAttribute(
            focusedElement,
            kAXSelectedTextAttribute as CFString,
            &selectedValue
        ) == .success,
           let selectedText = selectedValue as? String,
           !selectedText.isEmpty {
            return selectedText
        }

        // WebKit-backed controls, including Mail's message viewer, commonly
        // expose selections as text-marker ranges instead of AXSelectedText.
        var markerRange: CFTypeRef?
        guard readAttribute(
            focusedElement,
            selectedTextMarkerRange,
            &markerRange
        ) == .success,
            let markerRange
        else { return nil }

        var markerTextValue: CFTypeRef?
        guard readParameterizedAttribute(
            focusedElement,
            stringForTextMarkerRange,
            markerRange,
            &markerTextValue
        ) == .success,
            let markerText = markerTextValue as? String,
            !markerText.isEmpty
        else { return nil }
        return markerText
    }
}
