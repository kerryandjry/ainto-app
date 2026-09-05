// swiftlint:disable file_length function_body_length identifier_name line_length
import SwiftUI
import AppKit
import AintoCore
import ServiceManagement
import Sparkle

// pi-lens-ignore: type_body_length
/// Settings — clean sidebar + card-based content.
struct SettingsView: View {
    static let contentSize = NSSize(width: 720, height: 500)

    var hotkeyManager: HotkeyManager?

    @State private var clipboardMaxItems: Int = 200
    @State private var clipboardMaxImageItems: Int = 50
    @State private var clipboardImagePath: String = "~/.config/ainto/clipboard"
    @State private var claudeBinary: String = "claude"
    @State private var aiEnabled: Bool = true
    @State private var fileSearchPaths: [String] = [NSHomeDirectory()]
    @State private var fileSearchAllLocations = false
    @State private var fileSearchIncludeHidden = false
    @State private var homeClipboardHistory = true
    @State private var homeFileSearch = true
    @State private var homeAICommands = true
    @State private var homeAICommandIDs: [String] = []
    @State private var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled
    @State private var selectedHotkey: String = "⌘ ⇧ Space"
    @State private var popToRootSeconds: Int = 90
    @State private var hasLoaded = false
    @State private var selectedSection: SettingsSection = .general
    @State private var showResetConfirm = false
    @State private var raycastRunning = false

    enum SettingsSection: String, CaseIterable {
        case general = "General"
        case clipboard = "Clipboard"
        case ai = "AI"
        case fileSearch = "File Search"
        case home = "Home Items"
        case aliases = "Aliases"
        case data = "Data"
        case about = "About"

        var icon: String {
            switch self {
            case .general: return "gearshape"
            case .clipboard: return "doc.on.clipboard"
            case .ai: return "sparkle"
            case .fileSearch: return "doc.text.magnifyingglass"
            case .home: return "house"
            case .aliases: return "arrow.triangle.branch"
            case .data: return "folder"
            case .about: return "info.circle"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            // Sidebar — darker background
            VStack(spacing: 2) {
                ForEach(SettingsSection.allCases, id: \.self) { section in
                    SidebarItem(
                        title: section.rawValue,
                        icon: section.icon,
                        isSelected: selectedSection == section
                    )
                    .onTapGesture { selectedSection = section }
                }
                Spacer()
            }
            .padding(.vertical, 16)
            .padding(.horizontal, 8)
            .frame(width: 160)
            .background(Color.primary.opacity(0.04))

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch selectedSection {
                    case .general: generalSection
                    case .clipboard: clipboardSection
                    case .ai: aiSection
                    case .fileSearch: fileSearchSection
                    case .home:
                        HomeItemsSettingsView(
                            clipboardHistory: $homeClipboardHistory,
                            fileSearch: $homeFileSearch,
                            aiCommands: $homeAICommands,
                            selectedAICommandIDs: $homeAICommandIDs,
                            aiEnabled: aiEnabled
                        )
                    case .aliases: AliasSettingsView()
                    case .data: dataSection
                    case .about: aboutSection
                    }
                }
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: Self.contentSize.width, height: Self.contentSize.height)
        .onAppear {
            loadConfig()
            if let hk = hotkeyManager?.currentHotkey { selectedHotkey = hk }
            raycastRunning = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.raycast.macos" }
        }
        .onChange(of: clipboardMaxItems) { _, _ in saveConfig(); applyClipboardLimits() }
        .onChange(of: clipboardMaxImageItems) { _, _ in saveConfig(); applyClipboardLimits() }
        .onChange(of: claudeBinary) { _, _ in saveConfig() }
        .onChange(of: aiEnabled) { _, _ in saveConfig() }
        .onChange(of: popToRootSeconds) { _, _ in saveConfig() }
        .onChange(of: fileSearchPaths) { _, _ in saveConfig() }
        .onChange(of: fileSearchAllLocations) { _, _ in saveConfig() }
        .onChange(of: fileSearchIncludeHidden) { _, _ in saveConfig() }
        .onChange(of: homeClipboardHistory) { _, _ in saveConfig() }
        .onChange(of: homeFileSearch) { _, _ in saveConfig() }
        .onChange(of: homeAICommands) { _, _ in saveConfig() }
        .onChange(of: homeAICommandIDs) { _, _ in saveConfig() }
        .alert("Reset Rankings", isPresented: $showResetConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) {
                _ = rc_reset_rankings()
            }
        } message: {
            Text("This will reset all app and command usage rankings. This cannot be undone.")
        }
    }

    // MARK: - General

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            SectionHeader(title: "General", icon: "gearshape")

            SettingsCard {
                VStack(spacing: 16) {
                    SettingsRow(label: "Hotkey") {
                        HotkeyPicker(selected: $selectedHotkey) { newValue in
                            hotkeyManager?.setHotkey(newValue)
                        }
                    }

                    // Spotlight warning — only if Spotlight's Cmd+Space is enabled
                    if selectedHotkey == "⌘ Space" && isSpotlightHotkeyEnabled() {
                        SettingsHint(icon: "exclamationmark.triangle.fill", color: .orange,
                                     text: "Uncheck \"Show Spotlight search\" in Keyboard → Keyboard Shortcuts → Spotlight.") {
                            HotkeyManager.openSpotlightSettings()
                        }
                    }

                    if isRaycastConflicting() {
                        SettingsHint(icon: "exclamationmark.triangle.fill", color: .orange,
                                     text: "Raycast is using the same hotkey (\(getRaycastHotkey() ?? "")). Quit Raycast or choose a different hotkey.") {
                            if let raycast = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.raycast.macos" }) {
                                raycast.terminate()
                                raycastRunning = false
                            }
                        }
                    }

                    Divider().opacity(0.3)

                    SettingsRow(label: "Return to search") {
                        Picker("", selection: $popToRootSeconds) {
                            ForEach(popToRootOptions, id: \.self) { seconds in
                                Text(Self.popToRootLabel(seconds)).tag(seconds)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(maxWidth: 190)
                    }

                    Divider().opacity(0.3)

                    SettingsRow(label: "Launch at login") {
                        Toggle("", isOn: $launchAtLogin)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .onChange(of: launchAtLogin) { _, newValue in
                                do {
                                    if newValue {
                                        try SMAppService.mainApp.register()
                                    } else {
                                        try SMAppService.mainApp.unregister()
                                    }
                                } catch {
                                    launchAtLogin = SMAppService.mainApp.status == .enabled
                                }
                            }
                    }
                }
            }

            Text("Reopening the launcher after longer than this returns to the search page instead of the clipboard, AI command or Claude page it was left on.")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .padding(.leading, 4)
        }
    }

    private static let popToRootPresets = [0, 10, 30, 60, 90, 300, -1]

    /// Presets plus whatever is currently configured. A value typed straight
    /// into config.toml has to stay selectable, or opening Settings would
    /// quietly round it to the nearest preset and save that.
    private var popToRootOptions: [Int] {
        var options = Self.popToRootPresets
        guard !options.contains(popToRootSeconds) else { return options }
        options.insert(popToRootSeconds, at: max(0, options.count - 1))
        return options
    }

    private static func popToRootLabel(_ seconds: Int) -> String {
        if seconds < 0 { return "Never" }
        if seconds == 0 { return "Immediately" }
        if seconds < 60 { return "After \(seconds) seconds" }
        if seconds == 60 { return "After 1 minute" }
        if seconds % 60 == 0 { return "After \(seconds / 60) minutes" }
        return "After \(seconds) seconds"
    }

    // MARK: - Clipboard

    private var clipboardSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            SectionHeader(title: "Clipboard", icon: "doc.on.clipboard")

            SettingsCard {
                VStack(spacing: 16) {
                    SettingsRow(label: "Max text items") {
                        HStack(spacing: 6) {
                            Text("\(clipboardMaxItems)")
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 40, alignment: .trailing)
                            Stepper("", value: $clipboardMaxItems, in: 10...1000, step: 10)
                                .labelsHidden()
                        }
                    }

                    Divider().opacity(0.3)

                    SettingsRow(label: "Max image items") {
                        HStack(spacing: 6) {
                            Text("\(clipboardMaxImageItems)")
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 40, alignment: .trailing)
                            Stepper("", value: $clipboardMaxImageItems, in: 5...200, step: 5)
                                .labelsHidden()
                        }
                    }

                    Divider().opacity(0.3)

                    SettingsRow(label: "Image storage") {
                        TextField("", text: $clipboardImagePath)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12, design: .monospaced))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Color.primary.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .frame(maxWidth: 220)
                    }
                }
            }

            Text("Images are stored as compressed PNG files. Older items are automatically removed when limits are reached.")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .padding(.leading, 4)
        }
    }

    // MARK: - AI

    private var aiSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            SectionHeader(title: "AI", icon: "sparkle")

            SettingsCard {
                SettingsRow(label: "Enable AI features") {
                    Toggle("", isOn: $aiEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
            }

            Text(
                "Turn this off to disable Claude mode, AI Commands, and related aliases and shortcuts. "
                    + "Your saved commands and settings are preserved."
            )
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .padding(.leading, 4)

            if aiEnabled {
                // Claude Code subsection
                HStack(spacing: 6) {
                    ClaudeIcon(size: 14)
                    Text("Claude Code")
                        .font(.system(size: 15, weight: .medium))
                }
                .padding(.top, 8)

                SettingsCard {
                    SettingsRow(label: "Binary path") {
                        TextField("claude", text: $claudeBinary)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12, design: .monospaced))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Color.primary.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .frame(maxWidth: 220)
                    }
                }

                Text("Press Tab in the launcher to switch to Claude mode.")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 4)

                // AI Commands subsection
                HStack(spacing: 6) {
                    Image(systemName: "sparkle")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                    Text("AI Commands")
                        .font(.system(size: 15, weight: .medium))
                }
                .padding(.top, 8)

                SettingsCard {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("ai-commands.toml")
                                .font(.system(size: 13))
                            Text("Add, remove, or modify AI commands")
                                .font(.system(size: 12))
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Button("Edit") {
                            let _ = rc_ai_commands_load()
                            let path = ("~/.config/ainto/ai-commands.toml" as NSString).expandingTildeInPath
                            NSWorkspace.shared.open(URL(fileURLWithPath: path))
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundColor(.accentColor)
                    }
                }

                Text("Use {selection} as placeholder for selected text in prompts.")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 4)
            }
        }
    }

    // MARK: - File Search

    private var fileSearchSection: some View {
        FileSearchSettingsView(
            paths: $fileSearchPaths,
            allLocations: $fileSearchAllLocations,
            includeHidden: $fileSearchIncludeHidden
        )
    }

    // MARK: - Data

    private var dataSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            SectionHeader(title: "Data", icon: "folder")

            SettingsCard {
                VStack(spacing: 16) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Config directory")
                                .font(.system(size: 13))
                            Text("~/.config/ainto/")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Button("Open") {
                            let path = ("~/.config/ainto" as NSString).expandingTildeInPath
                            NSWorkspace.shared.open(URL(fileURLWithPath: path))
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundColor(.accentColor)
                    }

                    Divider().opacity(0.3)

                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Usage rankings")
                                .font(.system(size: 13))
                            Text("Frecency data for apps and commands")
                                .font(.system(size: 12))
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Button("Reset") {
                            showResetConfirm = true
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundColor(.red)
                    }
                }
            }
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        VStack(spacing: 20) {
            Spacer()

            AintoAboutIcon(size: 64)

            Text("Ainto")
                .font(.system(size: 22, weight: .bold))

            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? appVersion)")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            Text("A personal macOS launcher\nbuilt with Swift + Rust")
                .font(.system(size: 13))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)

            Spacer().frame(height: 12)

            HStack(spacing: 12) {
                AboutButton(title: "Star on GitHub", icon: "star") {
                    NSWorkspace.shared.open(URL(string: "https://github.com/ainto-labs/ainto-app")!)
                }
                AboutButton(title: "Report Issue", icon: "exclamationmark.bubble") {
                    NSWorkspace.shared.open(URL(string: "https://github.com/ainto-labs/ainto-app/issues")!)
                }
            }

            HStack(spacing: 12) {
                AboutButton(title: "ainto.app", icon: "globe") {
                    NSWorkspace.shared.open(URL(string: "https://ainto.app")!)
                }
                AboutButton(title: "Check for Updates", icon: "arrow.triangle.2.circlepath") {
                    (NSApp.delegate as? AppDelegate)?.updater?.checkForUpdates()
                }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

}

private extension SettingsView {
    // MARK: - System Detection

    /// Check if Spotlight's Cmd+Space shortcut is enabled (key 64 in symbolic hotkeys).
    private func isSpotlightHotkeyEnabled() -> Bool {
        guard let hotkeys = UserDefaults(suiteName: "com.apple.symbolichotkeys")?
                .dictionary(forKey: "AppleSymbolicHotKeys"),
              let entry = hotkeys["64"] as? [String: Any],
              let enabled = entry["enabled"] as? Bool else {
            return true // assume enabled if can't read
        }
        return enabled
    }

    /// Get Raycast's global hotkey as display string, or nil if not installed/readable.
    private func getRaycastHotkey() -> String? {
        guard let raw = UserDefaults(suiteName: "com.raycast.macos")?
                .string(forKey: "raycastGlobalHotkey") else { return nil }
        // Format: "Command-49" → "⌘ Space", "Command-Shift-49" → "⌘ ⇧ Space"
        return parseRaycastHotkey(raw)
    }

    /// Check if Raycast is running AND its hotkey conflicts with ours.
    private func isRaycastConflicting() -> Bool {
        guard raycastRunning else { return false }
        guard let raycastHotkey = getRaycastHotkey() else { return false }
        return raycastHotkey == selectedHotkey
    }

    /// Parse Raycast's hotkey format to our display format.
    /// "Command-49" → "⌘ Space", "Command-Shift-49" → "⌘ ⇧ Space"
    private func parseRaycastHotkey(_ raw: String) -> String? {
        let parts = raw.split(separator: "-")
        var modifiers: [String] = []
        var keyCode: Int?

        for part in parts {
            switch part {
            case "Command": modifiers.append("⌘")
            case "Shift": modifiers.append("⇧")
            case "Option": modifiers.append("⌥")
            case "Control": modifiers.append("⌃")
            default:
                keyCode = Int(part)
            }
        }

        let keyName: String
        switch keyCode {
        case 49: keyName = "Space"
        case 40: keyName = "K"
        default: return nil
        }

        return (modifiers + [keyName]).joined(separator: " ")
    }

    // MARK: - Config IO

    private func loadConfig() {
        guard let cStr = rc_config_load() else { return }
        let jsonStr = String(cString: cStr)
        rc_free_string(cStr)

        guard let data = jsonStr.data(using: .utf8),
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        clipboardMaxItems = config["clipboard_max_items"] as? Int ?? 200
        clipboardMaxImageItems = config["clipboard_max_image_items"] as? Int ?? 50
        claudeBinary = config["claude_binary"] as? String ?? "claude"
        aiEnabled = config["ai_enabled"] as? Bool ?? true
        popToRootSeconds = config["pop_to_root_seconds"] as? Int ?? 90
        fileSearchPaths = config["file_search_paths"] as? [String] ?? [NSHomeDirectory()]
        fileSearchAllLocations = config["file_search_all_locations"] as? Bool ?? false
        fileSearchIncludeHidden = config["file_search_include_hidden"] as? Bool ?? false
        homeClipboardHistory = config["home_clipboard_history"] as? Bool ?? true
        homeFileSearch = config["home_file_search"] as? Bool ?? true
        homeAICommands = config["home_ai_commands"] as? Bool ?? true

        let availableCommands = AICommand.loadAll()
        let configuredIDs = config["home_ai_command_ids"] as? [String]
        if let availableCommands {
            let availableIDs = Set(availableCommands.map(\.id))
            if let configuredIDs {
                homeAICommandIDs = Array(configuredIDs.filter(availableIDs.contains).prefix(4))
            } else {
                homeAICommandIDs = availableCommands
                    .sorted { first, second in
                        let firstScore = max(
                            Int(rc_get_ranking("cmd-id:\(first.id)")),
                            Int(rc_get_ranking("cmd:\(first.name)"))
                        )
                        let secondScore = max(
                            Int(rc_get_ranking("cmd-id:\(second.id)")),
                            Int(rc_get_ranking("cmd:\(second.name)"))
                        )
                        if firstScore != secondScore { return firstScore > secondScore }
                        return first.name.localizedStandardCompare(second.name) == .orderedAscending
                    }
                    .prefix(4)
                    .map(\.id)
            }
        } else if let configuredIDs {
            // Preserve stable selections when the AI command file is unreadable.
            homeAICommandIDs = Array(configuredIDs.prefix(4))
        }
        hasLoaded = true
        if configuredIDs == nil, availableCommands != nil {
            saveConfig() // Migrate legacy dynamic top-four behavior to stable IDs.
        }
    }

    private func saveConfig() {
        guard hasLoaded else { return }
        // Start from what is on disk. Sending only the fields below leaves the
        // rest out of the JSON, and the core fills those from
        // `Config::default()` — silently resetting any setting this view does
        // not manage. `pop_to_root_seconds`, which is edited straight in
        // config.toml, was reset to its default every time Settings opened.
        guard var config = configOnDisk() else { return }
        config["clipboard_max_items"] = clipboardMaxItems
        config["clipboard_max_image_items"] = clipboardMaxImageItems
        config["claude_binary"] = claudeBinary
        config["ai_enabled"] = aiEnabled
        config["pop_to_root_seconds"] = popToRootSeconds
        config["file_search_paths"] = fileSearchPaths
        config["file_search_all_locations"] = fileSearchAllLocations
        config["file_search_include_hidden"] = fileSearchIncludeHidden
        config["home_clipboard_history"] = homeClipboardHistory
        config["home_file_search"] = homeFileSearch
        config["home_ai_commands"] = homeAICommands
        config["home_ai_command_ids"] = homeAICommandIDs
        guard let data = try? JSONSerialization.data(withJSONObject: config),
              let jsonStr = String(data: data, encoding: .utf8) else { return }
        let _ = rc_config_save(jsonStr)
    }

    /// The config as the core currently has it, so a save can preserve keys
    /// this view does not manage. Returns nil when it cannot be read — the core
    /// returns NULL for a file that failed to parse, and overwriting that with
    /// defaults is exactly what must not happen.
    private func configOnDisk() -> [String: Any]? {
        guard let cStr = rc_config_load() else { return nil }
        let jsonStr = String(cString: cStr)
        rc_free_string(cStr)
        guard let data = jsonStr.data(using: .utf8),
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return config
    }

    /// Apply clipboard limits to the running store so the change takes effect
    /// immediately, not just on next launch. Only invoked when the clipboard
    /// limits change — not on every config save.
    private func applyClipboardLimits() {
        let _ = rc_clipboard_set_limits(UInt64(clipboardMaxItems), UInt64(clipboardMaxImageItems))
    }
}

// MARK: - Components

struct SectionHeader: View {
    let title: String
    let icon: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 18, weight: .semibold))
        }
    }
}

/// Card container with subtle background.
struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(16)
            .background(Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Warning/hint row with action button.
struct SettingsHint: View {
    let icon: String
    let color: Color
    let text: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .foregroundColor(color)
                .font(.system(size: 12))
                .padding(.top, 1)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Fix") { action() }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.accentColor)
        }
        .padding(10)
        .background(color.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct SidebarItem: View {
    let title: String
    let icon: String
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .frame(width: 18)
            Text(title)
                .font(.system(size: 14))
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.accentColor.opacity(0.2))
            }
        }
        .foregroundStyle(isSelected ? .primary : .secondary)
        .contentShape(Rectangle())
    }
}

struct SettingsRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 14))
            Spacer()
            content()
        }
    }
}

/// Custom hotkey picker — badge button + popover dropdown.
struct HotkeyPicker: View {
    @Binding var selected: String
    let onChange: (String) -> Void
    @State private var showPopover = false

    var body: some View {
        Button(action: { showPopover.toggle() }) {
            HStack(spacing: 4) {
                ForEach(selected.split(separator: " ").map(String.init), id: \.self) { key in
                    Text(key)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.primary.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 2)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            VStack(spacing: 2) {
                ForEach(HotkeyConfig.options.map(\.displayName), id: \.self) { option in
                    Button(action: {
                        selected = option
                        onChange(option)
                        showPopover = false
                    }) {
                        HStack(spacing: 4) {
                            ForEach(option.split(separator: " ").map(String.init), id: \.self) { key in
                                Text(key)
                                    .font(.system(size: 12, weight: .medium, design: .rounded))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(Color.primary.opacity(option == selected ? 0.15 : 0.06))
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                            }
                            Spacer()
                            if option == selected {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(.accentColor)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(6)
            .frame(width: 210)
        }
    }
}

/// Ainto logo icon loaded from bundled PNG for the About section.
struct AintoAboutIcon: View {
    let size: CGFloat

    var body: some View {
        if let image = loadAboutIcon() {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        } else {
            Image(systemName: "command.square.fill")
                .font(.system(size: size * 0.75))
                .foregroundColor(.accentColor)
        }
    }

    private func loadAboutIcon() -> NSImage? {
        if let url = ResourceBundle.url(forResource: "ainto-about", withExtension: "png") {
            return NSImage(contentsOf: url)
        }
        return nil
    }
}

struct AboutButton: View {
    let title: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                Text(title)
                    .font(.system(size: 13))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Color.primary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
