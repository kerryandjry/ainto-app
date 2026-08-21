import AppKit

/// Serializes access to `NSPasteboard.general` across Ainto.
///
/// AppKit maintains mutable type-conversion caches inside NSPasteboard. Reading
/// those caches concurrently from the main thread and ClipboardMonitor's poll
/// queue can crash inside `_updateTypeCacheIfNeeded`, so every caller shares
/// this gate.
enum PasteboardAccess {
    private static let gate = DispatchSemaphore(value: 1)

    static func beginExclusiveAccess() {
        gate.wait()
    }

    /// Acquire without blocking the main actor if a lazy pasteboard provider is
    /// currently being read by ClipboardMonitor.
    static func acquireExclusiveAccess() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                gate.wait()
                continuation.resume()
            }
        }
    }

    static func endExclusiveAccess() {
        gate.signal()
    }

    static func withPasteboard<Result>(_ body: (NSPasteboard) -> Result) -> Result {
        beginExclusiveAccess()
        defer { endExclusiveAccess() }
        return body(.general)
    }

    /// Copy every item with every advertised representation. Returns nil rather
    /// than silently accepting a partial snapshot that could lose user data.
    /// Must be called while exclusive access is held.
    static func snapshotItems(from pasteboard: NSPasteboard) -> [NSPasteboardItem]? {
        var snapshot: [NSPasteboardItem] = []
        for item in pasteboard.pasteboardItems ?? [] {
            let copy = NSPasteboardItem()
            for type in item.types {
                guard let data = item.data(forType: type) else {
                    return nil
                }
                copy.setData(data, forType: type)
            }
            snapshot.append(copy)
        }
        return snapshot
    }

    /// Restore a prior snapshot. An empty snapshot restores an empty clipboard.
    /// Must be called while exclusive access is held.
    static func restore(_ items: [NSPasteboardItem], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        if !items.isEmpty {
            pasteboard.writeObjects(items)
        }
    }
}
