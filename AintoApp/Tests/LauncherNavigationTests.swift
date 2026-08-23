import XCTest
#if canImport(AintoApp)
@testable import AintoApp
#elseif canImport(Ainto)
@testable import Ainto
#endif

@MainActor
final class LauncherNavigationTests: XCTestCase {
    func testUnsentClaudeFollowUpSurvivesStalePanel() {
        let viewModel = SearchViewModel()
        viewModel.page = .claude
        viewModel.query = "unfinished follow-up"

        viewModel.popToRootIfStale(hiddenFor: 91)

        XCTAssertEqual(viewModel.page, .claude)
        XCTAssertEqual(viewModel.query, "unfinished follow-up")
    }
}
