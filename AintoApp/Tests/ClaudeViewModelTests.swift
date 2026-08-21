import XCTest
#if canImport(AintoApp)
@testable import AintoApp
#elseif canImport(Ainto)
@testable import Ainto
#endif

@MainActor
final class ClaudeViewModelTests: XCTestCase {
    func testOverloadErrorOffersRetry() {
        let viewModel = SearchViewModel()
        viewModel.claudeMessages = [
            ClaudeMessage(role: .user, text: "Translate this"),
            ClaudeMessage(role: .assistant, text: "API Error: 529 Overloaded"),
        ]

        XCTAssertTrue(viewModel.claudeCanRetryLastRequest)
    }

    func testOrdinaryAssistantResponseDoesNotOfferRetry() {
        let viewModel = SearchViewModel()
        viewModel.claudeMessages = [
            ClaudeMessage(role: .user, text: "Translate this"),
            ClaudeMessage(role: .assistant, text: "翻譯結果"),
        ]

        XCTAssertFalse(viewModel.claudeCanRetryLastRequest)
    }
}
