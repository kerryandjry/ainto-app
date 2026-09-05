import XCTest
#if canImport(AintoApp)
@testable import AintoApp
#elseif canImport(Ainto)
@testable import Ainto
#endif

final class AliasServiceTests: XCTestCase {
    func testRetiredSnippetAliasesAreDormantAndDoNotReserveBindings() throws {
        let hotkey = LauncherHotkey(keyCode: 8, modifiers: 2048, display: "⌥ C")
        let retired = LauncherAlias(alias: "files", hotkey: hotkey, targetType: .snippet, targetID: "old-id")
        let active = LauncherAlias(alias: "files", hotkey: hotkey, targetType: .launcherCommand, targetID: "file-search")
        let entries = try JSONDecoder().decode(
            [LauncherAlias].self, from: JSONEncoder().encode([retired, active])
        )
        XCTAssertEqual(entries, [retired, active])
        XCTAssertFalse(entries[0].isActive)
        XCTAssertTrue(entries[1].isActive)
        XCTAssertNil(AliasStore.validate(entries))
    }

    func testFailedReloadPreservesDraftAndBlocksSaveUntilRecovery() {
        let original = LauncherAlias(alias: "sleep", targetType: .systemAction, targetID: "sleep")
        var draft = AliasSettingsDraft(savedAliases: [original])
        draft.reload(nil)
        var saves = 0
        let rejected = draft.commit([]) { _ in
            saves += 1
            return .success(())
        }
        if case .success = rejected { XCTFail("Unreadable aliases must not be saved") }
        XCTAssertEqual(saves, 0)
        XCTAssertEqual(draft.aliases, [original])
        draft.reload([original])
        let accepted = draft.commit([]) { _ in
            saves += 1
            return .success(())
        }
        if case .failure = accepted { XCTFail("Successful reload must reopen the save gate") }
        XCTAssertEqual(saves, 1)
    }

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

    func testAliasDraftCommitsAValidHotkeyImmediately() {
        let original = LauncherAlias(
            alias: "clipboard",
            hotkey: LauncherHotkey(keyCode: 8, modifiers: 2048, display: "⌥ C"),
            targetType: .launcherCommand,
            targetID: "clipboard-history"
        )
        var changed = original
        changed.hotkey = LauncherHotkey(keyCode: 9, modifiers: 2048, display: "⌥ V")
        var saved: [LauncherAlias] = []
        var draft = AliasSettingsDraft(savedAliases: [original])

        let result = draft.commit([changed]) { candidate in
            saved = candidate
            return .success(())
        }

        if case .failure(let error) = result {
            XCTFail("Unexpected save failure: \(error.message)")
        }
        XCTAssertEqual(saved, [changed])
        XCTAssertEqual(draft.aliases, [changed])
    }

    func testAliasDraftRevertsWhenSavingFails() {
        let original = LauncherAlias(
            alias: "clipboard",
            hotkey: LauncherHotkey(keyCode: 8, modifiers: 2048, display: "⌥ C"),
            targetType: .launcherCommand,
            targetID: "clipboard-history"
        )
        var changed = original
        changed.hotkey = LauncherHotkey(keyCode: 9, modifiers: 2048, display: "⌥ V")
        var draft = AliasSettingsDraft(savedAliases: [original])

        let result = draft.commit([changed]) { _ in .failure(.core(-4)) }

        if case .success = result {
            XCTFail("Expected the failed save to be reported")
        }
        XCTAssertEqual(draft.aliases, [original])
    }

    func testAliasDraftRejectsConflictsWithoutWriting() {
        let original = LauncherAlias(
            alias: "clipboard",
            hotkey: LauncherHotkey(keyCode: 8, modifiers: 2048, display: "⌥ C"),
            targetType: .launcherCommand,
            targetID: "clipboard-history"
        )
        let duplicate = LauncherAlias(
            alias: "files",
            hotkey: original.hotkey,
            targetType: .launcherCommand,
            targetID: "file-search"
        )
        var attemptedSave = false
        var draft = AliasSettingsDraft(savedAliases: [original])

        let result = draft.commit([original, duplicate]) { _ in
            attemptedSave = true
            return .success(())
        }

        if case .success = result {
            XCTFail("Expected duplicate shortcut validation to fail")
        }
        XCTAssertFalse(attemptedSave)
        XCTAssertEqual(draft.aliases, [original])
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
