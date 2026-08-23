// swiftlint:disable type_body_length function_body_length cyclomatic_complexity identifier_name file_length
import AppKit
import SwiftUI

/// Non-activating floating panel for the search interface.
/// Uses NSPanel + .nonactivatingPanel so the previously focused app keeps focus.
/// This allows "paste to frontmost app" to work after selecting a clipboard item.
@MainActor
final class SearchPanel: NSPanel {
    private let hostingView: NSHostingView<MainView>
    let viewModel = SearchViewModel()

    /// The app that was frontmost before we showed the panel.
    private var previousApp: NSRunningApplication?
    /// When the panel was last hidden, so the next invocation can tell a quick
    /// round trip from returning to a launcher left open on a sub-page.
    private var hiddenAt: Date?

    /// Where the user wants the panel on each display, as a top-left corner in
    /// screen coordinates. Tracked per display so dragging it on one screen is
    /// still remembered after invoking it on another, and tracked by the
    /// top-left rather than the origin because an NSWindow's origin is its
    /// bottom-left corner, which moves whenever a page change changes the
    /// panel's height.
    private var preferredTopLeftByDisplay: [CGDirectDisplayID: NSPoint] = [:]
    /// Guards `windowDidMove` against recording our own corrective moves.
    private var isRestoringPosition = false

    /// Floating action panel window.
    private var actionWindow: NSWindow?
    private var actionSelectedIndex = 0

    init() {
        let mainView = MainView(viewModel: viewModel)
        hostingView = NSHostingView(rootView: mainView)
        // Default sizingOptions (.standardBounds) for correct auto-sizing.
        // Removing .titled eliminates the title bar constraints that caused
        // the infinite recursion between updateWindowContentSizeExtremaIfNecessary
        // and updateConstraints when display configuration changes (macOS 14/15).
        // The panel's visual appearance is unchanged — SwiftUI provides its own
        // glassmorphism background via VisualEffectBackground + RoundedRectangle.

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        self.contentView = hostingView
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.isMovableByWindowBackground = true
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true

        // Round the window content view to match the SwiftUI clipShape,
        // so the window-level shadow follows the rounded corners.
        if let cv = self.contentView {
            cv.wantsLayer = true
            cv.layer?.cornerRadius = 16
            cv.layer?.cornerCurve = .continuous
            cv.layer?.maskedCorners = [
                .layerMinXMinYCorner,
                .layerMaxXMinYCorner,
                .layerMinXMaxYCorner,
                .layerMaxXMaxYCorner,
            ]
            cv.layer?.masksToBounds = true
        }

        // Accept keyboard input even without activating the app
        self.becomesKeyOnlyIfNeeded = false

        hostingView.translatesAutoresizingMaskIntoConstraints = false
        if let contentView = self.contentView {
            NSLayoutConstraint.activate([
                hostingView.topAnchor.constraint(equalTo: contentView.topAnchor),
                hostingView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
                hostingView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                hostingView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            ])
        }

        self.delegate = self

        // Wire up the paste action
        viewModel.onPasteAndHide = { [weak self] in
            self?.pasteToFrontmostApp()
        }

        // Wire up grab selection for AI commands
        viewModel.onGrabSelection = { [weak self] completion in
            self?.grabSelectionFromPreviousApp(completion: completion)
        }
        viewModel.fileSearch.onOpen = { [weak self] in self?.hidePanel() }
        viewModel.onSystemActionCompleted = { [weak self] in self?.hidePanel() }
        viewModel.onProcessKillCompleted = { [weak self] in self?.hidePanel() }
        viewModel.onSearchResultsWillChange = { [weak self] in self?.hideActionPanel() }

        viewModel.loadAISettings()
    }

    /// Display used on the previous presentation. Moving within the same display
    /// is preserved, while invoking from another display follows the mouse.
    private var lastPresentedScreenFrame: NSRect?
    /// Invalidates delayed sizing passes from an older presentation.
    private var presentationGeneration: UInt = 0

    func showPanel() {
        // Alias editing activates Ainto. Preserve the last external app so
        // actions still return to the user's actual target application.
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousApp = frontmost
        }

        // Pick up any Settings change to the AI master switch.
        viewModel.loadAISettings()

        // Refresh the in-memory snippet/AI-command lists that search reads from,
        // so typing never has to hit disk.
        viewModel.loadSnippets()
        viewModel.loadAICommands()

        // Must follow loadAISettings, which refreshes the configured delay.
        if let hiddenAt {
            viewModel.popToRootIfStale(hiddenFor: Date().timeIntervalSince(hiddenAt))
        }

        positionOnMouseScreenIfNeeded()
        sizeToFitContent()

        // Do NOT call NSApp.activate — keep the previous app focused
        presentPanel()
        viewModel.selectAll()
        // Pick up apps installed/removed since the last time the panel opened.
        viewModel.refreshApps()
    }

    func hidePanel() {
        hideActionPanel()
        viewModel.prepareForPanelHide()
        hiddenAt = Date()
        // If the user dragged the panel, remember the display it actually
        // occupied so the next invocation can still follow the mouse.
        if let screen {
            lastPresentedScreenFrame = screen.frame
        }
        orderOut(nil)
    }

    private func positionOnMouseScreenIfNeeded() {
        let mouseLocation = NSEvent.mouseLocation
        guard let targetScreen = NSScreen.screens.first(where: {
            NSMouseInRect(mouseLocation, $0.frame, false)
        }) ?? NSScreen.main ?? NSScreen.screens.first else { return }

        let targetChanged = lastPresentedScreenFrame != targetScreen.frame
        let panelIsOnTarget = screen?.frame == targetScreen.frame
        guard lastPresentedScreenFrame == nil || targetChanged || !panelIsOnTarget else { return }

        let visibleFrame = targetScreen.visibleFrame
        // Somewhere the panel has already been placed or dragged on this
        // display wins over the default spot: moving to a second screen and
        // back should not forget where it was put on the first.
        let remembered = displayID(of: targetScreen).flatMap { preferredTopLeftByDisplay[$0] }
        let proposedX = remembered?.x ?? (visibleFrame.midX - frame.width / 2)
        // Place the panel's center roughly one quarter down from the top.
        let proposedY = remembered.map { $0.y - frame.height }
            ?? (visibleFrame.maxY - visibleFrame.height * 0.25 - frame.height / 2)
        let maxX = max(visibleFrame.minX, visibleFrame.maxX - frame.width)
        let maxY = max(visibleFrame.minY, visibleFrame.maxY - frame.height)
        let x = min(max(proposedX, visibleFrame.minX), maxX)
        let y = min(max(proposedY, visibleFrame.minY), maxY)
        isRestoringPosition = true
        setFrameOrigin(NSPoint(x: x, y: y))
        isRestoringPosition = false
        if remembered == nil {
            remember(topLeft: NSPoint(x: x, y: y + frame.height), on: targetScreen)
        }
        lastPresentedScreenFrame = targetScreen.frame
    }

    private func displayID(of screen: NSScreen?) -> CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let number = screen?.deviceDescription[key] as? NSNumber else { return nil }
        return CGDirectDisplayID(number.uint32Value)
    }

    private func remember(topLeft: NSPoint, on screen: NSScreen?) {
        guard let id = displayID(of: screen) else { return }
        preferredTopLeftByDisplay[id] = topLeft
    }

    /// Show the panel and schedule bounded sizing passes for content that
    /// SwiftUI could not lay out while the window was hidden. Selection capture
    /// also uses this path because its completion changes the page immediately
    /// after presenting the panel.
    private func presentPanel() {
        presentationGeneration &+= 1
        let generation = presentationGeneration
        makeKeyAndOrderFront(nil)
        schedulePostPresentationSizing(for: generation)
    }

    /// A window that is ordered out is not laid out, so content that grew while
    /// it was hidden can leave the window at its old size. A single next-run-loop
    /// measurement can still race SwiftUI, so use a few bounded passes without
    /// leaving a background sizing loop running.
    private func schedulePostPresentationSizing(for generation: UInt) {
        for delay in [0.0, 0.05, 0.15] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self,
                      self.isVisible,
                      self.presentationGeneration == generation else { return }
                self.sizeToFitContent()
            }
        }
    }

    private func sizeToFitContent() {
        hostingView.invalidateIntrinsicContentSize()
        hostingView.needsLayout = true
        hostingView.layoutSubtreeIfNeeded()
        let fitting = hostingView.fittingSize
        guard fitting.width > 1, fitting.height > 1 else { return }
        guard abs(fitting.height - frame.height) > 0.5
            || abs(fitting.width - frame.width) > 0.5 else { return }
        setContentSize(fitting)
    }

    /// Put the panel's top-left corner back where the user left it, clamped to
    /// the display it is on. A taller page then grows downward instead of
    /// sliding the whole panel down the screen.
    private func restorePreferredTopLeft() {
        let host = screen ?? NSScreen.main
        guard let preferred = displayID(of: host).flatMap({ preferredTopLeftByDisplay[$0] })
        else { return }
        var x = preferred.x
        var y = preferred.y - frame.height
        if let bounds = host?.visibleFrame {
            x = min(max(x, bounds.minX), max(bounds.minX, bounds.maxX - frame.width))
            y = min(max(y, bounds.minY), max(bounds.minY, bounds.maxY - frame.height))
        }
        isRestoringPosition = true
        setFrameOrigin(NSPoint(x: x, y: y))
        isRestoringPosition = false
    }

    /// Invoke a saved target shortcut using the same behavior as selecting it in search.
    func invokeShortcut(_ target: LauncherTargetRef) {
        showPanel()
        guard viewModel.invokeShortcutTarget(target) else {
            hidePanel()
            return
        }
        // Navigation and confirmation targets change the page and remain visible.
        // Immediate targets (apps, snippets, and safe system actions) close the panel.
        if viewModel.page == .main {
            hidePanel()
        }
    }

    /// Hide panel, re-activate the previous app, and simulate Cmd+V to paste.
    func pasteToFrontmostApp() {
        hidePanel()

        // Re-activate the previous app
        if let app = previousApp {
            app.activate()
        }

        // Small delay to let the app activate, then simulate Cmd+V
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.simulatePaste()
        }
    }

    /// Simulate Cmd+V keystroke.
    private func simulatePaste() {
        let source = CGEventSource(stateID: .combinedSessionState)

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true) // V key
        keyDown?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        keyUp?.flags = .maskCommand
        keyUp?.post(tap: .cghidEventTap)
    }

    /// Hide panel, activate previous app, simulate Cmd+C to grab selection, then call back.
    func grabSelectionFromPreviousApp(completion: @MainActor @escaping (SelectionCaptureResult) -> Void) {
        guard AXIsProcessTrusted() else {
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
            let message = "Ainto needs Accessibility permission to read selected text. "
                + "Enable Ainto in System Settings → Privacy & Security → Accessibility, then try again."
            completion(.failure(message))
            return
        }
        guard let previousApp else {
            completion(.failure("Ainto could not identify the app containing the selected text."))
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }

            // Keep ClipboardMonitor and every other Ainto pasteboard user out
            // of this multi-step copy transaction. Concurrent NSPasteboard
            // reads mutate AppKit's internal type cache and can crash in
            // `_updateTypeCacheIfNeeded`.
            await PasteboardAccess.acquireExclusiveAccess()

            let pasteboard = NSPasteboard.general
            guard let previousItems = PasteboardAccess.snapshotItems(from: pasteboard) else {
                PasteboardAccess.endExclusiveAccess()
                completion(.failure("Ainto could not safely preserve the current clipboard."))
                return
            }

            hidePanel()
            previousApp.activate()
            try? await Task.sleep(nanoseconds: 150_000_000)

            pasteboard.clearContents()
            let clearedChangeCount = pasteboard.changeCount
            simulateCopy()

            // Some applications update the pasteboard asynchronously. Poll for
            // at most one second instead of assuming 150 ms is always enough.
            var selection = ""
            for _ in 0..<20 {
                if pasteboard.changeCount != clearedChangeCount,
                   let copiedText = pasteboard.string(forType: .string) {
                    selection = copiedText
                    break
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }

            PasteboardAccess.restore(previousItems, to: pasteboard)
            if !previousItems.isEmpty {
                pasteboard.setData(
                    Data(),
                    forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
                )
            }
            PasteboardAccess.endExclusiveAccess()

            // Present UI and invoke callbacks only after releasing the
            // non-reentrant gate; either path can synchronously read clipboard.
            // The completion immediately switches to Claude, so use the same
            // bounded sizing passes as a normal launcher presentation.
            presentPanel()
            completion(.success(selection))
        }
    }

    /// Simulate Cmd+C keystroke.
    private func simulateCopy() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let cDown = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: true)
        cDown?.flags = .maskCommand
        cDown?.post(tap: .cghidEventTap)
        let cUp = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: false)
        cUp?.flags = .maskCommand
        cUp?.post(tap: .cghidEventTap)
    }

    // MARK: - Action Panel

    func showActionPanel() {
        let actions = viewModel.currentActions
        guard !actions.isEmpty else { return }
        actionSelectedIndex = 0

        let title = viewModel.currentActionTitle

        let panelView = ActionPanelView(
            title: title,
            actions: actions,
            onDismiss: { [weak self] in self?.hideActionPanel() },
            selectedIndex: actionSelectedIndex
        )
        let hosting = NSHostingView(rootView: panelView)
        hosting.frame = NSRect(x: 0, y: 0, width: 260, height: CGFloat(actions.count * 32 + 70))

        let window = NSPanel(
            contentRect: hosting.frame,
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .floating

        // Position to the right of the main panel
        let mainFrame = self.frame
        let x = mainFrame.maxX + 8
        let y = mainFrame.maxY - hosting.frame.height - 40
        window.setFrameOrigin(NSPoint(x: x, y: y))

        window.orderFront(nil)
        actionWindow = window
        viewModel.showActionPanel = true
    }

    func hideActionPanel() {
        actionWindow?.orderOut(nil)
        actionWindow = nil
        viewModel.showActionPanel = false
        actionSelectedIndex = 0
    }

    func updateActionPanelSelection() {
        guard let window = actionWindow else { return }
        let actions = viewModel.currentActions
        let title = viewModel.currentActionTitle

        let panelView = ActionPanelView(
            title: title,
            actions: actions,
            onDismiss: { [weak self] in self?.hideActionPanel() },
            selectedIndex: actionSelectedIndex
        )
        let hosting = NSHostingView(rootView: panelView)
        hosting.frame = window.contentView?.frame ?? .zero
        window.contentView = hosting
    }

    var isPanelVisible: Bool {
        isVisible && isKeyWindow
    }

    // Auto-hide when losing focus
    override func resignKey() {
        super.resignKey()
        hidePanel()
    }

    // NSPanel override: allow key events even when app is not active
    override var canBecomeKey: Bool { true }

    private var localEventMonitor: Any?

    private func installKeyMonitor() {
        guard localEventMonitor == nil else { return }
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isKeyWindow else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let keyCode = Int(event.keyCode)
            let hasCmd = flags.contains(.command)

            // Forward standard text editing shortcuts to first responder.
            // NonActivatingPanel doesn't receive Edit menu actions automatically.
            if hasCmd, self.firstResponder is NSTextView {
                let action: Selector? = switch keyCode {
                case 6: flags.contains(.shift) ? Selector(("redo:")) : Selector(("undo:")) // Z
                case 0: #selector(NSText.selectAll(_:))  // A
                case 7: #selector(NSText.cut(_:))        // X
                case 8: #selector(NSText.copy(_:))       // C
                case 9: #selector(NSText.paste(_:))      // V
                default: nil
                }
                if let action {
                    NSApp.sendAction(action, to: nil, from: nil)
                    return nil
                }
            }

            // Cmd+K — toggle action panel
            if hasCmd && keyCode == 40 { // K key
                if self.viewModel.showActionPanel {
                    self.hideActionPanel()
                } else {
                    self.showActionPanel()
                }
                return nil
            }

            // When action panel is shown, handle its navigation
            if self.viewModel.showActionPanel {
                let actions = self.viewModel.currentActions
                switch keyCode {
                case 125: // Down
                    if self.actionSelectedIndex < actions.count - 1 {
                        self.actionSelectedIndex += 1
                        self.updateActionPanelSelection()
                    }
                    return nil
                case 126: // Up
                    if self.actionSelectedIndex > 0 {
                        self.actionSelectedIndex -= 1
                        self.updateActionPanelSelection()
                    }
                    return nil
                case 36: // Enter — run selected action
                    if self.actionSelectedIndex < actions.count {
                        let action = actions[self.actionSelectedIndex]
                        action.action()
                        self.hideActionPanel()
                        if !action.keepPanel {
                            self.hidePanel()
                        }
                    }
                    return nil
                case 53: // Escape — close action panel
                    self.hideActionPanel()
                    return nil
                default:
                    return event
                }
            }

            // Cmd+Enter — save snippet/AI command form
            if hasCmd && keyCode == 36 {
                if self.viewModel.isEditingSnippet {
                    self.viewModel.saveEditingSnippet()
                    return nil
                }
                if self.viewModel.isEditingAICommand {
                    self.viewModel.saveEditingAICommand()
                    return nil
                }
                if self.viewModel.page == .main,
                   self.viewModel.results.indices.contains(self.viewModel.selectedIndex) {
                    let selectedResult = self.viewModel.results[self.viewModel.selectedIndex]
                    if selectedResult.isProcessKillConfirmation && event.isARepeat {
                        return nil
                    }
                    if let alternateAction = selectedResult.alternateAction {
                        alternateAction()
                        return nil
                    }
                }
            }

            // Cmd+C in Claude page — copy last response
            if hasCmd && keyCode == 8 && self.viewModel.page == .claude { // C key
                self.viewModel.claudeCopyLastResponse()
                return nil
            }

            // Cmd+Enter in Claude page — replace selected text with response
            if hasCmd && keyCode == 36 && self.viewModel.page == .claude && !self.viewModel.claudeIsStreaming {
                self.viewModel.replaceSelectedText()
                return nil
            }

            // Cmd+N — new snippet/AI command
            if hasCmd && keyCode == 45 { // N key
                if self.viewModel.page == .snippets && !self.viewModel.isEditingSnippet {
                    self.viewModel.addSnippet()
                    return nil
                }
                if self.viewModel.page == .aiCommands && !self.viewModel.isEditingAICommand {
                    self.viewModel.addAICommand()
                    return nil
                }
            }

            // Cmd+D or Cmd+Backspace — delete selected item
            if hasCmd && (keyCode == 2 || keyCode == 51) { // D key or Backspace
                if self.viewModel.page == .snippets && !self.viewModel.isEditingSnippet {
                    let items = self.viewModel.filteredSnippets
                    if self.viewModel.snippetSelectedIndex < items.count {
                        self.viewModel.deleteSnippet(id: items[self.viewModel.snippetSelectedIndex].id)
                    }
                    return nil
                }
                if self.viewModel.page == .aiCommands && !self.viewModel.isEditingAICommand {
                    let items = self.viewModel.filteredAICommands
                    if self.viewModel.aiCommandSelectedIndex < items.count {
                        self.viewModel.deleteAICommand(id: items[self.viewModel.aiCommandSelectedIndex].id)
                    }
                    return nil
                }
                if self.viewModel.page == .clipboard {
                    let items = self.viewModel.filteredClipboardItems
                    if self.viewModel.clipboardSelectedIndex < items.count {
                        self.viewModel.deleteClipboardItem(id: items[self.viewModel.clipboardSelectedIndex].id)
                    }
                    return nil
                }
            }

            // Cmd+E — edit selected snippet/AI command
            if hasCmd && keyCode == 14 { // E key
                if self.viewModel.page == .snippets && !self.viewModel.isEditingSnippet {
                    self.viewModel.editSelectedSnippet()
                    return nil
                }
                if self.viewModel.page == .aiCommands && !self.viewModel.isEditingAICommand {
                    self.viewModel.editSelectedAICommand()
                    return nil
                }
            }

            // Tab — toggle search mode (apps ↔ Claude)
            if keyCode == 48 && !hasCmd && self.viewModel.page == .main { // Tab key
                self.viewModel.toggleSearchMode()
                return nil
            }

            // Let the IME handle Enter/Escape/arrows while composing
            // (marked text means the input method is mid-composition).
            if let textView = self.firstResponder as? NSTextView,
               textView.hasMarkedText(),
               [36, 53, 125, 126].contains(keyCode) {
                return event
            }

            switch keyCode {
            case 53 where self.viewModel.isEditingSnippet: // Escape in snippet edit — cancel
                self.viewModel.cancelEditingSnippet()
                return nil
            case 53 where self.viewModel.isEditingAICommand: // Escape in AI command edit — cancel
                self.viewModel.cancelEditingAICommand()
                return nil
            case 125: // Down arrow
                self.viewModel.moveSelection(by: 1)
                return nil
            case 126: // Up arrow
                self.viewModel.moveSelection(by: -1)
                return nil
            case 36: // Enter/Return
                if self.viewModel.searchMode == .claude && self.viewModel.page == .main {
                    self.viewModel.claudeAsk()
                    return nil
                }
                if self.viewModel.page == .claude && !self.viewModel.claudeIsStreaming {
                    self.viewModel.claudeAsk()
                    return nil
                }
                let keepPanelOpen = self.viewModel.page == .main
                    && self.viewModel.results.indices.contains(self.viewModel.selectedIndex)
                    && self.viewModel.results[self.viewModel.selectedIndex].keepsPanelOpenAfterAction
                self.viewModel.openSelected()
                if self.viewModel.page == .main && !keepPanelOpen {
                    self.hidePanel()
                }
                return nil
            case 53: // Escape
                if self.viewModel.cancelPendingProcessKillIfNeeded() {
                    return nil
                } else if self.viewModel.page != .main {
                    self.viewModel.goBack()
                } else if self.viewModel.query.isEmpty {
                    self.hidePanel()
                } else {
                    self.viewModel.clearQuery()
                }
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let monitor = localEventMonitor {
            NSEvent.removeMonitor(monitor)
            localEventMonitor = nil
        }
    }

    override func makeKeyAndOrderFront(_ sender: Any?) {
        super.makeKeyAndOrderFront(sender)
        installKeyMonitor()
    }

    override func orderOut(_ sender: Any?) {
        removeKeyMonitor()
        super.orderOut(sender)
    }
}

extension SearchPanel: NSWindowDelegate {
    /// SwiftUI resizes the panel a layout pass after the page changes, so the
    /// placement done while popping ran against the outgoing page's height.
    /// Place it again now that the new height is known.
    func windowDidResize(_ notification: Notification) {
        restorePreferredTopLeft()
    }

    func windowDidMove(_ notification: Notification) {
        // The user dragged the panel: that corner is the one to keep from now
        // on, including across the height changes a page switch brings.
        guard !isRestoringPosition else { return }
        remember(topLeft: NSPoint(x: frame.minX, y: frame.maxY), on: screen)
    }
}
