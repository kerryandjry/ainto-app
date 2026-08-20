import XCTest
#if canImport(AintoApp)
@testable import AintoApp
#elseif canImport(Ainto)
@testable import Ainto
#endif

final class AliasServiceTests: XCTestCase {
    func testNormalizationIsUnicodeCaseInsensitive() {
        XCTAssertEqual(AliasStore.normalize("  Straße  "), AliasStore.normalize("STRASSE"))
    }

    func testNormalizationCanonicalizesEquivalentUnicode() {
        XCTAssertEqual(AliasStore.normalize("café"), AliasStore.normalize("cafe\u{301}"))
    }

    func testValidationRejectsUnicodeEquivalentDuplicates() {
        let aliases = [
            LauncherAlias(alias: "Straße", targetType: .systemAction, targetID: "sleep"),
            LauncherAlias(alias: "STRASSE", targetType: .systemAction, targetID: "restart"),
        ]
        XCTAssertNotNil(AliasStore.validate(aliases))
    }

    func testValidationAllowsHotkeyWithoutAlias() {
        let entry = LauncherAlias(
            alias: "",
            hotkey: LauncherHotkey(keyCode: 8, modifiers: 2048, display: "⌥ C"),
            targetType: .launcherCommand,
            targetID: "clipboard-history"
        )
        XCTAssertNil(AliasStore.validate([entry]))
    }

    func testHotkeyOnlyEntryEncodesForRustBridge() throws {
        let entry = LauncherAlias(
            alias: "",
            hotkey: LauncherHotkey(keyCode: 8, modifiers: 2048, display: "⌥ C"),
            targetType: .launcherCommand,
            targetID: "clipboard-history"
        )
        let data = try JSONEncoder().encode([entry])
        let values = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        )
        XCTAssertEqual(values[0]["alias"] as? String, "")
        XCTAssertEqual(values[0]["hotkey_key_code"] as? Int, 8)
        XCTAssertEqual(values[0]["hotkey_modifiers"] as? Int, 2048)
        XCTAssertEqual(values[0]["hotkey_display"] as? String, "⌥ C")
    }

    func testValidationRejectsDuplicateHotkeys() {
        let hotkey = LauncherHotkey(keyCode: 3, modifiers: 2048, display: "⌥ F")
        let entries = [
            LauncherAlias(
                alias: "clipboard",
                hotkey: hotkey,
                targetType: .launcherCommand,
                targetID: "clipboard-history"
            ),
            LauncherAlias(
                alias: "files",
                hotkey: hotkey,
                targetType: .launcherCommand,
                targetID: "file-search"
            ),
        ]
        XCTAssertNotNil(AliasStore.validate(entries))
    }

    func testAppTargetsDistinguishDuplicateBundleIDs() {
        let first = SearchViewModel.appTargetRef(
            bundleID: "com.example.app",
            path: "/Applications/Example.app"
        )
        let second = SearchViewModel.appTargetRef(
            bundleID: "com.example.app",
            path: "/Users/example/Example.app"
        )
        XCTAssertNotEqual(first, second)
    }
}
