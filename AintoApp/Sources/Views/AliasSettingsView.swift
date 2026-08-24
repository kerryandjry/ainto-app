@preconcurrency import HotKey
import AppKit
import SwiftUI
import AintoCore

struct AliasSettingsView: View {
    @State private var draft = AliasSettingsDraft()
    @State private var targets: [AliasTargetOption] = []
    @State private var newAlias = ""
    @State private var newHotkey: LauncherHotkey?
    @State private var selectedTarget: LauncherTargetRef?
    @State private var validationError: String?
    @State private var savedMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SectionHeader(title: "Aliases & Shortcuts", icon: "command")

            Text(
                "Map an optional typed alias, a global keyboard shortcut, or both to one target. "
                    + "Aliases are exact and case-insensitive."
            )
            .font(.system(size: 12))
            .foregroundStyle(.secondary)

            SettingsCard {
                VStack(spacing: 10) {
                    gridHeader
                    HStack(spacing: 10) {
                        TextField("Optional alias", text: $newAlias)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                        HotkeyRecorderField(hotkey: $newHotkey)
                            .frame(width: 100, height: 24)
                        SearchableTargetPicker(selection: $selectedTarget, targets: targets)
                            .frame(minWidth: 130)
                        Button("Add") { addEntry() }
                            .frame(width: 42)
                            .disabled(
                                (AliasStore.normalize(newAlias).isEmpty && newHotkey == nil)
                                    || selectedTarget == nil
                            )
                    }
                }
            }

            if draft.aliases.isEmpty {
                Text("No aliases or shortcuts configured.")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
            } else {
                SettingsCard {
                    VStack(spacing: 10) {
                        gridHeader
                        ForEach(Array(draft.aliases.indices), id: \.self) { index in
                            HStack(spacing: 10) {
                                TextField("Optional", text: aliasBinding(index))
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 90)
                                HotkeyRecorderField(hotkey: hotkeyBinding(index))
                                    .frame(width: 100, height: 24)
                                SearchableTargetPicker(
                                    selection: targetBinding(index),
                                    targets: targetsIncludingUnavailable(for: draft.aliases[index])
                                )
                                .frame(minWidth: 130)
                                Button {
                                    var candidate = draft.aliases
                                    candidate.remove(at: index)
                                    persist(candidate)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.red)
                                .help("Delete")
                            }
                            if index < draft.aliases.count - 1 {
                                Divider().opacity(0.25)
                            }
                        }
                        HStack {
                            Spacer()
                            Label("Changes save automatically", systemImage: "checkmark.circle")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }

            if let validationError {
                Text(validationError)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
            } else if let savedMessage {
                Text(savedMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(.green)
            }
        }
        .onAppear {
            reloadSavedAliases()
            targets = Self.loadTargets()
            selectedTarget = targets.first?.ref
        }
        .onReceive(NotificationCenter.default.publisher(for: .settingsWindowDidOpen)) { _ in
            reloadSavedAliases()
        }
    }

    private var gridHeader: some View {
        HStack(spacing: 10) {
            Text("Alias").frame(width: 90, alignment: .leading)
            Text("Shortcut").frame(width: 100, alignment: .leading)
            Text("Target").frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(width: 28, height: 1)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
    }

    private func aliasBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: {
                guard draft.aliases.indices.contains(index) else { return "" }
                return draft.aliases[index].alias
            },
            set: { alias in
                guard draft.aliases.indices.contains(index) else { return }
                var candidate = draft.aliases
                candidate[index].alias = alias
                persist(candidate)
            }
        )
    }

    private func hotkeyBinding(_ index: Int) -> Binding<LauncherHotkey?> {
        Binding(
            get: {
                guard draft.aliases.indices.contains(index) else { return nil }
                return draft.aliases[index].hotkey
            },
            set: { hotkey in
                guard draft.aliases.indices.contains(index) else { return }
                var candidate = draft.aliases
                candidate[index].hotkey = hotkey
                persist(candidate)
            }
        )
    }

    private func targetBinding(_ index: Int) -> Binding<LauncherTargetRef?> {
        Binding(
            get: {
                guard draft.aliases.indices.contains(index) else { return nil }
                return draft.aliases[index].target
            },
            set: { target in
                guard let target, draft.aliases.indices.contains(index) else { return }
                var candidate = draft.aliases
                candidate[index].targetType = target.kind
                candidate[index].targetID = target.id
                persist(candidate)
            }
        )
    }

    private func targetsIncludingUnavailable(for entry: LauncherAlias) -> [AliasTargetOption] {
        guard !targets.contains(where: { $0.ref == entry.target }) else { return targets }
        return targets + [
            AliasTargetOption(
                ref: entry.target,
                title: "Unavailable target",
                detail: entry.targetID
            )
        ]
    }

    private func addEntry() {
        guard let selectedTarget else { return }
        let entry = LauncherAlias(
            alias: newAlias.trimmingCharacters(in: .whitespacesAndNewlines),
            hotkey: newHotkey,
            targetType: selectedTarget.kind,
            targetID: selectedTarget.id
        )
        let candidate = draft.aliases + [entry]
        if persist(candidate) {
            newAlias = ""
            newHotkey = nil
        }
    }

    @discardableResult
    private func persist(_ candidate: [LauncherAlias]) -> Bool {
        switch draft.commit(candidate) {
        case .success:
            validationError = nil
            savedMessage = "Saved automatically."
            return true
        case .failure(let error):
            validationError = error.message
            savedMessage = nil
            NSSound.beep()
            return false
        }
    }

    private func reloadSavedAliases() {
        draft.reload(AliasStore.load())
        validationError = nil
        savedMessage = nil
    }

    private static func loadTargets() -> [AliasTargetOption] {
        var options: [AliasTargetOption] = [
            AliasTargetOption(
                ref: LauncherTargetRef(kind: .launcherCommand, id: "file-search"),
                title: "File Search",
                detail: "Launcher Command"
            ),
            AliasTargetOption(
                ref: LauncherTargetRef(kind: .launcherCommand, id: "clipboard-history"),
                title: "Clipboard History",
                detail: "Launcher Command"
            )
        ]

        options += SystemAction.allCases.map {
            AliasTargetOption(
                ref: LauncherTargetRef(kind: .systemAction, id: $0.id),
                title: $0.title,
                detail: "System Action"
            )
        }
        options += (AICommand.loadAll() ?? []).map {
            AliasTargetOption(
                ref: LauncherTargetRef(kind: .aiCommand, id: $0.id),
                title: $0.name,
                detail: "AI Command"
            )
        }
        options += loadSnippetTargets()
        options += loadAppTargets()
        return options.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private static func loadSnippetTargets() -> [AliasTargetOption] {
        guard let cString = rc_snippets_load() else { return [] }
        defer { rc_free_string(cString) }
        let json = String(cString: cString)
        guard let data = json.data(using: .utf8),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return entries.compactMap { entry in
            guard let id = entry["id"] as? String else { return nil }
            return AliasTargetOption(
                ref: LauncherTargetRef(kind: .snippet, id: id),
                title: entry["name"] as? String ?? "Untitled Snippet",
                detail: "Snippet"
            )
        }
    }

    private static func loadAppTargets() -> [AliasTargetOption] {
        guard let cString = rc_get_all_apps() else { return [] }
        defer { rc_free_string(cString) }
        let json = String(cString: cString)
        guard let data = json.data(using: .utf8),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return entries.compactMap { entry in
            guard let path = entry["path"] as? String else { return nil }
            let bundleID = entry["bundle_id"] as? String
            return AliasTargetOption(
                ref: SearchViewModel.appTargetRef(bundleID: bundleID, path: path),
                title: entry["display_name"] as? String
                    ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent,
                detail: "Application"
            )
        }
    }
}

private struct SearchableTargetPicker: View {
    @Binding var selection: LauncherTargetRef?
    let targets: [AliasTargetOption]

    @State private var isPresented = false
    @State private var filter = ""

    private var filteredTargets: [AliasTargetOption] {
        let normalized = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return targets }
        return targets.filter {
            $0.title.localizedCaseInsensitiveContains(normalized)
                || $0.detail.localizedCaseInsensitiveContains(normalized)
        }
    }

    private var selectedTarget: AliasTargetOption? {
        targets.first { $0.ref == selection }
    }

    var body: some View {
        Button {
            filter = ""
            isPresented.toggle()
        } label: {
            HStack(spacing: 7) {
                Text(selectedTarget?.title ?? "Choose a target")
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(selectedTarget.map { "\($0.title) — \($0.detail)" } ?? "Choose a target")
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 26, maxHeight: 26)
            .background(Color.primary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(spacing: 8) {
                TextField("Filter targets", text: $filter)
                    .textFieldStyle(.roundedBorder)
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(filteredTargets) { target in
                            Button {
                                selection = target.ref
                                isPresented = false
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(target.title)
                                        Text(target.detail)
                                            .font(.system(size: 10))
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if selection == target.ref {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.tint)
                                    }
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        if filteredTargets.isEmpty {
                            Text("No matching targets")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .padding(12)
                        }
                    }
                }
                .frame(maxHeight: 280)
            }
            .padding(10)
            .frame(width: 320)
        }
    }
}

private struct HotkeyRecorderField: NSViewRepresentable {
    @Binding var hotkey: LauncherHotkey?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> HotkeyRecorderTextField {
        let field = HotkeyRecorderTextField()
        field.onChange = { context.coordinator.parent.hotkey = $0 }
        field.hotkey = hotkey
        return field
    }

    func updateNSView(_ field: HotkeyRecorderTextField, context: Context) {
        context.coordinator.parent = self
        field.onChange = { context.coordinator.parent.hotkey = $0 }
        if !field.isRecording {
            field.hotkey = hotkey
        }
    }

    final class Coordinator {
        var parent: HotkeyRecorderField
        init(_ parent: HotkeyRecorderField) {
            self.parent = parent
        }
    }
}

private final class HotkeyRecorderTextField: NSTextField {
    var onChange: ((LauncherHotkey?) -> Void)?
    var isRecording = false
    var hotkey: LauncherHotkey? {
        didSet { updateDisplay() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isEditable = false
        isSelectable = false
        isBezeled = true
        bezelStyle = .roundedBezel
        alignment = .center
        font = .systemFont(ofSize: 12, weight: .medium)
        focusRingType = .exterior
        toolTip = "Click, then press a shortcut. Press Delete to clear."
        updateDisplay()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        isRecording = true
        stringValue = "Press shortcut…"
        NotificationCenter.default.post(name: .shortcutRecordingDidBegin, object: self)
        return true
    }

    override func resignFirstResponder() -> Bool {
        // NSTextField can refuse resignation in some field-editor transitions.
        // Resume global hotkeys regardless so recording never leaves them suspended.
        finishRecording()
        return super.resignFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            finishRecording()
            window?.makeFirstResponder(nil)
            return
        }
        if event.keyCode == 51 || event.keyCode == 117 { // Delete / Forward Delete
            hotkey = nil
            onChange?(nil)
            finishRecording()
            window?.makeFirstResponder(nil)
            return
        }

        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard !modifiers.isEmpty,
              let key = Key(carbonKeyCode: UInt32(event.keyCode))
        else {
            NSSound.beep()
            return
        }

        let value = LauncherHotkey(
            keyCode: UInt32(event.keyCode),
            modifiers: modifiers.carbonFlags,
            display: Self.displayName(key: key, modifiers: modifiers)
        )
        hotkey = value
        onChange?(value)
        finishRecording(recordedKeyCode: value.keyCode, modifierFlags: modifiers)
        window?.makeFirstResponder(nil)
    }

    private func finishRecording(
        recordedKeyCode: UInt32? = nil,
        modifierFlags: NSEvent.ModifierFlags = []
    ) {
        guard isRecording else { return }
        isRecording = false
        updateDisplay()
        var userInfo: [String: NSNumber]?
        if let recordedKeyCode {
            userInfo = [
                ShortcutRecordingInfo.keyCode: NSNumber(value: recordedKeyCode),
                ShortcutRecordingInfo.modifierFlags: NSNumber(value: modifierFlags.rawValue),
            ]
        }
        NotificationCenter.default.post(
            name: .shortcutRecordingDidEnd,
            object: self,
            userInfo: userInfo
        )
    }

    private func updateDisplay() {
        stringValue = hotkey?.display ?? "None"
        textColor = hotkey == nil ? .tertiaryLabelColor : .labelColor
    }

    private static func displayName(key: Key, modifiers: NSEvent.ModifierFlags) -> String {
        var parts: [String] = []
        if modifiers.contains(.command) { parts.append("⌘") }
        if modifiers.contains(.option) { parts.append("⌥") }
        if modifiers.contains(.control) { parts.append("⌃") }
        if modifiers.contains(.shift) { parts.append("⇧") }
        parts.append(key.description)
        return parts.joined(separator: " ")
    }
}
