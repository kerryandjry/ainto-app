// swiftlint:disable file_length type_body_length function_body_length identifier_name line_length cyclomatic_complexity
import AppKit
import Foundation
import AintoCore

/// AI command — loaded from ~/.config/ainto/ai-commands.toml
struct AICommand: Identifiable {
    var id: String
    var name: String
    var icon: String
    var prompt: String  // {selection} will be replaced with selected text

    static func new() -> AICommand {
        AICommand(id: UUID().uuidString, name: "", icon: "sparkle", prompt: "{selection}")
    }

    /// Load all commands from TOML (includes defaults on first run).
    /// Returns nil when the file exists but could not be read — callers must
    /// not persist over a file they failed to load.
    static func loadAll() -> [AICommand]? {
        guard let cStr = rc_ai_commands_load() else { return nil }
        let jsonStr = String(cString: cStr)
        rc_free_string(cStr)

        guard let data = jsonStr.data(using: .utf8),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }

        return entries.map { entry in
            AICommand(
                // Rust fills in any missing id and rewrites the file, so this
                // fallback only covers a genuinely malformed entry.
                id: (entry["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString,
                name: entry["name"] as? String ?? "",
                icon: entry["icon"] as? String ?? "sparkle",
                prompt: entry["prompt"] as? String ?? ""
            )
        }
    }
}

/// Fuzzy match score. Returns 0 if no match.
/// Higher = better match. Mirrors Rust's fuzzy_score logic.
func fuzzyScore(_ query: String, _ target: String) -> Int {
    let q = query.lowercased()
    let t = target.lowercased()
    if t == q { return 200 }
    if t.hasPrefix(q) { return 150 }
    // Word-boundary initials: "iw" → "Improve Writing" (I + W)
    if wordBoundaryMatch(q, target) { return 120 }
    if t.contains(q) { return 100 }
    if fuzzyMatch(q, t) { return 60 + Int(Double(q.count) / Double(t.count) * 40) }
    return 0
}

/// Check if query matches the first letter of each word or camelCase boundary.
/// "iw" matches "Improve Writing", "vsc" matches "Visual Studio Code"
func wordBoundaryMatch(_ query: String, _ target: String) -> Bool {
    let initials = extractWordBoundaries(target)
    let qChars = Array(query.lowercased())
    let iChars = initials.map { Character($0.lowercased()) }
    guard !qChars.isEmpty, !iChars.isEmpty else { return false }
    var qi = 0
    for ic in iChars {
        if qi < qChars.count && ic == qChars[qi] {
            qi += 1
        }
    }
    return qi == qChars.count
}

/// Extract first char + chars after space/hyphen + uppercase in camelCase.
func extractWordBoundaries(_ name: String) -> [Character] {
    var boundaries: [Character] = []
    let chars = Array(name)
    for (i, c) in chars.enumerated() {
        if i == 0 && c.isLetter {
            boundaries.append(c)
        } else if c.isUppercase && i > 0 && chars[i-1].isLowercase {
            boundaries.append(c)
        } else if i > 0 && (chars[i-1] == " " || chars[i-1] == "-" || chars[i-1] == "_") && c.isLetter {
            boundaries.append(c)
        }
    }
    return boundaries
}

/// Simple fuzzy match: query chars appear in order in target.
/// Returns true if all characters of query appear in target in order.
func fuzzyMatch(_ query: String, _ target: String) -> Bool {
    if query.isEmpty { return true }
    let q = query.lowercased()
    let t = target.lowercased()
    var qi = q.startIndex
    for tc in t {
        if tc == q[qi] {
            qi = q.index(after: qi)
            if qi == q.endIndex { return true }
        }
    }
    return false
}

/// Sendable wrapper for UnsafeMutableRawPointer (for passing to Task.detached).
struct SendablePointer: @unchecked Sendable {
    let ptr: UnsafeMutableRawPointer
}

/// A message in the Claude conversation.
struct ClaudeMessage: Identifiable {
    let id = UUID()
    let role: ClaudeRole
    var text: String
}

enum ClaudeRole {
    case user
    case assistant
}

/// Active page in the launcher.
enum LauncherPage: Equatable {
    case main
    case clipboard
    case snippets
    case aiCommands
    case fileSearch
    case systemConfirmation
    case claude
}

enum SearchMode: Equatable {
    case apps    // default: search apps/commands
    case claude  // Tab: ask Claude
}

enum SelectionCaptureResult {
    case success(String)
    case failure(String)
}

/// An action available for a search result.
struct ActionItem: Identifiable {
    let id = UUID()
    let title: String
    let icon: String // SF Symbol name
    let shortcut: String? // e.g. "⌘ O" for display
    var keepPanel: Bool = false // true = don't hide panel after action (for navigation)
    let action: () -> Void
}

/// Search result model for the UI.
struct SearchResult: Identifiable {
    let id = UUID()
    let title: String
    var subtitle: String
    let icon: NSImage?
    let systemIcon: String? // fallback SF Symbol name
    var score: Int = 0 // higher = better match, used for unified sorting
    var targetRef: LauncherTargetRef? = nil
    let action: () -> Void
    var actions: [ActionItem] = [] // Cmd+K to show
    var alternateAction: (() -> Void)? // Cmd+Enter, used by Instant Answers
    var instantAnswerID: String?
    var instantAnswerIsPending = false
    var keepsPanelOpenAfterAction = false

    /// Resolved icon: app icon or SF Symbol fallback
    var displayIcon: NSImage {
        if let icon { return icon }
        if let name = systemIcon,
           let img = NSImage(systemSymbolName: name, accessibilityDescription: nil) {
            return img
        }
        return NSImage(systemSymbolName: "app.fill", accessibilityDescription: nil)
            ?? NSImage()
    }
}

/// Clipboard entry decoded from Rust JSON.
struct ClipboardItem: Identifiable {
    let id: Int64
    let contentType: String // "text" | "image" | "file"
    let text: String?
    let filePath: String?
    let imageFilename: String?
    let hash: UInt64
    let sourceApp: String?
    let lastCopiedAt: Int64
    let copyCount: UInt32

    var displayTitle: String {
        switch contentType {
        case "image": return "Image"
        case "file":
            if let path = filePath {
                return (path as NSString).lastPathComponent
            }
            return "File"
        default:
            return text.map { Self.firstContentLine(of: $0) } ?? ""
        }
    }

    /// First line of actual content for the list: skips leading blank lines and
    /// indentation so the row shows real data instead of empty space. Scans only
    /// the leading whitespace plus that first line (capped) — never splits the
    /// whole string, which matters for very large clipboard entries.
    private static func firstContentLine(of text: String, maxChars: Int = 500) -> String {
        var start = text.startIndex
        while start < text.endIndex, text[start].isWhitespace {
            start = text.index(after: start)
        }
        guard start < text.endIndex else { return "" }
        var end = start
        var count = 0
        while end < text.endIndex, !text[end].isNewline, count < maxChars {
            end = text.index(after: end)
            count += 1
        }
        return String(text[start..<end])
    }

    var iconName: String {
        switch contentType {
        case "image": return "photo"
        case "file": return "doc.fill"
        default: return "doc.text"
        }
    }

    var contentTypeLabel: String {
        switch contentType {
        case "image": return "Image"
        case "file": return "File"
        default: return "Text"
        }
    }

    var date: Date {
        Date(timeIntervalSince1970: TimeInterval(lastCopiedAt))
    }

    var relativeTime: String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "Just now" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        return "\(Int(interval / 86400))d ago"
    }

    /// Time group for section headers.
    var timeGroup: String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        return "Earlier"
    }

    /// Full image path on disk.
    var imagePath: String? {
        guard let filename = imageFilename else { return nil }
        guard !filename.contains("/"), !filename.contains("..") else { return nil }
        guard let cStr = rc_clipboard_image_dir() else { return nil }
        let dir = String(cString: cStr)
        rc_free_string(cStr)
        return (dir as NSString).appendingPathComponent(filename)
    }

    /// Load NSImage for display (file icon or image thumbnail).
    var displayImage: NSImage? {
        switch contentType {
        case "file":
            if let path = filePath {
                return NSWorkspace.shared.icon(forFile: path)
            }
            return nil
        case "image":
            if let path = imagePath {
                return NSImage(contentsOfFile: path)
            }
            return nil
        default:
            return nil
        }
    }
}

/// Snippet item model.
struct SnippetItem: Identifiable {
    var id: String
    var name: String
    var keyword: String
    var expansion: String

    static func new() -> SnippetItem {
        SnippetItem(id: UUID().uuidString, name: "", keyword: "", expansion: "")
    }
}

/// ViewModel managing search state and Rust FFI calls.
@MainActor
final class SearchViewModel: ObservableObject {
    @Published var query: String = ""
    @Published var results: [SearchResult] = []
    @Published var selectedIndex: Int = 0
    @Published var shouldSelectAll = false
    @Published var page: LauncherPage = .main
    @Published var searchMode: SearchMode = .apps

    let fileSearch = FileSearchService()
    @Published var pendingSystemAction: SystemAction?
    @Published var systemActionError: String?
    @Published var isExecutingSystemAction = false
    var aliases: [LauncherAlias] = []
    var onSystemActionCompleted: (() -> Void)?

    // Claude state
    @Published var claudeMessages: [ClaudeMessage] = []
    @Published var claudeIsStreaming = false
    private var claudeSession: UnsafeMutableRawPointer?
    private var claudeSessionId: String?

    // Snippet state.
    // `snippetsLoaded` stays false until the file has been read successfully;
    // it guards saving so an unreadable file is never overwritten with an
    // empty list. Same pattern as `hasLoaded` in SettingsView.
    private var snippetsLoaded = false
    @Published var snippets: [SnippetItem] = []
    @Published var snippetSelectedIndex: Int = 0
    @Published var snippetFilter: String = ""
    @Published var isEditingSnippet = false
    @Published var editingSnippet: SnippetItem?

    // AI master switch (config: ai_enabled). When false, all AI surfaces
    // are hidden from the launcher.
    @Published var aiEnabled: Bool = true

    // Home visibility is independent from searchability. These values only
    // affect the empty-query list; search, aliases, and shortcuts remain active.
    private var homeClipboardHistory = true
    private var homeFileSearch = true
    private var homeSnippets = true
    private var homeAICommands = true
    private var homeAICommandIDs: Set<String>?

    // Agent CLI binary to spawn for AI sessions (config: claude_binary).
    var claudeBinary: String = "claude"

    /// Seconds the launcher may stay on a sub-page while hidden before the next
    /// invocation returns to search. `0` returns immediately; a negative value
    /// stays put. Mirrors `pop_to_root_seconds` in config.toml.
    private var popToRootSeconds: Int = 90

    // AI Commands state
    private var aiCommandsLoaded = false
    @Published var aiCommands: [AICommand] = []
    @Published var aiCommandSelectedIndex: Int = 0
    @Published var aiCommandFilter: String = ""
    @Published var isEditingAICommand = false
    @Published var editingAICommand: AICommand?

    // Clipboard state
    @Published var clipboardItems: [ClipboardItem] = []
    /// Not @Published — selection changes are handled directly by NSTableView
    /// to avoid triggering SwiftUI re-renders on every arrow key press.
    var clipboardSelectedIndex: Int = 0
    private let clipboardPageSize = 50
    /// Number of raw SQL rows consumed. This is intentionally separate from
    /// `clipboardItems.count`, because rows duplicated by a concurrent insert
    /// are discarded from the UI but still advance offset pagination.
    private var clipboardFetchOffset = 0
    private(set) var clipboardHasMore = true
    var clipboardFilter: String = "" {
        didSet {
            if clipboardFilter.isEmpty {
                clipboardFilterTask?.cancel()
                if !debouncedClipboardFilter.isEmpty {
                    debouncedClipboardFilter = ""
                    // Reload unfiltered from SQLite
                    loadClipboardItems()
                }
            } else {
                scheduleClipboardFilter()
            }
        }
    }
    @Published var clipboardTypeFilter: ClipboardTypeFilter = .all {
        didSet {
            guard oldValue != clipboardTypeFilter else { return }
            // Re-query: the filter is applied in SQL, so switching it needs a
            // fresh page rather than a thinner view of the one already loaded.
            reloadClipboardPage()
        }
    }
    @Published var debouncedClipboardFilter: String = ""
    private var clipboardFilterTask: DispatchWorkItem?

    // Action panel
    @Published var showActionPanel = false

    /// Icon cache keyed by app path
    private var iconCache: [String: NSImage] = [:]
    private let instantAnswerService = InstantAnswerService()
    private var instantAnswerTask: Task<Void, Never>?

    /// Callback to hide panel and paste to frontmost app (set by SearchPanel)
    var onPasteAndHide: (() -> Void)?

    /// Callback to move clipboard table selection (set by ClipboardTableView).
    /// Bypasses @Published to avoid SwiftUI re-render on every arrow key.
    var onClipboardSelectionMove: ((_ newIndex: Int) -> Void)?

    /// Callback to reload text expander snippets (set by AppDelegate)
    var onSnippetsChanged: (() -> Void)?

    var statusText: String {
        switch results.count {
        case 0: return "No results"
        case 1: return "1 result"
        default: return "\(results.count) results"
        }
    }

    func clearQuery() {
        query = ""
        results = []
        selectedIndex = 0
    }

    func selectAll() {
        shouldSelectAll = true
        // Refresh default results if query is empty
        if query.isEmpty {
            results = buildDefaultResults()
        }
    }

    /// Re-scan installed applications in the background, then refresh the
    /// visible results. Picks up apps installed (or removed) since launch,
    /// since `rc_discover_apps` otherwise only runs once at startup.
    /// Runs off the main thread so panel appearance isn't blocked.
    func refreshApps() {
        DispatchQueue.global(qos: .userInitiated).async {
            let _ = rc_discover_apps(false)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.page == .main else { return }
                if self.query.isEmpty {
                    self.results = self.buildDefaultResults()
                } else {
                    self.performSearch(query: self.query)
                }
            }
        }
    }

    // MARK: - Navigation

    func goToSnippets() {
        page = .snippets
        snippetFilter = ""
        snippetSelectedIndex = 0
        isEditingSnippet = false
        editingSnippet = nil
        loadSnippets()
        focusFilterField()
    }

    func goToAICommands() {
        page = .aiCommands
        aiCommandFilter = ""
        aiCommandSelectedIndex = 0
        isEditingAICommand = false
        editingAICommand = nil
        loadAICommands()
        focusFilterField()
    }

    func goToClipboard() {
        page = .clipboard
        clipboardFilter = ""
        debouncedClipboardFilter = ""
        clipboardSelectedIndex = 0
        loadClipboardItems()
        focusFilterField()
    }

    func goToFileSearch() {
        page = .fileSearch
        fileSearch.clear()
        fileSearch.reloadConfiguration()
        focusFilterField()
    }

    func reloadAliases() {
        aliases = AliasStore.load()
    }

    func prepareForPanelHide() {
        // A pending confirmation must not outlive the panel. Reopening on a
        // stale "Restart?" prompt leaves a destructive action one Return away,
        // with nothing to show how long it has been sitting there. An action
        // already executing is left alone, matching `goBack()`.
        if page == .systemConfirmation, !isExecutingSystemAction {
            pendingSystemAction = nil
            systemActionError = nil
        } else if page == .fileSearch {
            fileSearch.clear()
        } else {
            return
        }
        page = .main
        searchMode = .apps
        query = ""
        selectedIndex = 0
        results = buildDefaultResults()
    }

    func goBack() {
        if page == .systemConfirmation && isExecutingSystemAction { return }
        if page == .claude {
            claudeCancel()
            claudeMessages.removeAll()
            claudeSessionId = nil // start fresh next time
        }
        if page == .aiCommands && isEditingAICommand {
            cancelEditingAICommand()
            return
        }
        if page == .fileSearch {
            fileSearch.clear()
        }
        pendingSystemAction = nil
        systemActionError = nil
        clipboardFilter = "" // didSet handles cancel + debouncedClipboardFilter
        page = .main
        searchMode = .apps
        // TextField is always in the view hierarchy (ZStack), so focus immediately.
        // selectAll is chained after focus succeeds to avoid race conditions.
        focusFilterField(then: { [weak self] in self?.selectAll() })
    }

    /// Return to search when the launcher has been hidden long enough that the
    /// next invocation is a new task rather than a continuation of the last one.
    ///
    /// Held back whenever popping would throw work away: a half-written snippet
    /// or AI command that has not been saved, or a Claude response still
    /// streaming. Those stay put however long the panel was hidden.
    /// Returns whether it popped, so the caller can re-place a panel whose
    /// height is about to change with the page.
    @discardableResult
    func popToRootIfStale(hiddenFor interval: TimeInterval) -> Bool {
        guard page != .main else { return false }
        guard !isEditingSnippet, !isEditingAICommand, !claudeIsStreaming else { return false }
        guard popToRootSeconds >= 0, interval >= TimeInterval(popToRootSeconds) else { return false }
        popToRoot()
        return true
    }

    /// `goBack()` plus the query, so a stale search string does not come back
    /// with the search page.
    private func popToRoot() {
        goBack()
        query = ""
        selectedIndex = 0
        results = buildDefaultResults()
    }

    // MARK: - Main search

    func performSearch(query: String) {
        instantAnswerTask?.cancel()
        instantAnswerTask = nil
        guard !query.isEmpty else {
            results = buildDefaultResults()
            selectedIndex = 0
            return
        }

        // Check for /cc prefix (Claude Code)
        if query.hasPrefix("/cc ") {
            let prompt = String(query.dropFirst(4))
            results = [
                SearchResult(
                    title: "Ask Claude: \(prompt)",
                    subtitle: "Claude Code",
                    icon: nil,
                    systemIcon: "bubble.left.fill"
                ) { [weak self] in
                    self?.startClaude(prompt: prompt)
                }
            ]
            selectedIndex = 0
            return
        }

        // Search apps via Rust FFI
        var appResults: [SearchResult] = []

        if let cStr = rc_search_apps(query) {
            let jsonStr = String(cString: cStr)
            rc_free_string(cStr)

            if let data = jsonStr.data(using: .utf8),
               let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                appResults = entries.prefix(8).map { entry in
                    let name = entry["display_name"] as? String ?? ""
                    let path = entry["path"] as? String ?? ""
                    let bundleID = entry["bundle_id"] as? String
                    let ranking = entry["ranking"] as? Int ?? 0
                    let isPinned = entry["is_favourite"] as? Bool ?? false
                    let icon = self.loadAppIcon(path: path)
                    var result = SearchResult(
                        title: name,
                        subtitle: "Application",
                        icon: icon,
                        systemIcon: "app.fill",
                        score: fuzzyScore(query, name) + ranking,
                        targetRef: Self.appTargetRef(bundleID: bundleID, path: path)
                    ) {
                        NSWorkspace.shared.open(URL(fileURLWithPath: path))
                        rc_update_ranking(path)
                    }
                    result.actions = self.appActions(path: path, isPinned: isPinned)
                    return result
                }
            }
        }

        // Search snippets. Uses the in-memory copy — refreshed when the panel
        // opens and by the config watcher — so a keystroke never reads disk.
        let snippetResults: [SearchResult] = snippets
            .filter { fuzzyMatch(query, $0.name) || fuzzyMatch(query, $0.keyword) }
            .prefix(5)
            .map { snippet in
                let expansion = snippet.expansion
                return SearchResult(
                    title: snippet.name,
                    subtitle: "Snippet: \(snippet.keyword)",
                    icon: nil,
                    systemIcon: "doc.text.fill",
                    targetRef: LauncherTargetRef(kind: .snippet, id: snippet.id)
                ) { [weak self] in
                    self?.expandAndPasteSnippet(expansion)
                }
            }

        // Built-in commands that fuzzy match
        var commandResults: [SearchResult] = []
        let q = query.lowercased()

        // AI commands (built-in + custom) — fuzzy match. Hidden entirely when
        // the AI master switch is off.
        if aiEnabled {
            // Rank once per command rather than inside the sort comparator,
            // which called it O(n log n) times per keystroke.
            let rankedAICommands = aiCommands
                .filter { fuzzyMatch(q, $0.name) }
                .map { (command: $0, rank: self.commandRanking(for: $0)) }
                .sorted { $0.rank > $1.rank }
            for entry in rankedAICommands.prefix(6) {
                let command = entry.command
                let cmdScore = fuzzyScore(q, command.name) + entry.rank
                var result = SearchResult(
                    title: command.name,
                    subtitle: "AI Command",
                    icon: nil,
                    systemIcon: command.icon,
                    score: cmdScore,
                    targetRef: LauncherTargetRef(kind: .aiCommand, id: command.id)
                ) { [weak self] in
                    self?.incrementCommandRanking(command)
                    self?.executeAICommand(command)
                }
                result.actions = aiCommandActions(for: command)
                commandResults.append(result)
            }

            if fuzzyMatch(q, "ai commands") || fuzzyMatch(q, "manage ai commands") {
                commandResults.append(SearchResult(
                    title: "AI Commands",
                    subtitle: "Manage AI Commands",
                    icon: nil,
                    systemIcon: "sparkle",
                    score: fuzzyScore(q, "AI Commands")
                ) { [weak self] in
                    self?.goToAICommands()
                })
            }
        }

        if fuzzyMatch(q, "snippets") {
            let r = SearchResult(
                title: "Snippets",
                subtitle: "Command",
                icon: nil,
                systemIcon: "text.quote",
                score: fuzzyScore(query, "Snippets") + commandRanking(for: "Snippets")
            ) { [weak self] in
                self?.incrementCommandRanking("Snippets")
                self?.goToSnippets()
            }
            commandResults.append(r)
        }

        if fuzzyMatch(q, "clipboard history") {
            let r = SearchResult(
                title: "Clipboard History",
                subtitle: "Command",
                icon: nil,
                systemIcon: "doc.on.clipboard",
                score: fuzzyScore(query, "Clipboard History") + commandRanking(for: "Clipboard History"),
                targetRef: LauncherTargetRef(kind: .launcherCommand, id: "clipboard-history")
            ) { [weak self] in
                self?.incrementCommandRanking("Clipboard History")
                self?.goToClipboard()
            }
            commandResults.append(r)
        }

        if q == "f" || fuzzyMatch(q, "file search") {
            commandResults.append(fileSearchCommandResult(score: q == "f" ? 300 : fuzzyScore(q, "File Search")))
        }

        for action in SystemAction.allCases where fuzzyMatch(q, action.title) {
            commandResults.append(systemActionResult(action, score: fuzzyScore(q, action.title)))
        }

        var allResults = appResults + commandResults + snippetResults
        if let aliasResult = resolvedAliasResult(for: query) {
            if let target = aliasResult.targetRef {
                allResults.removeAll { $0.targetRef == target }
            }
            allResults.append(aliasResult)
        }
        allResults.sort { $0.score > $1.score }
        results = Array(allResults.prefix(20))
        if let pendingAnswer = instantAnswerService.pendingAnswer(for: query) {
            results.append(instantAnswerResult(pendingAnswer))
            results.sort { $0.score > $1.score }
            results = Array(results.prefix(20))
        }
        selectedIndex = 0
        scheduleInstantAnswers(for: query)
    }

    private func scheduleInstantAnswers(for query: String) {
        instantAnswerTask = Task { [weak self] in
            guard let self else { return }
            let answers = await instantAnswerService.answers(for: query)
            guard !Task.isCancelled, self.query == query, self.page == .main else { return }
            let selectedResultID = self.selectedIndex > 0 && self.results.indices.contains(self.selectedIndex)
                ? self.results[self.selectedIndex].id
                : nil
            var updated = self.results.filter { $0.instantAnswerID == nil }
            updated.append(contentsOf: answers.map { self.instantAnswerResult($0) })
            updated.sort { $0.score > $1.score }
            self.results = Array(updated.prefix(20))
            if let selectedResultID,
               let preservedIndex = self.results.firstIndex(where: { $0.id == selectedResultID }) {
                self.selectedIndex = preservedIndex
            } else {
                self.selectedIndex = 0
            }
        }
    }

    private func instantAnswerResult(_ answer: InstantAnswer) -> SearchResult {
        let copy = { [weak self] (value: String) in
            self?.copyInstantAnswer(value)
        }
        var result = SearchResult(
            title: answer.title,
            subtitle: answer.subtitle,
            icon: nil,
            systemIcon: answer.systemIcon,
            score: 9_000
        ) { [weak self] in
            if let value = answer.copyText {
                copy(value)
            } else if answer.canRefresh {
                self?.refreshCurrencyInstantAnswer()
            }
        }
        result.instantAnswerID = answer.id
        result.instantAnswerIsPending = answer.isPending
        result.keepsPanelOpenAfterAction = answer.isPending || (answer.copyText == nil && answer.canRefresh)
        if let value = answer.copyText {
            result.alternateAction = { [weak self] in self?.pasteInstantAnswer(value) }
            result.actions = [
                ActionItem(title: "Copy Result", icon: "doc.on.doc", shortcut: "↵") {
                    copy(value)
                },
                ActionItem(
                    title: answer.kind == .calculator ? "Copy Expression" : "Copy Source Amount",
                    icon: "text.quote",
                    shortcut: nil
                ) {
                    copy(answer.input)
                },
                ActionItem(title: "Paste Result", icon: "doc.on.clipboard", shortcut: "⌘ ↵") { [weak self] in
                    self?.pasteInstantAnswer(value)
                }
            ]
        }
        if let swapQuery = answer.swapQuery {
            result.actions.append(ActionItem(
                title: "Swap Currencies",
                icon: "arrow.left.arrow.right",
                shortcut: nil,
                keepPanel: true
            ) { [weak self] in
                self?.query = swapQuery
            })
        }
        if answer.canRefresh {
            result.actions.append(ActionItem(
                title: "Refresh Rate",
                icon: "arrow.clockwise",
                shortcut: nil,
                keepPanel: true
            ) { [weak self] in
                self?.refreshCurrencyInstantAnswer()
            })
        }
        if let sourceURL = answer.sourceURL {
            result.actions.append(ActionItem(
                title: "View Rate Source",
                icon: "safari",
                shortcut: nil
            ) {
                NSWorkspace.shared.open(sourceURL)
            })
        }
        return result
    }

    private func refreshCurrencyInstantAnswer() {
        let currentQuery = query
        Task { [weak self] in
            guard let self else { return }
            let refreshed = await self.instantAnswerService.refreshCurrencyRates()
            guard refreshed, self.query == currentQuery else { return }
            self.performSearch(query: currentQuery)
        }
    }

    private func copyInstantAnswer(_ value: String) {
        PasteboardAccess.withPasteboard { pasteboard in
            pasteboard.clearContents()
            pasteboard.setString(value, forType: .string)
        }
    }

    private func pasteInstantAnswer(_ value: String) {
        copyInstantAnswer(value)
        onPasteAndHide?()
    }

    func moveSelection(by offset: Int) {
        switch page {
        case .clipboard:
            let count = filteredClipboardItems.count
            guard count > 0 else { return }
            clipboardSelectedIndex = max(0, min(clipboardSelectedIndex + offset, count - 1))
            onClipboardSelectionMove?(clipboardSelectedIndex)
        case .snippets:
            let count = filteredSnippets.count
            guard count > 0 else { return }
            snippetSelectedIndex = max(0, min(snippetSelectedIndex + offset, count - 1))
        case .aiCommands:
            let count = filteredAICommands.count
            guard count > 0 else { return }
            aiCommandSelectedIndex = max(0, min(aiCommandSelectedIndex + offset, count - 1))
        case .fileSearch:
            fileSearch.moveSelection(by: offset)
        case .main:
            guard !results.isEmpty else { return }
            selectedIndex = max(0, min(selectedIndex + offset, results.count - 1))
        case .systemConfirmation, .claude:
            break // no list navigation on these pages
        }
    }

    func openSelected() {
        switch page {
        case .clipboard:
            pasteSelectedClipboardItem()
        case .snippets:
            expandSelectedSnippet()
        case .aiCommands:
            executeSelectedAICommand()
        case .fileSearch:
            fileSearch.openSelected()
        case .systemConfirmation:
            confirmSystemAction()
        case .main:
            guard selectedIndex < results.count else { return }
            results[selectedIndex].action()
        case .claude:
            break
        }
    }

    // MARK: - Clipboard

    /// Reload clipboard items only if the clipboard page is currently visible.
    func reloadClipboardIfVisible() {
        guard page == .clipboard else { return }
        loadClipboardItems()
    }

    private func scheduleClipboardFilter() {
        clipboardFilterTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.debouncedClipboardFilter = self.clipboardFilter
            self.reloadClipboardPage()
        }
        clipboardFilterTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: task)
    }

    func loadClipboardItems() {
        reloadClipboardPage()
    }

    /// Fetch the first page under the current text and type filters.
    private func reloadClipboardPage() {
        let query = debouncedClipboardFilter.isEmpty ? nil : debouncedClipboardFilter
        let firstPage = fetchClipboardItems(query: query, offset: 0)
        clipboardFetchOffset = firstPage.count
        clipboardHasMore = firstPage.count >= clipboardPageSize
        clipboardItems = deduplicatedClipboardItems(firstPage)
        clipboardSelectedIndex = 0
        rebuildFilteredClipboardItems()
    }

    /// Load next page and append to existing items.
    func loadMoreClipboardItems() {
        guard clipboardHasMore else { return }
        let query = debouncedClipboardFilter.isEmpty ? nil : debouncedClipboardFilter
        var existingIDs = Set(clipboardItems.map(\.id))

        // An insert between offset-based queries can shift a row into the next
        // page. Consume duplicate-only pages until we find a new row or reach
        // the end, while advancing by every raw row returned from SQLite.
        while clipboardHasMore {
            let page = fetchClipboardItems(query: query, offset: clipboardFetchOffset)
            clipboardFetchOffset += page.count
            clipboardHasMore = page.count >= clipboardPageSize

            let uniquePage = page.filter { existingIDs.insert($0.id).inserted }
            if !uniquePage.isEmpty {
                clipboardItems.append(contentsOf: uniquePage)
                break
            }
            if page.isEmpty { break }
        }
        rebuildFilteredClipboardItems()
    }

    private func deduplicatedClipboardItems(_ items: [ClipboardItem]) -> [ClipboardItem] {
        var seen = Set<Int64>()
        return items.filter { seen.insert($0.id).inserted }
    }

    /// Fetch clipboard items from Rust/SQLite with optional search query.
    private func fetchClipboardItems(query: String?, offset: Int) -> [ClipboardItem] {
        let cStr: UnsafePointer<CChar>?
        let contentType = clipboardTypeFilter.contentType
        if let query, !query.isEmpty {
            cStr = rc_clipboard_search_paged(query, UInt64(clipboardPageSize), UInt64(offset), contentType)
        } else {
            cStr = rc_clipboard_get_recent_paged(UInt64(clipboardPageSize), UInt64(offset), contentType)
        }
        guard let cStr else { return [] }
        let jsonStr = String(cString: cStr)
        rc_free_string(cStr)

        guard let data = jsonStr.data(using: .utf8),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }

        return entries.map { entry in
            ClipboardItem(
                id: entry["id"] as? Int64 ?? 0,
                contentType: entry["content_type"] as? String ?? "text",
                text: entry["text"] as? String,
                filePath: entry["file_path"] as? String,
                imageFilename: entry["image_filename"] as? String,
                hash: (entry["hash"] as? NSNumber)?.uint64Value ?? 0,
                sourceApp: entry["source_app"] as? String,
                lastCopiedAt: entry["last_copied_at"] as? Int64 ?? 0,
                copyCount: (entry["copy_count"] as? NSNumber)?.uint32Value ?? 0
            )
        }
    }

    /// Cached filtered result + derived data — recalculated only when filter
    /// inputs change, not on every SwiftUI body evaluation.
    @Published private(set) var filteredClipboardItems: [ClipboardItem] = []
    private(set) var clipboardGroupedItems: [String: [ClipboardItem]] = [:]
    private(set) var clipboardGroupedKeys: [String] = []
    private(set) var clipboardIndexMap: [Int64: Int] = [:]

    private func rebuildFilteredClipboardItems() {
        // Both the text and type filters are applied in SQL, so the loaded page
        // is already the result set — only the derived views are rebuilt here.
        let items = clipboardItems
        filteredClipboardItems = items

        // Rebuild derived data (used by ClipboardView)
        let grouped = Dictionary(grouping: items) { $0.timeGroup }
        clipboardGroupedItems = grouped
        let order = ["Today": 0, "Yesterday": 1, "Earlier": 2]
        clipboardGroupedKeys = grouped.keys.sorted { (order[$0] ?? 3) < (order[$1] ?? 3) }
        // `uniquingKeysWith` rather than `uniqueKeysWithValues`: pages are fetched
        // by offset, so an insert between two fetches can shift the window and
        // return a row twice. A duplicate must not trap.
        clipboardIndexMap = Dictionary(
            items.enumerated().map { ($1.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    func pasteSelectedClipboardItem() {
        let items = filteredClipboardItems
        guard clipboardSelectedIndex < items.count else { return }
        let item = items[clipboardSelectedIndex]

        PasteboardAccess.withPasteboard { pasteboard in
            pasteboard.clearContents()

            switch item.contentType {
            case "text":
                if let text = item.text {
                    pasteboard.setString(text, forType: .string)
                }
            case "file":
                if let path = item.filePath {
                    let url = URL(fileURLWithPath: path) as NSURL
                    pasteboard.writeObjects([url])
                }
            case "image":
                if let path = item.imagePath, let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
                    pasteboard.setData(data, forType: .png)
                }
            default:
                break
            }
        }

        // Hide panel and paste into the previously focused app
        onPasteAndHide?()
    }

    func deleteClipboardItem(id: Int64) {
        let _ = rc_clipboard_delete(id)
        loadClipboardItems()
    }

    // MARK: - Snippets

    func loadSnippets() {
        // A later reload can fail after an earlier one succeeded. Close the
        // save gate before every attempt so stale in-memory data can never
        // overwrite a file that is currently unreadable.
        snippetsLoaded = false
        guard let cStr = rc_snippets_load() else { return }
        let jsonStr = String(cString: cStr)
        rc_free_string(cStr)

        guard let data = jsonStr.data(using: .utf8),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }

        snippets = entries.map { entry in
            SnippetItem(
                id: entry["id"] as? String ?? UUID().uuidString,
                name: entry["name"] as? String ?? "",
                keyword: entry["keyword"] as? String ?? "",
                expansion: entry["expansion"] as? String ?? ""
            )
        }
        snippetsLoaded = true
        snippetSelectedIndex = 0
    }

    func saveSnippets() {
        // Never write over a file we could not read.
        guard snippetsLoaded else { return }
        let jsonArray: [[String: Any]] = snippets.map { s in
            ["id": s.id, "name": s.name, "keyword": s.keyword, "expansion": s.expansion]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: jsonArray),
              let jsonStr = String(data: data, encoding: .utf8) else { return }
        let _ = rc_snippets_save(jsonStr)
        onSnippetsChanged?()
    }

    var filteredSnippets: [SnippetItem] {
        if snippetFilter.isEmpty { return snippets }
        let q = snippetFilter.lowercased()
        return snippets.filter {
            $0.name.lowercased().contains(q) || $0.keyword.lowercased().contains(q)
        }
    }

    func addSnippet() {
        editingSnippet = .new()
        isEditingSnippet = true
    }

    func editSelectedSnippet() {
        let items = filteredSnippets
        guard snippetSelectedIndex < items.count else { return }
        editingSnippet = items[snippetSelectedIndex]
        isEditingSnippet = true
    }

    func saveEditingSnippet() {
        guard let editing = editingSnippet else { return }
        if let idx = snippets.firstIndex(where: { $0.id == editing.id }) {
            snippets[idx] = editing
        } else {
            snippets.append(editing)
        }
        saveSnippets()
        isEditingSnippet = false
        editingSnippet = nil
        focusFilterField()
    }

    func cancelEditingSnippet() {
        isEditingSnippet = false
        editingSnippet = nil
        focusFilterField()
    }

    func deleteSnippet(id: String) {
        snippets.removeAll { $0.id == id }
        saveSnippets()
        if snippetSelectedIndex >= filteredSnippets.count {
            snippetSelectedIndex = max(0, filteredSnippets.count - 1)
        }
    }

    func expandSelectedSnippet() {
        let items = filteredSnippets
        guard snippetSelectedIndex < items.count else { return }
        expandAndPasteSnippet(items[snippetSelectedIndex].expansion)
    }

    /// Expand a snippet's placeholders, put the result on the pasteboard,
    /// and paste it into the frontmost app.
    func expandAndPasteSnippet(_ expansion: String) {
        let clipboardText = PasteboardAccess.withPasteboard { pasteboard in
            pasteboard.string(forType: .string)
        }
        guard let cStr = rc_snippet_expand(expansion, clipboardText) else { return }
        let expanded = String(cString: cStr)
        rc_free_string(cStr)
        PasteboardAccess.withPasteboard { pasteboard in
            pasteboard.clearContents()
            pasteboard.setString(expanded, forType: .string)
        }
        onPasteAndHide?()
    }

    // MARK: - AI Commands

    func loadAICommands() {
        // Keep saves disabled unless this exact reload succeeded. Otherwise an
        // external malformed edit could be replaced by stale in-memory data.
        aiCommandsLoaded = false
        guard let loaded = AICommand.loadAll() else { return }
        aiCommands = loaded
        aiCommandsLoaded = true
        aiCommandSelectedIndex = 0
    }

    /// Load AI settings (`ai_enabled` master switch and the agent CLI binary)
    /// from config.toml. Called at startup and each time the panel opens, so
    /// changes in Settings take effect the next time the launcher is shown.
    func loadAISettings() {
        guard let cStr = rc_config_load() else { return }
        let jsonStr = String(cString: cStr)
        rc_free_string(cStr)
        guard let data = jsonStr.data(using: .utf8),
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        aiEnabled = config["ai_enabled"] as? Bool ?? true
        claudeBinary = (config["claude_binary"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "claude"
        homeClipboardHistory = config["home_clipboard_history"] as? Bool ?? true
        homeFileSearch = config["home_file_search"] as? Bool ?? true
        homeSnippets = config["home_snippets"] as? Bool ?? true
        homeAICommands = config["home_ai_commands"] as? Bool ?? true
        homeAICommandIDs = (config["home_ai_command_ids"] as? [String]).map(Set.init)
        reloadAliases()
        fileSearch.reloadConfiguration()
        popToRootSeconds = config["pop_to_root_seconds"] as? Int ?? 90
        exitAISurfacesIfDisabled()
    }

    /// When AI is disabled, leave any active AI surface (Claude chat or the AI
    /// Commands page) so the launcher doesn't reopen mid-conversation or stuck
    /// on a now-hidden page. No-op while AI is enabled.
    private func exitAISurfacesIfDisabled() {
        guard !aiEnabled else { return }
        if page == .claude {
            claudeCancel()
            claudeMessages.removeAll()
            claudeSessionId = nil
        }
        if page == .claude || page == .aiCommands {
            page = .main
        }
        searchMode = .apps
    }

    func saveAICommands() {
        // Never write over a file we could not read.
        guard aiCommandsLoaded else { return }
        let jsonArray: [[String: Any]] = aiCommands.map { cmd in
            ["id": cmd.id, "name": cmd.name, "icon": cmd.icon, "prompt": cmd.prompt]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: jsonArray),
              let jsonStr = String(data: data, encoding: .utf8) else { return }
        let _ = rc_ai_commands_save(jsonStr)
    }

    var filteredAICommands: [AICommand] {
        if aiCommandFilter.isEmpty { return aiCommands }
        let q = aiCommandFilter.lowercased()
        return aiCommands.filter { $0.name.lowercased().contains(q) }
    }

    func addAICommand() {
        editingAICommand = .new()
        isEditingAICommand = true
    }

    func editSelectedAICommand() {
        let items = filteredAICommands
        guard aiCommandSelectedIndex < items.count else { return }
        editingAICommand = items[aiCommandSelectedIndex]
        isEditingAICommand = true
    }

    func saveEditingAICommand() {
        guard let editing = editingAICommand else { return }
        if let idx = aiCommands.firstIndex(where: { $0.id == editing.id }) {
            aiCommands[idx] = editing
        } else {
            aiCommands.append(editing)
        }
        saveAICommands()
        isEditingAICommand = false
        editingAICommand = nil
        focusFilterField()
    }

    func cancelEditingAICommand() {
        isEditingAICommand = false
        editingAICommand = nil
        focusFilterField()
    }

    func deleteAICommand(id: String) {
        aiCommands.removeAll { $0.id == id }
        saveAICommands()
        if aiCommandSelectedIndex >= filteredAICommands.count {
            aiCommandSelectedIndex = max(0, filteredAICommands.count - 1)
        }
    }

    func aiCommandActions(for command: AICommand) -> [ActionItem] {
        [
            ActionItem(title: "Edit", icon: "pencil", shortcut: nil, keepPanel: true) { [weak self] in
                self?.goToAICommands()
                if let idx = self?.aiCommands.firstIndex(where: { $0.id == command.id }) {
                    self?.aiCommandSelectedIndex = idx
                    self?.editSelectedAICommand()
                }
            },
            ActionItem(title: "Manage AI Commands", icon: "sparkle", shortcut: nil, keepPanel: true) { [weak self] in
                self?.goToAICommands()
            },
        ]
    }

    func executeSelectedAICommand() {
        let items = filteredAICommands
        guard aiCommandSelectedIndex < items.count else { return }
        let command = items[aiCommandSelectedIndex]
        executeAICommand(command)
    }

    // MARK: - Action Panel

    /// Get actions for the currently selected result.
    var currentActions: [ActionItem] {
        switch page {
        case .main:
            guard selectedIndex < results.count else { return [] }
            return results[selectedIndex].actions
        case .fileSearch:
            guard fileSearch.results.indices.contains(fileSearch.selectedIndex) else { return [] }
            return fileSearch.actions(for: fileSearch.results[fileSearch.selectedIndex])
        default:
            return []
        }
    }

    var currentActionTitle: String {
        switch page {
        case .main:
            return results.indices.contains(selectedIndex) ? results[selectedIndex].title : ""
        case .fileSearch:
            return fileSearch.results.indices.contains(fileSearch.selectedIndex)
                ? fileSearch.results[fileSearch.selectedIndex].title : ""
        default:
            return ""
        }
    }

    func toggleActionPanel() {
        showActionPanel = !currentActions.isEmpty && !showActionPanel
    }

    /// App-specific actions.
    func appActions(path: String, isPinned: Bool) -> [ActionItem] {
        [
            ActionItem(title: "Open Application", icon: "arrow.up.forward.app", shortcut: "↵") {
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
                rc_update_ranking(path)
            },
            ActionItem(
                title: isPinned ? "Unpin from Home" : "Pin to Home",
                icon: isPinned ? "pin.slash" : "pin",
                shortcut: nil,
                keepPanel: true
            ) { [weak self] in
                let status = rc_set_app_pinned(path, !isPinned)
                if status == -2 {
                    self?.showPinnedAppsLimitAlert()
                    return
                }
                guard status == 0 else { return }
                self?.refreshResultsAfterPinChange()
            },
            ActionItem(title: "Show in Finder", icon: "folder", shortcut: nil) {
                NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
            },
            ActionItem(title: "Show Info in Finder", icon: "info.circle", shortcut: nil) {
                let url = URL(fileURLWithPath: path)
                NSWorkspace.shared.activateFileViewerSelecting([url])
                // Cmd+I after a short delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    let source = CGEventSource(stateID: .combinedSessionState)
                    let iDown = CGEvent(keyboardEventSource: source, virtualKey: 0x22, keyDown: true)
                    iDown?.flags = .maskCommand
                    iDown?.post(tap: .cghidEventTap)
                    let iUp = CGEvent(keyboardEventSource: source, virtualKey: 0x22, keyDown: false)
                    iUp?.flags = .maskCommand
                    iUp?.post(tap: .cghidEventTap)
                }
            },
            ActionItem(title: "Copy Path", icon: "doc.on.doc", shortcut: nil) {
                PasteboardAccess.withPasteboard { pasteboard in
                    pasteboard.clearContents()
                    pasteboard.setString(path, forType: .string)
                }
            },
            ActionItem(title: "Copy Bundle ID", icon: "number", shortcut: nil) {
                if let bundle = Bundle(path: path), let id = bundle.bundleIdentifier {
                    PasteboardAccess.withPasteboard { pasteboard in
                        pasteboard.clearContents()
                        pasteboard.setString(id, forType: .string)
                    }
                }
            },
        ]
    }

    private func showPinnedAppsLimitAlert() {
        let alert = NSAlert()
        alert.messageText = "Pinned Apps Limit Reached"
        alert.informativeText = "Unpin an app before pinning another. The home page supports up to 8 pinned apps."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func refreshResultsAfterPinChange() {
        if query.isEmpty {
            results = buildDefaultResults()
        } else {
            performSearch(query: query)
        }
        selectedIndex = min(selectedIndex, max(0, results.count - 1))
    }

    // MARK: - Default Results

    /// Build results shown when search query is empty.
    private func buildDefaultResults() -> [SearchResult] {
        var results: [SearchResult] = []

        // Only explicitly pinned apps appear on the home page.
        if let cStr = rc_get_pinned_apps(8) {
            let jsonStr = String(cString: cStr)
            rc_free_string(cStr)
            if let data = jsonStr.data(using: .utf8),
               let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                for entry in entries {
                    let name = entry["display_name"] as? String ?? ""
                    let path = entry["path"] as? String ?? ""
                    let bundleID = entry["bundle_id"] as? String
                    let isPinned = entry["is_favourite"] as? Bool ?? true
                    let icon = self.loadAppIcon(path: path)
                    var result = SearchResult(
                        title: name,
                        subtitle: "Application",
                        icon: icon,
                        systemIcon: "app.fill",
                        targetRef: Self.appTargetRef(bundleID: bundleID, path: path)
                    ) {
                        NSWorkspace.shared.open(URL(fileURLWithPath: path))
                        rc_update_ranking(path)
                    }
                    result.actions = self.appActions(path: path, isPinned: isPinned)
                    results.append(result)
                }
            }
        }

        // Built-in commands. Home visibility does not affect normal search.
        if homeClipboardHistory {
            results.append(SearchResult(
                title: "Clipboard History",
                subtitle: "Command",
                icon: nil,
                systemIcon: "doc.on.clipboard",
                targetRef: LauncherTargetRef(kind: .launcherCommand, id: "clipboard-history")
            ) { [weak self] in self?.goToClipboard() })
        }

        if homeFileSearch {
            results.append(fileSearchCommandResult(score: 0))
        }

        if homeSnippets {
            results.append(SearchResult(
                title: "Snippets",
                subtitle: "Command",
                icon: nil,
                systemIcon: "text.quote"
            ) { [weak self] in self?.goToSnippets() })
        }

        // AI surfaces — hidden entirely when the AI master switch is off.
        if aiEnabled && homeAICommands {
            results.append(SearchResult(
                title: "AI Commands",
                subtitle: "Command",
                icon: nil,
                systemIcon: "sparkle"
            ) { [weak self] in self?.goToAICommands() })

            // Explicit Home selections replace the legacy top-four behavior.
            // The prefix remains a defensive cap for manually edited config files.
            let eligible = homeAICommandIDs.map { selected in
                aiCommands.filter { selected.contains($0.id) }
            } ?? aiCommands
            let sorted = eligible
                .map { (command: $0, rank: commandRanking(for: $0)) }
                .sorted { first, second in
                    if first.rank != second.rank { return first.rank > second.rank }
                    return first.command.name.localizedStandardCompare(second.command.name) == .orderedAscending
                }
            for entry in sorted.prefix(4) {
                let command = entry.command
                var result = SearchResult(
                    title: command.name,
                    subtitle: "AI Command",
                    icon: nil,
                    systemIcon: command.icon,
                    targetRef: LauncherTargetRef(kind: .aiCommand, id: command.id)
                ) { [weak self] in
                    self?.incrementCommandRanking(command)
                    self?.executeAICommand(command)
                }
                result.actions = aiCommandActions(for: command)
                results.append(result)
            }
        }

        return results
    }

    // MARK: - AI Commands

    /// Callback to grab selection from previous app (set by SearchPanel)
    var onGrabSelection: ((@MainActor @escaping (SelectionCaptureResult) -> Void) -> Void)?

    func executeAICommand(_ command: AICommand) {
        // Ask the panel to hide, grab selection from previous app, then proceed
        onGrabSelection? { [weak self] result in
            guard let self else { return }

            let selectedText: String
            switch result {
            case .success(let text):
                selectedText = text
            case .failure(let message):
                self.searchMode = .claude
                self.claudeMessages.append(ClaudeMessage(role: .assistant, text: message))
                self.page = .claude
                return
            }

            guard !selectedText.isEmpty else {
                self.searchMode = .claude
                self.claudeMessages.append(ClaudeMessage(role: .assistant, text: "Please select some text in another app first, then try this command again."))
                self.page = .claude
                return
            }

            let prompt = command.prompt.replacingOccurrences(of: "{selection}", with: selectedText)
            self.searchMode = .claude
            self.query = prompt
            self.claudeAsk()
        }
    }

    // MARK: - Claude

    func toggleSearchMode() {
        // Claude mode is an AI surface — disabled when the master switch is off.
        guard aiEnabled else { return }
        if searchMode == .apps {
            searchMode = .claude
            results = []
        } else {
            searchMode = .apps
            claudeCancel()
            performSearch(query: query)
        }
    }

    func claudeAsk() {
        guard aiEnabled else { return }
        guard !query.isEmpty else { return }
        let prompt = query
        let wasOnClaudePage = page == .claude

        // Add user message
        claudeMessages.append(ClaudeMessage(role: .user, text: prompt))

        // Add empty assistant message (will be filled by streaming)
        claudeMessages.append(ClaudeMessage(role: .assistant, text: ""))
        let assistantMessageIndex = claudeMessages.count - 1

        // Switch to Claude page
        page = .claude
        claudeIsStreaming = true
        query = ""

        // Start session via Rust FFI. A command launched from search starts a
        // fresh conversation; only a follow-up already on this page resumes.
        let resumeId = wasOnClaudePage ? claudeSessionId : nil
        if !wasOnClaudePage {
            claudeSessionId = nil
        }
        guard let session = rc_claude_start(prompt, claudeBinary, resumeId) else {
            // Update last message with error
            if let lastIdx = claudeMessages.indices.last {
                claudeMessages[lastIdx].text = "Error: Could not start AI session. Is `\(claudeBinary)` installed?"
            }
            claudeIsStreaming = false
            return
        }
        claudeSession = session

        // Stream chunks in background (blocking reads on detached thread)
        let sendablePtr = SendablePointer(ptr: session)
        let sessionToken = UInt(bitPattern: session)
        Task.detached {
            let ptr = sendablePtr.ptr
            var gotAnyText = false
            while true {
                guard let cStr = rc_claude_next_chunk(ptr) else {
                    var completedSessionID: String?
                    if let sidStr = rc_claude_get_session_id(ptr) {
                        completedSessionID = String(cString: sidStr)
                        rc_free_string(sidStr)
                    }

                    var errorMessage: String?
                    if !gotAnyText {
                        errorMessage = "Claude process ended without output."
                        if let errStr = rc_claude_get_stderr(ptr) {
                            let stderr = String(cString: errStr)
                            rc_free_string(errStr)
                            if !stderr.isEmpty {
                                errorMessage = stderr
                            }
                        }
                    }

                    await MainActor.run { [weak self] in
                        guard let self,
                              self.claudeSession.map({ UInt(bitPattern: $0) }) == sessionToken
                        else { return }
                        if let errorMessage {
                            if self.claudeMessages.indices.contains(assistantMessageIndex) {
                                self.claudeMessages[assistantMessageIndex].text = Self.claudeDisplayError(errorMessage)
                            }
                            if resumeId == nil {
                                self.claudeSessionId = nil
                            }
                        } else if let completedSessionID {
                            self.claudeSessionId = completedSessionID
                        }
                        self.claudeIsStreaming = false
                        self.claudeSession = nil
                    }
                    rc_claude_free(ptr)
                    break
                }

                let chunk = String(cString: cStr)
                rc_free_string(cStr)
                gotAnyText = true

                await MainActor.run { [weak self] in
                    guard let self,
                          self.claudeSession.map({ UInt(bitPattern: $0) }) == sessionToken
                    else { return }
                    if self.claudeMessages.indices.contains(assistantMessageIndex) {
                        self.claudeMessages[assistantMessageIndex].text += chunk
                    }
                }
            }
        }
    }

    func claudeCancel() {
        if let session = claudeSession {
            rc_claude_cancel(session)
            // Don't free here — background reader thread still holds the pointer.
            // It will be freed when rc_claude_next_chunk returns nil.
            claudeSession = nil
        }
        claudeIsStreaming = false
    }

    var claudeCanRetryLastRequest: Bool {
        guard !claudeIsStreaming,
              let lastMessage = claudeMessages.last,
              lastMessage.role == .assistant
        else { return false }
        return Self.isRetryableClaudeError(lastMessage.text)
    }

    func claudeRetryLastRequest() {
        guard claudeCanRetryLastRequest,
              let userIndex = claudeMessages.lastIndex(where: { $0.role == .user })
        else { return }
        let prompt = claudeMessages[userIndex].text
        claudeMessages.removeSubrange(userIndex...)
        query = prompt
        claudeAsk()
    }

    private static func claudeDisplayError(_ error: String) -> String {
        let lowercased = error.lowercased()
        if lowercased.contains("529") || lowercased.contains("overloaded") {
            return "Claude is temporarily overloaded (529). Try again in a moment."
        }
        return error
    }

    private static func isRetryableClaudeError(_ error: String) -> Bool {
        let lowercased = error.lowercased()
        return lowercased.contains("529")
            || lowercased.contains("overloaded")
            || lowercased.contains("rate limit")
            || lowercased.contains("connection issue")
            || lowercased.contains("ended without output")
    }

    /// Replace the selected text in the previous app with the last Claude response.
    func replaceSelectedText() {
        guard let lastResponse = claudeMessages.last(where: { $0.role == .assistant }),
              !lastResponse.text.isEmpty else { return }

        // Write response to clipboard
        PasteboardAccess.withPasteboard { pasteboard in
            pasteboard.clearContents()
            pasteboard.setString(lastResponse.text, forType: .string)
        }

        // Hide panel and paste into previous app
        onPasteAndHide?()
    }

    func claudeCopyLastResponse() {
        if let last = claudeMessages.last(where: { $0.role == .assistant }) {
            PasteboardAccess.withPasteboard { pasteboard in
                pasteboard.clearContents()
                pasteboard.setString(last.text, forType: .string)
            }
        }
    }

    // MARK: - Command Ranking

    func incrementCommandRanking(_ name: String) {
        let key = "cmd:\(name)"
        let _ = rc_increment_ranking(key)
    }

    func incrementCommandRanking(_ command: AICommand) {
        let _ = rc_increment_ranking("cmd-id:\(command.id)")
    }

    func commandRanking(for name: String) -> Int {
        let key = "cmd:\(name)"
        return Int(rc_get_ranking(key))
    }

    func commandRanking(for command: AICommand) -> Int {
        max(Int(rc_get_ranking("cmd-id:\(command.id)")), commandRanking(for: command.name))
    }

    // MARK: - Focus

    /// Force focus on the first visible, editable text field.
    /// SwiftUI @FocusState doesn't work reliably with NSPanel + nonActivatingPanel,
    /// so we use AppKit directly. Retries up to 3 times with short delays to handle
    /// SwiftUI render lag (e.g. conditional view mounting or .disabled toggling).
    func focusFilterField(then completion: (() -> Void)? = nil) {
        func tryFocus(attempts: Int) {
            guard attempts > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                // Alias fields in Settings can remain the key window. Always
                // focus the visible launcher panel instead of NSApp.keyWindow.
                if let window = NSApp.windows
                    .compactMap({ $0 as? SearchPanel })
                    .first(where: { $0.isVisible }),
                   let textField = Self.findTextField(in: window.contentView) {
                    window.makeFirstResponder(textField)
                    completion?()
                } else {
                    tryFocus(attempts: attempts - 1)
                }
            }
        }
        tryFocus(attempts: 3)
    }

    private static func findTextField(in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let tf = view as? NSTextField, tf.isEditable {
            return tf
        }
        for subview in view.subviews {
            if let found = findTextField(in: subview) {
                return found
            }
        }
        return nil
    }

    // MARK: - Private

    func loadAppIcon(path: String) -> NSImage? {
        if let cached = iconCache[path] {
            return cached
        }
        let icon = NSWorkspace.shared.icon(forFile: path)
        icon.size = NSSize(width: 32, height: 32)
        iconCache[path] = icon
        return icon
    }

    private func startClaude(prompt: String) {
        query = prompt
        searchMode = .claude
        claudeAsk()
    }
}
