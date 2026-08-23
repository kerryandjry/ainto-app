import XCTest
#if canImport(AintoApp)
@testable import AintoApp
#elseif canImport(Ainto)
@testable import Ainto
#endif

@MainActor
final class LauncherNavigationTests: XCTestCase {
    func testPopToRootWaitsForConfiguredDelay() {
        let viewModel = makeViewModel(page: .clipboard, delay: 90)
        viewModel.query = "stale query"

        XCTAssertFalse(viewModel.popToRootIfStale(hiddenFor: 89))
        XCTAssertEqual(viewModel.page, .clipboard)

        XCTAssertTrue(viewModel.popToRootIfStale(hiddenFor: 90))
        XCTAssertEqual(viewModel.page, .main)
        XCTAssertTrue(viewModel.query.isEmpty)
    }

    func testZeroDelayPopsImmediately() {
        let viewModel = makeViewModel(page: .snippets, delay: 0)

        XCTAssertTrue(viewModel.popToRootIfStale(hiddenFor: 0))
        XCTAssertEqual(viewModel.page, .main)
    }

    func testNegativeDelayNeverPops() {
        let viewModel = makeViewModel(page: .clipboard, delay: -1)

        XCTAssertFalse(viewModel.popToRootIfStale(hiddenFor: 86_400))
        XCTAssertEqual(viewModel.page, .clipboard)
    }

    func testSnippetAndAICommandEditorsSurviveStalePanel() {
        let snippetViewModel = makeViewModel(page: .snippets)
        snippetViewModel.isEditingSnippet = true
        XCTAssertFalse(snippetViewModel.popToRootIfStale(hiddenFor: 91))
        XCTAssertEqual(snippetViewModel.page, .snippets)

        let commandViewModel = makeViewModel(page: .aiCommands)
        commandViewModel.isEditingAICommand = true
        XCTAssertFalse(commandViewModel.popToRootIfStale(hiddenFor: 91))
        XCTAssertEqual(commandViewModel.page, .aiCommands)
    }

    func testStreamingClaudeResponseSurvivesStalePanel() {
        let viewModel = makeViewModel(page: .claude)
        viewModel.claudeIsStreaming = true

        XCTAssertFalse(viewModel.popToRootIfStale(hiddenFor: 91))
        XCTAssertEqual(viewModel.page, .claude)
    }

    func testUnsentClaudeFollowUpSurvivesStalePanel() {
        let viewModel = makeViewModel(page: .claude)
        viewModel.query = "unfinished follow-up"

        XCTAssertFalse(viewModel.popToRootIfStale(hiddenFor: 91))
        XCTAssertEqual(viewModel.page, .claude)
        XCTAssertEqual(viewModel.query, "unfinished follow-up")
    }

    private func makeViewModel(
        page: LauncherPage,
        delay: Int = 90
    ) -> SearchViewModel {
        let viewModel = SearchViewModel()
        viewModel.page = page
        viewModel.popToRootSeconds = delay
        return viewModel
    }
}
