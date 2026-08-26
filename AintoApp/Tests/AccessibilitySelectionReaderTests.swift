import ApplicationServices
import XCTest
#if canImport(AintoApp)
@testable import AintoApp
#elseif canImport(Ainto)
@testable import Ainto
#endif

final class AccessibilitySelectionReaderTests: XCTestCase {
    func testReadsSelectionFromFocusedAccessibilityElement() {
        let application = AXUIElementCreateSystemWide()
        let focused = AXUIElementCreateSystemWide()
        let selection = "Text selected for translation" as CFString

        let result = AccessibilitySelectionReader.selectedText(
            applicationElement: application,
            readAttribute: { element, attribute, output in
                if CFEqual(element, application),
                   attribute == kAXFocusedUIElementAttribute as CFString {
                    output.pointee = focused
                    return .success
                }
                if CFEqual(element, focused),
                   attribute == kAXSelectedTextAttribute as CFString {
                    output.pointee = selection
                    return .success
                }
                return .attributeUnsupported
            }
        )

        XCTAssertEqual(result, "Text selected for translation")
    }

    func testReturnsNilWhenSelectedTextIsUnavailable() {
        let application = AXUIElementCreateSystemWide()
        let focused = AXUIElementCreateSystemWide()

        let result = AccessibilitySelectionReader.selectedText(
            applicationElement: application,
            readAttribute: { element, attribute, output in
                if CFEqual(element, application),
                   attribute == kAXFocusedUIElementAttribute as CFString {
                    output.pointee = focused
                    return .success
                }
                return .attributeUnsupported
            }
        )

        XCTAssertNil(result)
    }

    func testReturnsNilForEmptySelection() {
        let application = AXUIElementCreateSystemWide()
        let focused = AXUIElementCreateSystemWide()
        let selection = "" as CFString

        let result = AccessibilitySelectionReader.selectedText(
            applicationElement: application,
            readAttribute: { element, attribute, output in
                if CFEqual(element, application),
                   attribute == kAXFocusedUIElementAttribute as CFString {
                    output.pointee = focused
                    return .success
                }
                if CFEqual(element, focused),
                   attribute == kAXSelectedTextAttribute as CFString {
                    output.pointee = selection
                    return .success
                }
                return .attributeUnsupported
            }
        )

        XCTAssertNil(result)
    }
}
