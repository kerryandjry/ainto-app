import XCTest
#if SWIFT_PACKAGE
@testable import AintoApp
#else
@testable import Ainto
#endif

final class HomeItemConfigurationTests: XCTestCase {
    func testHiddenFallbackDoesNotExposeBuiltInHomeItems() {
        XCTAssertEqual(
            HomeItemConfiguration.hidden,
            HomeItemConfiguration(config: [
                "home_clipboard_history": false,
                "home_file_search": false,
                "home_snippets": false,
                "home_ai_commands": false,
            ])
        )
    }

    func testLegacyConfigKeepsBuiltInHomeDefaults() {
        let configuration = HomeItemConfiguration(config: [:])

        XCTAssertTrue(configuration.clipboardHistory)
        XCTAssertTrue(configuration.fileSearch)
        XCTAssertTrue(configuration.snippets)
        XCTAssertTrue(configuration.aiCommands)
    }
}
