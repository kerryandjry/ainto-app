import Darwin
import Foundation

struct ProcessIdentity: Equatable, Sendable {
    let pid: pid_t
    let uid: uid_t
    let executablePath: String
    let startSeconds: UInt64
    let startMicroseconds: UInt64
}

struct ProcessCandidate: Equatable, Sendable {
    let identity: ProcessIdentity
    let name: String

    var pid: pid_t { identity.pid }
    var executablePath: String { identity.executablePath }
}

enum ProcessKillOutcome: Equatable, Sendable {
    case signalSent
    case stale
    case forbidden(String)
    case failed(String)
}

enum ProcessSearchService {
    private static let protectedNames: Set<String> = [
        "ainto", "launchd", "loginwindow", "windowserver",
    ]
    private static let protectedPathPrefixes = [
        "/System/", "/Library/Apple/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/",
    ]

    /// `kill` by itself remains an ordinary app/alias query. Only the reserved
    /// syntax with a trailing space enters inline process search.
    static func searchTerm(for query: String) -> String? {
        guard query.count >= 5,
              String(query.prefix(5)).lowercased() == "kill " else { return nil }
        return query.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func matchingProcesses(for term: String, limit: Int = 8) -> [ProcessCandidate] {
        guard !term.isEmpty, limit > 0 else { return [] }
        return matchingProcesses(in: allProcesses(), term: term, limit: limit)
    }

    static func matchingProcesses(
        in candidates: [ProcessCandidate],
        term: String,
        limit: Int = 8
    ) -> [ProcessCandidate] {
        let normalized = term.lowercased()
        guard !normalized.isEmpty, limit > 0 else { return [] }

        return candidates.compactMap { candidate -> (ProcessCandidate, Int)? in
            let name = candidate.name.lowercased()
            let path = candidate.executablePath.lowercased()
            let score: Int
            if String(candidate.pid) == normalized {
                score = 10_000
            } else if name == normalized {
                score = 9_000
            } else if name.hasPrefix(normalized) {
                score = 8_000
            } else if name.contains(normalized) {
                score = 7_000
            } else if path.contains(normalized) {
                score = 6_000
            } else {
                return nil
            }
            return (candidate, score)
        }
        .sorted { first, second in
            if first.1 != second.1 { return first.1 > second.1 }
            if first.0.name != second.0.name {
                return first.0.name.localizedStandardCompare(second.0.name) == .orderedAscending
            }
            return first.0.pid < second.0.pid
        }
        .prefix(limit)
        .map(\.0)
    }

    static func forceKill(_ candidate: ProcessCandidate) -> ProcessKillOutcome {
        guard let current = process(pid: candidate.pid), current.identity == candidate.identity else {
            return .stale
        }
        guard isAllowed(current) else {
            return .forbidden("Ainto will only terminate non-system processes owned by the current user.")
        }
        guard Darwin.kill(candidate.pid, SIGKILL) == 0 else {
            let code = errno
            if code == ESRCH { return .stale }
            if code == EPERM {
                return .forbidden("macOS did not allow Ainto to terminate this process.")
            }
            return .failed(String(cString: strerror(code)))
        }
        return .signalSent
    }

    static func isAllowed(_ candidate: ProcessCandidate) -> Bool {
        candidate.pid > 1
            && candidate.pid != getpid()
            && candidate.identity.uid == getuid()
            && !protectedNames.contains(candidate.name.lowercased())
            && !protectedPathPrefixes.contains { candidate.executablePath.hasPrefix($0) }
    }

    private static func allProcesses() -> [ProcessCandidate] {
        let estimatedCount = max(Int(proc_listallpids(nil, 0)), 0)
        var processIDs = [pid_t](repeating: 0, count: max(estimatedCount + 64, 256))
        let count = processIDs.withUnsafeMutableBytes { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count))
        }
        guard count > 0 else { return [] }
        return processIDs.prefix(Int(count)).compactMap { pid -> ProcessCandidate? in
            guard let candidate = process(pid: pid), isAllowed(candidate) else { return nil }
            return candidate
        }
    }

    private static func process(pid: pid_t) -> ProcessCandidate? {
        var info = proc_bsdinfo()
        let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, expectedSize) == expectedSize else {
            return nil
        }

        var pathBuffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        guard pathLength > 0 else { return nil }
        let path = String(
            decoding: pathBuffer.prefix(Int(pathLength)).map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
        guard !path.isEmpty else { return nil }

        var nameBuffer = [CChar](repeating: 0, count: 1024)
        let nameLength = proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
        let name = nameLength > 0
            ? String(
                decoding: nameBuffer.prefix(Int(nameLength)).map { UInt8(bitPattern: $0) },
                as: UTF8.self
            )
            : URL(fileURLWithPath: path).lastPathComponent
        guard !name.isEmpty else { return nil }

        return ProcessCandidate(
            identity: ProcessIdentity(
                pid: pid,
                uid: info.pbi_uid,
                executablePath: path,
                startSeconds: info.pbi_start_tvsec,
                startMicroseconds: info.pbi_start_tvusec
            ),
            name: name
        )
    }
}
