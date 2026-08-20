import Foundation
import AintoCore

extension Notification.Name {
    static let aliasesDidChange = Notification.Name("app.ainto.aliasesDidChange")
}

enum LauncherTargetKind: String, Codable, CaseIterable {
    case app
    case aiCommand = "ai_command"
    case snippet
    case launcherCommand = "launcher_command"
    case systemAction = "system_action"
}

struct LauncherTargetRef: Hashable, Codable {
    let kind: LauncherTargetKind
    let id: String
}

struct LauncherHotkey: Codable, Hashable {
    let keyCode: UInt32
    let modifiers: UInt32
    let display: String

    enum CodingKeys: String, CodingKey {
        case keyCode = "key_code"
        case modifiers
        case display
    }
}

struct LauncherAlias: Codable, Identifiable, Hashable {
    var alias: String
    private var hotkeyKeyCode: UInt32?
    private var hotkeyModifiers: UInt32?
    private var hotkeyDisplay: String?
    var targetType: LauncherTargetKind
    var targetID: String

    var hotkey: LauncherHotkey? {
        get {
            guard let keyCode = hotkeyKeyCode,
                  let modifiers = hotkeyModifiers,
                  let display = hotkeyDisplay
            else { return nil }
            return LauncherHotkey(keyCode: keyCode, modifiers: modifiers, display: display)
        }
        set {
            hotkeyKeyCode = newValue?.keyCode
            hotkeyModifiers = newValue?.modifiers
            hotkeyDisplay = newValue?.display
        }
    }

    var id: String {
        let shortcut = hotkey.map { "\($0.keyCode):\($0.modifiers)" } ?? ""
        return "\(AliasStore.normalize(alias))|\(shortcut)|\(targetType.rawValue):\(targetID)"
    }
    var target: LauncherTargetRef { LauncherTargetRef(kind: targetType, id: targetID) }

    enum CodingKeys: String, CodingKey {
        case alias
        case hotkeyKeyCode = "hotkey_key_code"
        case hotkeyModifiers = "hotkey_modifiers"
        case hotkeyDisplay = "hotkey_display"
        case targetType = "target_type"
        case targetID = "target_id"
    }

    init(alias: String, hotkey: LauncherHotkey? = nil, targetType: LauncherTargetKind, targetID: String) {
        self.alias = alias
        hotkeyKeyCode = hotkey?.keyCode
        hotkeyModifiers = hotkey?.modifiers
        hotkeyDisplay = hotkey?.display
        self.targetType = targetType
        self.targetID = targetID
    }
}

struct AliasTargetOption: Identifiable, Hashable {
    let ref: LauncherTargetRef
    let title: String
    let detail: String
    var id: String { "\(ref.kind.rawValue):\(ref.id)" }
}

enum AliasStore {
    static func normalize(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCompatibilityMapping
            .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .precomposedStringWithCompatibilityMapping
    }

    static func load() -> [LauncherAlias] {
        guard let cString = rc_aliases_load() else { return [] }
        defer { rc_free_string(cString) }
        let json = String(cString: cString)
        guard let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([LauncherAlias].self, from: data)) ?? []
    }

    static func validate(_ aliases: [LauncherAlias]) -> String? {
        var usedAliases = Set<String>()
        var usedHotkeys = Set<String>()
        for entry in aliases {
            let normalized = normalize(entry.alias)
            if normalized.isEmpty && entry.hotkey == nil {
                return "Enter an alias, record a shortcut, or provide both."
            }
            if !normalized.isEmpty, !usedAliases.insert(normalized).inserted {
                return "The alias ‘\(entry.alias.trimmingCharacters(in: .whitespacesAndNewlines))’ is already in use."
            }
            if let hotkey = entry.hotkey {
                let identifier = "\(hotkey.keyCode):\(hotkey.modifiers)"
                if !usedHotkeys.insert(identifier).inserted {
                    return "The shortcut ‘\(hotkey.display)’ is already in use."
                }
                if HotkeyConfig.isLauncherHotkey(hotkey) {
                    return "The shortcut ‘\(hotkey.display)’ is already used to open Ainto."
                }
            }
        }
        return nil
    }

    @discardableResult
    static func save(_ aliases: [LauncherAlias]) -> Bool {
        guard validate(aliases) == nil,
              let data = try? JSONEncoder().encode(aliases),
              let json = String(data: data, encoding: .utf8)
        else { return false }
        guard rc_aliases_save(json) == 0 else { return false }
        NotificationCenter.default.post(name: .aliasesDidChange, object: nil)
        return true
    }
}
