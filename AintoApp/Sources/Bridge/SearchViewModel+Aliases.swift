import AppKit
import Foundation
import AintoCore

extension SearchViewModel {
    nonisolated static func appTargetRef(bundleID: String?, path: String) -> LauncherTargetRef {
        let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        if let bundleID, !bundleID.isEmpty {
            // Bundle IDs are not unique when multiple copies of an app are installed.
            return LauncherTargetRef(kind: .app, id: "bundle:\(bundleID)|path:\(standardizedPath)")
        }
        return LauncherTargetRef(kind: .app, id: "path:\(standardizedPath)")
    }

    func resolvedAliasResult(for query: String) -> SearchResult? {
        let normalized = AliasStore.normalize(query)
        guard !normalized.isEmpty,
              let entry = aliases.first(where: { $0.isActive && AliasStore.normalize($0.alias) == normalized }),
              var result = result(for: entry.target)
        else { return nil }
        result.subtitle = "Alias: \(entry.alias) • \(result.subtitle)"
        result.score = 10_000
        return result
    }

    func invokeShortcutTarget(_ target: LauncherTargetRef) -> Bool {
        guard let result = result(for: target) else { return false }
        result.action()
        return true
    }

    private func result(for target: LauncherTargetRef) -> SearchResult? {
        switch target.kind {
        case .app:
            return appResult(targetID: target.id)
        case .aiCommand:
            guard aiEnabled,
                  let command = AICommand.loadAll()?.first(where: { $0.id == target.id })
            else { return nil }
            var result = SearchResult(
                title: command.name,
                subtitle: "AI Command",
                icon: nil,
                systemIcon: command.icon,
                targetRef: target
            ) { [weak self] in
                self?.incrementCommandRanking(command)
                self?.executeAICommand(command)
            }
            result.actions = aiCommandActions(for: command)
            result.keepsPanelOpenAfterAction = true
            return result
        case .snippet:
            return nil // Legacy target retained only for lossless alias migration.
        case .launcherCommand:
            switch target.id {
            case "file-search":
                return fileSearchCommandResult(score: 0)
            case "clipboard-history":
                return SearchResult(
                    title: "Clipboard History",
                    subtitle: "Command",
                    icon: nil,
                    systemIcon: "doc.on.clipboard",
                    targetRef: target
                ) { [weak self] in self?.goToClipboard() }
            default:
                return nil
            }
        case .systemAction:
            guard let action = SystemAction(rawValue: target.id) else { return nil }
            return systemActionResult(action, score: 0)
        }
    }

    private func appResult(targetID: String) -> SearchResult? {
        guard let cString = rc_get_all_apps() else { return nil }
        defer { rc_free_string(cString) }
        let json = String(cString: cString)
        guard let data = json.data(using: .utf8),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let entry = entries.first(where: { entry in
                  let path = entry["path"] as? String ?? ""
                  let bundleID = entry["bundle_id"] as? String
                  return Self.appTargetRef(bundleID: bundleID, path: path).id == targetID
              })
        else { return nil }

        let name = entry["display_name"] as? String ?? ""
        let path = entry["path"] as? String ?? ""
        let isPinned = entry["is_favourite"] as? Bool ?? false
        var result = SearchResult(
            title: name,
            subtitle: "Application",
            icon: loadAppIcon(path: path),
            systemIcon: "app.fill",
            targetRef: LauncherTargetRef(kind: .app, id: targetID)
        ) {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
            rc_update_ranking(path)
        }
        result.actions = appActions(path: path, isPinned: isPinned)
        return result
    }


}
