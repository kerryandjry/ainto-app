import XCTest
#if canImport(AintoApp)
@testable import AintoApp
#elseif canImport(Ainto)
@testable import Ainto
#endif

#if canImport(AintoApp) || canImport(Ainto)
@MainActor
final class LauncherNavigationTests: XCTestCase {
    func testPendingSystemActionDoesNotSurviveHidingThePanel() {
        let viewModel = SearchViewModel()
        viewModel.page = .systemConfirmation
        viewModel.pendingSystemAction = .restart

        viewModel.prepareForPanelHide()

        // Reopening on a stale confirmation would leave Restart one Return away.
        XCTAssertEqual(viewModel.page, .main)
        XCTAssertNil(viewModel.pendingSystemAction)
    }

    func testConfirmationSurvivesWhileTheActionIsExecuting() {
        let viewModel = SearchViewModel()
        viewModel.page = .systemConfirmation
        viewModel.pendingSystemAction = .restart
        viewModel.isExecutingSystemAction = true

        viewModel.prepareForPanelHide()

        XCTAssertEqual(viewModel.page, .systemConfirmation)
        XCTAssertEqual(viewModel.pendingSystemAction, .restart)
    }

    func testUnaffectedPagesAreLeftAlone() {
        let viewModel = SearchViewModel()
        viewModel.page = .clipboard

        viewModel.prepareForPanelHide()

        XCTAssertEqual(viewModel.page, .clipboard)
    }

    func testFileSearchUsesTheConfiguredPopDelay() {
        let viewModel = makeViewModel(page: .fileSearch, delay: 90)

        viewModel.prepareForPanelHide()
        XCTAssertEqual(viewModel.page, .fileSearch)
        XCTAssertFalse(viewModel.popToRootIfStale(hiddenFor: 89))
        XCTAssertEqual(viewModel.page, .fileSearch)

        XCTAssertTrue(viewModel.popToRootIfStale(hiddenFor: 90))
        XCTAssertEqual(viewModel.page, .main)
    }

    func testStaleRootAppSearchIsClearedAtConfiguredDelay() {
        let viewModel = makeViewModel(page: .main, delay: 90)
        viewModel.searchMode = .apps
        viewModel.query = "unfinished filter"

        XCTAssertFalse(viewModel.popToRootIfStale(hiddenFor: 89))
        XCTAssertEqual(viewModel.query, "unfinished filter")

        XCTAssertTrue(viewModel.popToRootIfStale(hiddenFor: 90))
        XCTAssertEqual(viewModel.page, .main)
        XCTAssertTrue(viewModel.query.isEmpty)
    }

    func testEmptyRootSearchDoesNotPop() {
        let viewModel = makeViewModel(page: .main, delay: 90)

        XCTAssertFalse(viewModel.popToRootIfStale(hiddenFor: 90))
        XCTAssertEqual(viewModel.page, .main)
    }

    func testUnsentRootAIPromptSurvivesStalePanel() {
        let viewModel = makeViewModel(page: .main, delay: 90)
        viewModel.searchMode = .claude
        viewModel.query = "unfinished prompt"

        XCTAssertFalse(viewModel.popToRootIfStale(hiddenFor: 90))
        XCTAssertEqual(viewModel.searchMode, .claude)
        XCTAssertEqual(viewModel.query, "unfinished prompt")
    }

    func testZeroDelayClearsRootAppSearchImmediately() {
        let viewModel = makeViewModel(page: .main, delay: 0)
        viewModel.query = "filter"

        XCTAssertTrue(viewModel.popToRootIfStale(hiddenFor: 0))
        XCTAssertTrue(viewModel.query.isEmpty)
    }

    func testNegativeDelayPreservesRootAppSearch() {
        let viewModel = makeViewModel(page: .main, delay: -1)
        viewModel.query = "filter"

        XCTAssertFalse(viewModel.popToRootIfStale(hiddenFor: 86_400))
        XCTAssertEqual(viewModel.query, "filter")
    }

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
#endif
