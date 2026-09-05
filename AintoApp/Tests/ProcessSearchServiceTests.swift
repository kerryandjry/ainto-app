import Darwin
import XCTest
#if canImport(AintoApp)
@testable import AintoApp
#elseif canImport(Ainto)
@testable import Ainto
#endif

#if canImport(AintoApp) || canImport(Ainto)
final class ProcessSearchServiceTests: XCTestCase {
    func testExactKillRemainsAnOrdinarySearchQuery() {
        XCTAssertNil(ProcessSearchService.searchTerm(for: "kill"))
        XCTAssertNil(ProcessSearchService.searchTerm(for: "KILL"))
        XCTAssertEqual(ProcessSearchService.searchTerm(for: "kill node"), "node")
        XCTAssertEqual(ProcessSearchService.searchTerm(for: "KILL   123"), "123")
    }

    func testMatchingProcessesRanksPIDThenExactName() {
        let node = candidate(pid: 120, name: "node", path: "/opt/homebrew/bin/node")
        let helper = candidate(pid: 121, name: "node-helper", path: "/tmp/node-helper")
        let unrelated = candidate(pid: 122, name: "python", path: "/usr/bin/python3")

        XCTAssertEqual(
            ProcessSearchService.matchingProcesses(
                in: [helper, unrelated, node],
                term: "120"
            ),
            [node]
        )
        XCTAssertEqual(
            ProcessSearchService.matchingProcesses(
                in: [helper, unrelated, node],
                term: "node"
            ),
            [node, helper]
        )
    }

    func testProtectedProcessesAreRejected() {
        XCTAssertFalse(ProcessSearchService.isAllowed(
            candidate(pid: 10, name: "WindowServer", path: "/System/Library/WindowServer")
        ))
        XCTAssertFalse(ProcessSearchService.isAllowed(
            candidate(pid: getpid(), name: "test", path: "/tmp/test")
        ))
        XCTAssertFalse(ProcessSearchService.isAllowed(
            candidate(pid: 10, uid: 0, name: "daemon", path: "/usr/sbin/daemon")
        ))
        XCTAssertFalse(ProcessSearchService.isAllowed(
            candidate(pid: 10, name: "Dock", path: "/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock")
        ))
    }

    func testForceKillRevalidatesIdentityBeforeSignallingOwnedChild() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer {
            if child.isRunning {
                child.terminate()
                child.waitUntilExit()
            }
        }

        let pid = child.processIdentifier
        var runningCandidate: ProcessCandidate?
        for _ in 0..<50 where runningCandidate == nil {
            runningCandidate = ProcessSearchService.matchingProcesses(for: String(pid)).first
            if runningCandidate == nil { usleep(10_000) }
        }
        let current = try XCTUnwrap(runningCandidate)
        let stale = ProcessCandidate(
            identity: ProcessIdentity(
                pid: current.pid,
                uid: current.identity.uid,
                executablePath: current.executablePath,
                startSeconds: current.identity.startSeconds + 1,
                startMicroseconds: current.identity.startMicroseconds
            ),
            name: current.name
        )

        XCTAssertEqual(ProcessSearchService.forceKill(stale), .stale)
        XCTAssertTrue(child.isRunning)
        XCTAssertEqual(ProcessSearchService.forceKill(current), .signalSent)
        child.waitUntilExit()
        XCTAssertFalse(child.isRunning)
    }

    private func candidate(
        pid: pid_t,
        uid: uid_t = getuid(),
        name: String,
        path: String
    ) -> ProcessCandidate {
        ProcessCandidate(
            identity: ProcessIdentity(
                pid: pid,
                uid: uid,
                executablePath: path,
                startSeconds: 1,
                startMicroseconds: 2
            ),
            name: name
        )
    }
}

@MainActor
final class ProcessSearchRoutingTests: XCTestCase {
    func testAliasNamedKillStillResolvesNormally() {
        let viewModel = SearchViewModel(cleanStaleAttachments: false)
        viewModel.aliases = [
            LauncherAlias(
                alias: "kill",
                targetType: .launcherCommand,
                targetID: "clipboard-history"
            )
        ]

        viewModel.performSearch(query: "kill")

        XCTAssertTrue(viewModel.results.contains { $0.subtitle.hasPrefix("Alias: kill") })
    }

    func testStaleCandidateCannotArmAfterQueryChanges() {
        let viewModel = SearchViewModel(cleanStaleAttachments: false)
        let candidate = processCandidate()
        viewModel.query = "ordinary search"
        viewModel.processCandidates = [candidate]

        viewModel.armProcessKill(candidate)

        XCTAssertNil(viewModel.pendingProcessKill)
        XCTAssertFalse(viewModel.results.contains { $0.isProcessKillConfirmation })
    }

    func testHidingPanelCancelsArmedConfirmationAndSearchGeneration() throws {
        let viewModel = SearchViewModel(cleanStaleAttachments: false)
        let candidate = processCandidate()
        viewModel.query = "kill test-child"
        viewModel.processCandidates = [candidate]
        viewModel.processSearchGeneration = UUID()
        viewModel.processSearchTask = Task { try? await Task.sleep(nanoseconds: 10_000_000_000) }
        viewModel.armProcessKill(candidate)
        XCTAssertNotNil(viewModel.pendingProcessKill)
        XCTAssertTrue(viewModel.results.first?.isProcessKillConfirmation == true)

        viewModel.prepareForPanelHide()

        XCTAssertNil(viewModel.pendingProcessKill)
        XCTAssertNil(viewModel.processSearchTask)
        XCTAssertNil(viewModel.processSearchGeneration)
        XCTAssertFalse(viewModel.results.contains { $0.isProcessKillConfirmation })
    }

    func testConfirmationTokenExpiryDisarmsCandidate() throws {
        let viewModel = SearchViewModel(cleanStaleAttachments: false)
        let candidate = processCandidate()
        viewModel.query = "kill test-child"
        viewModel.processCandidates = [candidate]
        viewModel.armProcessKill(candidate)
        let token = try XCTUnwrap(viewModel.processConfirmationToken)

        viewModel.expireProcessKillConfirmation(token: token)

        XCTAssertNil(viewModel.pendingProcessKill)
        XCTAssertFalse(viewModel.results.contains { $0.isProcessKillConfirmation })
    }

    private func processCandidate() -> ProcessCandidate {
        ProcessCandidate(
            identity: ProcessIdentity(
                pid: 99_999,
                uid: getuid(),
                executablePath: "/tmp/test-child",
                startSeconds: 1,
                startMicroseconds: 2
            ),
            name: "test-child"
        )
    }
}
#endif
