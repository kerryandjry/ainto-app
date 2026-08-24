import AppKit
import XCTest
@testable import AintoApp

@MainActor
final class LauncherFocusTests: XCTestCase {
    private func waitForFocus(
        _ placeholder: String,
        in panel: SearchPanel
    ) async throws {
        for _ in 0..<50 {
            if panel.focusedTextFieldPlaceholderForTesting == placeholder {
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting to focus \(placeholder)")
    }

    func testRapidReopenFocusesMainSearchField() async throws {
        _ = NSApplication.shared
        let panel = SearchPanel()
        defer { panel.hidePanel() }

        panel.showPanel()
        panel.hidePanel()
        panel.showPanel()
        try await waitForFocus("Search...", in: panel)

        XCTAssertTrue(panel.isKeyWindow)
    }

    func testStaleMainRequestCannotStealFocusFromClaudePage() async throws {
        _ = NSApplication.shared
        let panel = SearchPanel()
        defer { panel.hidePanel() }

        panel.showPanel()
        panel.requestFocus(selectAll: true)
        panel.viewModel.page = .claude
        panel.requestFocus(selectAll: false)
        try await waitForFocus("Follow up...", in: panel)
    }

    func testHidingInvalidatesPendingFocusCompletion() async throws {
        _ = NSApplication.shared
        let panel = SearchPanel()
        var completed = false

        panel.showPanel()
        panel.requestFocus(selectAll: false) { completed = true }
        panel.hidePanel()
        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertFalse(completed)
    }
}
