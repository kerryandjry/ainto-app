import Foundation

extension SearchViewModel {
    func scheduleProcessSearch(for term: String, originalQuery: String) {
        guard !term.isEmpty else {
            results = [processStatusResult(
                title: "Type a process name or PID",
                subtitle: "Process Search · The exact query ‘kill’ remains available to apps and aliases",
                icon: "terminal"
            )]
            selectedIndex = 0
            return
        }

        results = [processStatusResult(
            title: "Searching processes…",
            subtitle: "Process Search · Current user only",
            icon: "hourglass"
        )]
        selectedIndex = 0
        let generation = UUID()
        processSearchGeneration = generation
        processSearchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard !Task.isCancelled else { return }
            let candidates = await Task.detached {
                ProcessSearchService.matchingProcesses(for: term)
            }.value
            guard let self,
                  !Task.isCancelled,
                  self.processSearchGeneration == generation,
                  self.query == originalQuery,
                  self.page == .main else { return }
            self.processCandidates = candidates
            self.results = candidates.isEmpty
                ? [self.processStatusResult(
                    title: "No matching process",
                    subtitle: "Try a process name, executable path, or PID",
                    icon: "xmark.circle"
                )]
                : candidates.map { self.processResult($0) }
            self.selectedIndex = 0
        }
    }

    private func processResult(_ candidate: ProcessCandidate) -> SearchResult {
        var result = SearchResult(
            title: candidate.name,
            subtitle: "Process · PID \(candidate.pid) · \(candidate.executablePath)",
            icon: nil,
            systemIcon: "terminal",
            score: 9_000
        ) { [weak self] in
            self?.armProcessKill(candidate)
        }
        result.isProcessSearchCandidate = true
        result.keepsPanelOpenAfterAction = true
        result.actions = [
            ActionItem(
                title: "Prepare Force Kill",
                icon: "exclamationmark.octagon",
                shortcut: "↵",
                keepPanel: true
            ) { [weak self] in
                self?.armProcessKill(candidate)
            }
        ]
        return result
    }

    func armProcessKill(_ candidate: ProcessCandidate) {
        guard ProcessSearchService.searchTerm(for: query) != nil,
              processCandidates.contains(where: { $0.identity == candidate.identity }) else { return }
        pendingProcessKill = candidate
        let token = UUID()
        processConfirmationToken = token

        var confirmation = SearchResult(
            title: "Force kill \(candidate.name) (PID \(candidate.pid))?",
            subtitle: "Unsaved data will be lost · Press ⌘↵ to confirm",
            icon: nil,
            systemIcon: "exclamationmark.octagon.fill",
            score: 10_000
        ) {}
        confirmation.alternateAction = { [weak self] in
            self?.confirmProcessKill(candidate)
        }
        confirmation.isProcessKillConfirmation = true
        confirmation.keepsPanelOpenAfterAction = true
        results = [confirmation]
        selectedIndex = 0

        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            self?.expireProcessKillConfirmation(token: token)
        }
    }

    func expireProcessKillConfirmation(token: UUID) {
        guard processConfirmationToken == token else { return }
        _ = cancelPendingProcessKillIfNeeded()
    }

    @discardableResult
    func cancelPendingProcessKillIfNeeded() -> Bool {
        guard pendingProcessKill != nil else { return false }
        pendingProcessKill = nil
        processConfirmationToken = nil
        restoreProcessResults()
        return true
    }

    private func confirmProcessKill(_ candidate: ProcessCandidate) {
        guard pendingProcessKill?.identity == candidate.identity else { return }
        pendingProcessKill = nil
        processConfirmationToken = nil
        let originalQuery = query
        results = [processStatusResult(
            title: "Force killing \(candidate.name)…",
            subtitle: "PID \(candidate.pid)",
            icon: "hourglass"
        )]
        selectedIndex = 0

        Task { [weak self] in
            let outcome = await Task.detached {
                ProcessSearchService.forceKill(candidate)
            }.value
            guard let self, self.query == originalQuery else { return }
            switch outcome {
            case .signalSent:
                self.clearQuery()
                self.performSearch(query: "")
                self.onProcessKillCompleted?()
            case .stale:
                self.showProcessKillFailure(
                    candidate,
                    message: "The selected process is no longer running."
                )
            case .forbidden(let message), .failed(let message):
                self.showProcessKillFailure(candidate, message: message)
            }
        }
    }

    private func showProcessKillFailure(_ candidate: ProcessCandidate, message: String) {
        var failure = SearchResult(
            title: "Could not force kill \(candidate.name)",
            subtitle: message,
            icon: nil,
            systemIcon: "exclamationmark.triangle.fill",
            score: 10_000
        ) { [weak self] in
            self?.restoreProcessResults()
        }
        failure.keepsPanelOpenAfterAction = true
        results = [failure]
        selectedIndex = 0
    }

    private func restoreProcessResults() {
        results = processCandidates.map { processResult($0) }
        if results.isEmpty {
            results = [processStatusResult(
                title: "No matching process",
                subtitle: "Try a process name, executable path, or PID",
                icon: "xmark.circle"
            )]
        }
        selectedIndex = 0
    }

    private func processStatusResult(title: String, subtitle: String, icon: String) -> SearchResult {
        var result = SearchResult(
            title: title,
            subtitle: subtitle,
            icon: nil,
            systemIcon: icon,
            score: 9_000
        ) {}
        result.keepsPanelOpenAfterAction = true
        return result
    }
}
