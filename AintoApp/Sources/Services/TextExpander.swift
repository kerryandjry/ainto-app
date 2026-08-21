import AppKit
import Carbon
import AintoCore

/// Global text expansion service.
/// Monitors all keystrokes via CGEvent tap, matches snippet keywords against a
/// rolling buffer, and replaces them with expanded text.
///
/// Reference: GenSnippets (https://github.com/jaynguyen-vn/gen-snippets)
///
/// Requires:
/// - System Settings → Privacy & Security → Accessibility
/// - System Settings → Privacy & Security → Input Monitoring
@MainActor
final class TextExpander {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// Lock protecting all static mutable state accessed from CGEvent tap thread.
    private static let lock = NSLock()

    /// Rolling buffer of recent keystrokes for matching.
    private static var buffer = ""
    private static let maxBufferLength = 50
    private static var lastKeystrokeTime = Date()
    private static let bufferTimeout: TimeInterval = 10 // clear after 10s inactivity

    /// Snippet keyword → expansion mapping.
    private static var snippetMap: [String: String] = [:]

    // MARK: - Public

    func start() {
        // Already running — keep start/stop idempotent so config-driven
        // toggling can call them freely.
        guard eventTap == nil else { return }
        guard checkAccessibilityPermission() else {
            print("TextExpander: Accessibility permission not granted")
            requestAccessibilityPermission()
            return
        }

        loadSnippets()
        installEventTap()
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    /// Reload snippets from disk (call after snippet CRUD).
    func reloadSnippets() {
        loadSnippets()
    }

    // MARK: - Permissions

    private func checkAccessibilityPermission() -> Bool {
        AXIsProcessTrusted()
    }

    private func requestAccessibilityPermission() {
        // kAXTrustedCheckOptionPrompt is "AXTrustedCheckOptionPrompt"
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Snippets

    private func loadSnippets() {
        guard let cStr = rc_snippets_load() else { return }
        let jsonStr = String(cString: cStr)
        rc_free_string(cStr)

        guard let data = jsonStr.data(using: .utf8),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }

        Self.lock.lock()
        Self.snippetMap.removeAll()

        for entry in entries {
            guard let keyword = entry["keyword"] as? String, !keyword.isEmpty,
                  let expansion = entry["expansion"] as? String else { continue }
            Self.snippetMap[keyword] = expansion
        }
        Self.lock.unlock()
    }

    // MARK: - CGEvent Tap

    private func installEventTap() {
        let eventMask: CGEventMask = (1 << CGEventType.keyDown.rawValue)

        // The callback must be a C function pointer — use a static method
        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: TextExpander.eventCallback,
            userInfo: nil
        )

        guard let tap else {
            print("TextExpander: Failed to create event tap. Check Input Monitoring permission.")
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.eventTap = tap
        self.runLoopSource = source
        Self.sharedEventTap = tap
    }

    /// C-compatible callback for CGEvent tap.
    /// Stored tap reference for re-enabling on timeout.
    private static var sharedEventTap: CFMachPort?

    private static let eventCallback: CGEventTapCallBack = { _, type, event, _ in
        // Re-enable tap if it gets disabled (system does this after timeout)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = sharedEventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passRetained(event)
        }

        guard type == .keyDown else {
            return Unmanaged.passRetained(event)
        }

        // Skip keystroke capture for password managers and secure input fields
        if SecureInput.isActive {
            return Unmanaged.passRetained(event)
        }

        // Skip if modifier keys are held (Cmd, Ctrl, Alt)
        let flags = event.flags
        if flags.contains(.maskCommand) || flags.contains(.maskControl) || flags.contains(.maskAlternate) {
            lock.lock()
            buffer = ""
            lock.unlock()
            return Unmanaged.passRetained(event)
        }

        // Get the character
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &length, unicodeString: &chars)

        guard length > 0 else {
            return Unmanaged.passRetained(event)
        }

        let char = String(utf16CodeUnits: chars, count: length)

        lock.lock()

        // Check for buffer timeout
        let now = Date()
        if now.timeIntervalSince(lastKeystrokeTime) > bufferTimeout {
            buffer = ""
        }
        lastKeystrokeTime = now

        // Handle backspace
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        if keyCode == 51 { // Backspace
            if !buffer.isEmpty {
                buffer.removeLast()
            }
            lock.unlock()
            return Unmanaged.passRetained(event)
        }

        // Append to buffer
        buffer += char
        if buffer.count > maxBufferLength {
            buffer = String(buffer.suffix(maxBufferLength))
        }

        // Check if buffer ends with any snippet keyword
        if let (keyword, expansion) = findMatch() {
            // Remove the keyword from the buffer
            buffer = String(buffer.dropLast(keyword.count))
            lock.unlock()

            // Perform replacement on the main actor without blocking it while
            // another pasteboard operation owns the serialization gate.
            Task { @MainActor in
                await performReplacement(
                    keyword: keyword,
                    expansion: expansion,
                    suppressedText: char
                )
            }

            // Suppress the last keystroke (it's part of the keyword)
            return nil
        }

        lock.unlock()
        return Unmanaged.passRetained(event)
    }

    /// Check if the buffer ends with any snippet keyword.
    ///
    /// Runs on the CGEvent tap thread, so it stays a pure dictionary lookup.
    /// Placeholder resolution needs the pasteboard, and a pasteboard read can
    /// block on a slow or dead promised-data provider (see the note on
    /// `ClipboardMonitor`); stalling here would make macOS disable the tap.
    /// The raw expansion is resolved later, on the main queue.
    private static func findMatch() -> (keyword: String, expansion: String)? {
        // Check from longest possible match to shortest
        let maxLen = min(buffer.count, maxBufferLength)
        for len in stride(from: maxLen, through: 1, by: -1) {
            let suffix = String(buffer.suffix(len))
            if let expansion = snippetMap[suffix] {
                return (suffix, expansion)
            }
        }
        return nil
    }

    /// Resolve `{date}`, `{clipboard}` and friends. Main queue only.
    private static func resolvePlaceholders(in expansion: String, clipboardText: String?) -> String {
        guard let cStr = rc_snippet_expand(expansion, clipboardText) else { return expansion }
        let resolved = String(cString: cStr)
        rc_free_string(cStr)
        return resolved
    }

    /// How long to leave the expansion on the pasteboard before restoring what
    /// was there. The paste is delivered as a synthetic Cmd+V, and there is no
    /// signal for when the target app has consumed it — so this is a heuristic:
    /// too short and a slow app pastes the restored contents instead.
    private static let clipboardRestoreDelay: TimeInterval = 0.4

    /// Delete the keyword characters and type the expansion.
    private static func performReplacement(
        keyword: String,
        expansion: String,
        suppressedText: String
    ) async {
        let source = CGEventSource(stateID: .combinedSessionState)

        // Snapshot before changing the target document. If an advertised
        // representation cannot be preserved, replay the suppressed key and
        // leave both the document and clipboard untouched.
        await PasteboardAccess.acquireExclusiveAccess()
        let pasteboard = NSPasteboard.general
        let saved = PasteboardAccess.snapshotItems(from: pasteboard)
        let clipboardText = pasteboard.string(forType: .string)
        PasteboardAccess.endExclusiveAccess()
        guard let saved else {
            postUnicodeText(suppressedText, source: source)
            return
        }
        let resolved = resolvePlaceholders(in: expansion, clipboardText: clipboardText)

        // Step 1: Send backspace to delete the keyword (minus the last char which was suppressed)
        for _ in 0..<(keyword.count - 1) {
            let backDown = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: true)
            backDown?.post(tap: .cghidEventTap)
            let backUp = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: false)
            backUp?.post(tap: .cghidEventTap)
        }

        // Step 2: Small delay to let backspaces process
        usleep(10_000) // 10ms

        // Step 3: Type the expansion by writing to clipboard and pasting
        // Mark as transient so ClipboardMonitor ignores it
        let (ourChangeCount, didWrite) = PasteboardAccess.withPasteboard { pasteboard in
            pasteboard.clearContents()
            let didWrite = pasteboard.setString(resolved, forType: .string)
            pasteboard.setData(
                Data(),
                forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
            )
            return (pasteboard.changeCount, didWrite)
        }
        guard didWrite else {
            PasteboardAccess.withPasteboard { pasteboard in
                PasteboardAccess.restore(saved, to: pasteboard)
            }
            postUnicodeText(keyword, source: source)
            return
        }

        // Simulate Cmd+V
        let vDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        vDown?.flags = .maskCommand
        vDown?.post(tap: .cghidEventTap)
        let vUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        vUp?.flags = .maskCommand
        vUp?.post(tap: .cghidEventTap)

        // Step 4: Put back what was on the pasteboard, unless something else
        // has written to it since — restoring then would clobber that. Clearing
        // without writing restores an originally empty pasteboard as well.
        DispatchQueue.main.asyncAfter(deadline: .now() + clipboardRestoreDelay) {
            PasteboardAccess.withPasteboard { pasteboard in
                guard pasteboard.changeCount == ourChangeCount else { return }
                PasteboardAccess.restore(saved, to: pasteboard)
            }
        }
    }

    private static func postUnicodeText(_ text: String, source: CGEventSource?) {
        let codeUnits = Array(text.utf16)
        codeUnits.withUnsafeBufferPointer { buffer in
            guard let pointer = buffer.baseAddress else { return }
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
            keyDown?.keyboardSetUnicodeString(
                stringLength: buffer.count,
                unicodeString: pointer
            )
            keyDown?.post(tap: .cghidEventTap)

            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            keyUp?.keyboardSetUnicodeString(
                stringLength: buffer.count,
                unicodeString: pointer
            )
            keyUp?.post(tap: .cghidEventTap)
        }
    }
}

/// Detects when macOS secure event input is active (password fields, etc.).
/// Uses Carbon's IsSecureEventInputEnabled() — returns true when any app
/// has enabled secure input (e.g., 1Password, Safari password fields).
enum SecureInput {
    static var isActive: Bool {
        IsSecureEventInputEnabled()
    }
}
