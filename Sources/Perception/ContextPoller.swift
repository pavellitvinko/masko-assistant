import Foundation

class ContextPoller {
    private let screenpipeClient: ScreenpipeClient
    private let fallback: FallbackPerception
    private let settingsProvider: () -> SmartFeatureSettings
    private var pollTask: Task<Void, Never>?
    
    var onContextChanged: ((ContextSnapshot) -> Void)?
    var onHealthChanged: ((ServiceHealth) -> Void)?
    private(set) var current: ContextSnapshot?
    private(set) var history: [ContextSnapshot] = []
    private(set) var health: ServiceHealth = .offline
    
    init(
        screenpipeClient: ScreenpipeClient,
        fallback: FallbackPerception,
        settingsProvider: @escaping () -> SmartFeatureSettings
    ) {
        self.screenpipeClient = screenpipeClient
        self.fallback = fallback
        self.settingsProvider = settingsProvider
    }
    
    func start() {
        stop()
        pollTask = Task { [weak self] in
            guard let self else { return }
            await self.update()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Constants.contextPollInterval * 1_000_000_000))
                if Task.isCancelled { break }
                await self.update()
            }
        }
    }
    
    func stop() {
        pollTask?.cancel()
        pollTask = nil
        setHealth(.offline)
    }
    
    private func update() async {
        var snapshot: ContextSnapshot
        let activeHint = fallback.snapshot()
        let settings = settingsProvider()

        guard settings.behaviorEnabled else {
            self.current = activeHint
            setHealth(.offline)
            return
        }

        guard settings.screenpipeEnabled else {
            snapshot = activeHint
            setHealth(.offline)

            let changed = isChanged(snapshot)
            self.current = snapshot
            if changed {
                history.append(snapshot)
                if history.count > 12 { history.removeFirst() }
                onContextChanged?(snapshot)
            }
            return
        }
        
        do {
            if let recent = try await fetchPreferredContext(activeHint: activeHint) {
                snapshot = ContextSnapshot(
                    appName: recent.app_name,
                    windowTitle: recent.window_name,
                    visibleText: String(recent.text.prefix(500)),
                    timestamp: Date(),
                    source: .screenpipe
                )
                debugLog("Selected OCR context app=\(recent.app_name) window=\(recent.window_name) textChars=\(recent.text.count)")
                setHealth(.connected)
            } else {
                snapshot = activeHint
                let healthy = await screenpipeClient.checkHealth()
                debugLog("No OCR context available, using fallback source=\(snapshot.source.rawValue) app=\(snapshot.appName) window=\(snapshot.windowTitle)")
                setHealth(healthy ? .degraded : .offline)
            }
        } catch {
            snapshot = activeHint
            let healthy = await screenpipeClient.checkHealth()
            debugLog("Screenpipe fetch failed (\(error.localizedDescription)); using fallback source=\(snapshot.source.rawValue) app=\(snapshot.appName)")
            setHealth(healthy ? .degraded : .offline)
        }
        
        let changed = isChanged(snapshot)
        self.current = snapshot
        
        if changed {
            history.append(snapshot)
            if history.count > 12 { history.removeFirst() } // Keep 2 minutes history
            debugLog("New recognized context source=\(snapshot.source.rawValue) app=\(snapshot.appName) window=\(snapshot.windowTitle) text=\"\(textPreview(snapshot.visibleText))\"")
            onContextChanged?(snapshot)
        } else {
            debugLog("Context unchanged source=\(snapshot.source.rawValue) app=\(snapshot.appName) window=\(snapshot.windowTitle)")
        }
    }
    
    private func isChanged(_ snapshot: ContextSnapshot) -> Bool {
        guard let last = current else { return true }
        if last.source != snapshot.source { return true }
        if last.appName != snapshot.appName { return true }
        if last.windowTitle != snapshot.windowTitle { return true }
        if last.visibleText.prefix(100) != snapshot.visibleText.prefix(100) { return true }
        return false
    }

    private func fetchPreferredContext(
        activeHint: ContextSnapshot
    ) async throws -> ScreenpipeClient.ScreenpipeContext? {
        for request in searchRequests(for: activeHint) {
            debugLog(
                "Querying screenpipe limit=\(request.limit) app=\(request.appName ?? "*") " +
                "window=\(request.windowName ?? "*") minLength=\(request.minLength.map(String.init) ?? "*")"
            )
            let contexts = try await screenpipeClient.getRecentContext(request: request)
            if let recent = selectPreferredContext(from: contexts, activeHint: activeHint) {
                return recent
            }
        }
        return nil
    }

    private func searchRequests(for activeHint: ContextSnapshot) -> [ScreenpipeClient.SearchRequest] {
        let preferredApp = normalized(activeHint.appName)
        let preferredWindow = normalized(activeHint.windowTitle)

        var requests: [ScreenpipeClient.SearchRequest] = []

        if !preferredApp.isEmpty, preferredApp != "none" {
            requests.append(
                ScreenpipeClient.SearchRequest(
                    limit: Self.scopedQueryLimit,
                    appName: activeHint.appName,
                    windowName: preferredWindow.isEmpty ? nil : activeHint.windowTitle,
                    minLength: Self.scopedMinLength
                )
            )

            requests.append(
                ScreenpipeClient.SearchRequest(
                    limit: Self.scopedQueryLimit,
                    appName: activeHint.appName,
                    windowName: nil,
                    minLength: Self.relaxedMinLength
                )
            )
        }

        requests.append(
            ScreenpipeClient.SearchRequest(
                limit: Self.globalQueryLimit,
                appName: nil,
                windowName: nil,
                minLength: Self.scopedMinLength
            )
        )

        return requests
    }

    private func selectPreferredContext(
        from contexts: [ScreenpipeClient.ScreenpipeContext],
        activeHint: ContextSnapshot
    ) -> ScreenpipeClient.ScreenpipeContext? {
        guard !contexts.isEmpty else { return nil }

        if let activeMatch = preferredActiveContext(in: contexts, activeHint: activeHint) {
            debugLog("Selecting active-window match app=\(activeMatch.app_name) window=\(activeMatch.window_name)")
            return activeMatch
        }

        if let bestOverall = bestMeaningfulContext(in: contexts) {
            debugLog("Selecting best overall meaningful context app=\(bestOverall.app_name) window=\(bestOverall.window_name)")
            return bestOverall
        }

        let newest = contexts.max(by: { timestamp(for: $0) < timestamp(for: $1) })
        if let newest {
            debugLog("Selecting newest context fallback app=\(newest.app_name) window=\(newest.window_name)")
        }
        return newest
    }

    private func preferredActiveContext(
        in contexts: [ScreenpipeClient.ScreenpipeContext],
        activeHint: ContextSnapshot
    ) -> ScreenpipeClient.ScreenpipeContext? {
        let preferredApp = normalized(activeHint.appName)
        guard !preferredApp.isEmpty, preferredApp != "none" else { return nil }

        let appMatches = contexts.filter { normalized($0.app_name) == preferredApp }
        guard !appMatches.isEmpty else { return nil }

        let preferredWindow = normalized(activeHint.windowTitle)
        if !preferredWindow.isEmpty {
            let windowMatches = appMatches.filter {
                let candidate = normalized($0.window_name)
                return candidate == preferredWindow
                    || candidate.contains(preferredWindow)
                    || preferredWindow.contains(candidate)
            }
            if let newestWindowMatch = windowMatches.max(by: { timestamp(for: $0) < timestamp(for: $1) }) {
                return newestWindowMatch
            }
        }

        return appMatches.max(by: { timestamp(for: $0) < timestamp(for: $1) })
    }

    private func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func timestamp(for context: ScreenpipeClient.ScreenpipeContext) -> Date {
        if let parsed = Self.iso8601WithFractional.date(from: context.timestamp)
            ?? Self.iso8601.date(from: context.timestamp) {
            return parsed
        }
        return .distantPast
    }

    private static let iso8601WithFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private func bestMeaningfulContext(in contexts: [ScreenpipeClient.ScreenpipeContext]) -> ScreenpipeClient.ScreenpipeContext? {
        guard !contexts.isEmpty else { return nil }
        return contexts.max(by: { qualityScore(for: $0) < qualityScore(for: $1) })
    }

    private func qualityScore(for context: ScreenpipeClient.ScreenpipeContext) -> Int {
        let trimmedText = context.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let textLength = min(trimmedText.count, 600)
        let tokenCount = trimmedText.split(whereSeparator: \.isWhitespace).count

        var score = textLength + (tokenCount * 8)

        if trimmedText.isEmpty {
            score -= 250
        } else if textLength < 20 {
            score -= 60
        }

        if Self.lowSignalApps.contains(context.app_name) {
            score -= 120
        }

        let windowName = context.window_name.lowercased()
        if Self.lowSignalWindowKeywords.contains(where: windowName.contains) {
            score -= 80
        }

        if context.focused == true {
            score += 50
        }

        // Prefer fresher records when quality is similar.
        let recencyBoost = max(0, Int(timestamp(for: context).timeIntervalSince1970) % 60)
        score += recencyBoost
        return score
    }

    private static let lowSignalApps: Set<String> = [
        "Control Centre",
        "Dock",
        "Notification Centre",
    ]

    private static let lowSignalWindowKeywords: [String] = [
        "clock",
        "battery",
        "wifi",
        "item-",
        "bentobox",
    ]

    private static let minMeaningfulScore = 120
    private static let scopedQueryLimit = 5
    private static let globalQueryLimit = 20
    private static let scopedMinLength = 400
    private static let relaxedMinLength = 250

    private func setHealth(_ next: ServiceHealth) {
        guard health != next else { return }
        debugLog("Perception health \(health.rawValue) -> \(next.rawValue)")
        health = next
        onHealthChanged?(next)
    }

    private func debugLog(_ message: String) {
        #if DEBUG
        print("[masko-desktop][context] \(message)")
        #endif
    }

    private func textPreview(_ text: String) -> String {
        let sanitized = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(sanitized.prefix(120))
    }
}
