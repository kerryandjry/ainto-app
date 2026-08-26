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

    static func selectedText(from application: NSRunningApplication) -> String? {
        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        return selectedText(applicationElement: applicationElement)
    }

    static func selectedText(
        applicationElement: AXUIElement,
        readAttribute: AttributeReader = AXUIElementCopyAttributeValue
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
        guard readAttribute(
            focusedElement,
            kAXSelectedTextAttribute as CFString,
            &selectedValue
        ) == .success,
            let selectedText = selectedValue as? String,
            !selectedText.isEmpty
        else { return nil }
        return selectedText
    }
}
