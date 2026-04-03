import Foundation

struct BehaviorOutput {
    let mood: Mood
    let state: Behavior
    let isSpeaking: Bool
}

enum CommentDecision {
    case silent
    case speak(ContextSnapshot)
}

private struct LLMCommentResponse: Codable {
    enum Action: String, Codable {
        case silent
        case speak
    }

    let action: Action
    let text: String?
    let emotion: String?
}

class BehaviorEngine {
    private var innerState: InnerState
    private let contextPoller: ContextPoller
    private let windowTracker: WindowTracker
    private let ollamaClient: OllamaClient
    private let settingsProvider: () -> SmartFeatureSettings
    private let policyProvider: () -> BehaviorPolicy
    private let scheduler = BehaviorScheduler()
    private let commentCache = CommentCache()

    var onStateChanged: ((BehaviorOutput) -> Void)?
    var onSpeech: ((SpeechEvent) -> Void)?
    var onDismissSpeech: (() -> Void)?
    var onMovement: ((MovementCommand) -> Void)?
    var onCommentaryHealthChanged: ((ServiceHealth) -> Void)?

    private(set) var isSpeaking = false
    private var currentBehavior: Behavior = .stand_idle
    private var latestContext: ContextSnapshot?
    private var ollamaHealth: ServiceHealth = .offline
    private var speechToken = UUID()
    private var lastCommentAt: Date?
    private var lastCommentFingerprint: String?
    private var verbalPenaltyUntil: Date?
    private var verbalSuppressedUntil: Date?
    private var dismissTimestamps: [Date] = []

    private let verbalPenaltyDuration: TimeInterval = 10 * 60
    private let verbalSuppressionDuration: TimeInterval = 30 * 60
    private let maxCommentWords = 15

    init(
        innerState: InnerState,
        contextPoller: ContextPoller,
        windowTracker: WindowTracker,
        ollamaClient: OllamaClient,
        settingsProvider: @escaping () -> SmartFeatureSettings,
        policyProvider: @escaping () -> BehaviorPolicy
    ) {
        self.innerState = innerState
        self.contextPoller = contextPoller
        self.windowTracker = windowTracker
        self.ollamaClient = ollamaClient
        self.settingsProvider = settingsProvider
        self.policyProvider = policyProvider
        self.latestContext = contextPoller.current

        scheduler.onTick = { [weak self] in
            self?.selectBehavior()
        }
    }

    func start() {
        scheduler.start()
    }

    func stop() {
        scheduler.stop()
        clearSpeakingState()
        innerState.save()
    }

    func onContextChanged(_ snapshot: ContextSnapshot) {
        latestContext = snapshot
        debugLog("Behavior received context source=\(snapshot.source.rawValue) app=\(snapshot.appName) window=\(snapshot.windowTitle) text=\"\(textPreview(snapshot.visibleText))\"")
        let decision = decideCommentAction(context: snapshot)
        ContextNudger.nudge(state: &innerState, with: snapshot)
        if ErrorDetector.containsSuccess(snapshot.visibleText) {
            innerState.comfort += 0.03
            innerState.clamp()
        }
        emitState()

        // Drive commentary from fresh context, not only from periodic behavior ticks.
        if case .speak = decision, shouldNudgeComment(now: Date()) {
            debugLog("Nudging immediate comment behavior after context update")
            executeBehavior(.comment)
        }
    }

    func setOllamaHealth(_ health: ServiceHealth) {
        if ollamaHealth != health {
            debugLog("Ollama health \(ollamaHealth.rawValue) -> \(health.rawValue)")
        }
        ollamaHealth = health
    }

    func onAgentEvent(_ event: AgentEvent) {
        guard let eventType = event.eventType else { return }

        switch eventType {
        case .sessionStart:
            innerState.energy += 0.15
            innerState.clamp()
            forceBehavior(.wave)
        case .taskCompleted:
            forceBehavior(.celebrate)
        case .stop:
            if event.reason != "interrupted" {
                forceBehavior(.celebrate)
            }
        case .postToolUseFailure, .stopFailure:
            innerState.comfort -= 0.1
            innerState.clamp()
            forceBehavior(.startle)
        case .preCompact:
            innerState.energy -= 0.05
            innerState.clamp()
        case .permissionRequest:
            forceBehavior(.wave)
        default:
            break
        }
    }

    func onBubbleDismissed() {
        clearSpeakingState()

        let now = Date()
        dismissTimestamps = dismissTimestamps.filter { now.timeIntervalSince($0) <= verbalSuppressionDuration }
        dismissTimestamps.append(now)

        if dismissTimestamps.count >= 3 {
            verbalSuppressedUntil = now.addingTimeInterval(verbalSuppressionDuration)
            verbalPenaltyUntil = verbalSuppressedUntil
            return
        }

        if dismissTimestamps.count == 1 {
            verbalPenaltyUntil = now.addingTimeInterval(verbalPenaltyDuration)
        }
    }

    func decideCommentAction(context: ContextSnapshot) -> CommentDecision {
        let contextInfo = contextDebugDescription(context)
        let settings = settingsProvider()
        let policy = policyProvider()

        if !settings.behaviorEnabled {
            debugDecision("silent", reason: "behavior_disabled", contextInfo: contextInfo)
            return .silent
        }

        if !settings.screenpipeEnabled {
            debugDecision("silent", reason: "screenpipe_feature_disabled", contextInfo: contextInfo)
            return .silent
        }

        if !settings.ollamaEnabled {
            debugDecision("silent", reason: "ollama_feature_disabled", contextInfo: contextInfo)
            return .silent
        }

        if policy.requireScreenpipeContext, context.source != .screenpipe {
            debugDecision("silent", reason: "requires_screenpipe_context", contextInfo: contextInfo)
            return .silent
        }

        if policy.requireOllamaHealth, ollamaHealth != .connected {
            debugDecision("silent", reason: "ollama_not_connected", contextInfo: contextInfo)
            return .silent
        }

        let now = Date()
        if let suppressedUntil = verbalSuppressedUntil, now < suppressedUntil {
            debugDecision("silent", reason: "verbal_suppressed_until_\(suppressedUntil.timeIntervalSince1970)", contextInfo: contextInfo)
            return .silent
        }

        if isSpeaking {
            debugDecision("silent", reason: "already_speaking", contextInfo: contextInfo)
            return .silent
        }

        let cooldown = policy.commentCooldown
        if let lastCommentAt,
           now.timeIntervalSince(lastCommentAt) < cooldown {
            let elapsed = now.timeIntervalSince(lastCommentAt)
            debugDecision("silent", reason: "cooldown_active elapsed=\(format(elapsed)) threshold=\(format(cooldown))", contextInfo: contextInfo)
            return .silent
        }

        var scoredInterest: Float?
        var errorBoost: Float = 0
        var successBoost: Float = 0
        var interest = InterestScorer.score(context: context)
        if ErrorDetector.containsError(context.visibleText) {
            errorBoost = policy.errorBoost
            interest += errorBoost
        }
        if ErrorDetector.containsSuccess(context.visibleText) {
            successBoost = policy.successBoost
            interest += successBoost
        }
        let threshold = policy.interestThreshold
        scoredInterest = interest
        if interest < threshold {
            debugDecision(
                "silent",
                reason: "interest_below_threshold score=\(format(interest)) threshold=\(format(threshold)) errorBoost=\(format(errorBoost)) successBoost=\(format(successBoost))",
                contextInfo: contextInfo
            )
            return .silent
        }

        if policy.suppressRepeatedContext {
            let fingerprint = Self.contextFingerprint(context)
            if lastCommentFingerprint == fingerprint {
                debugDecision("silent", reason: "repeated_context_fingerprint", contextInfo: contextInfo)
                return .silent
            }
        }

        let interestDebug = "score=\(format(scoredInterest ?? interest)) threshold=\(format(threshold)) errorBoost=\(format(errorBoost)) successBoost=\(format(successBoost))"
        debugDecision("speak", reason: "all_gates_passed \(interestDebug)", contextInfo: contextInfo)
        return .speak(context)
    }

    func triggerCommentaryProbe() {
        Task { [weak self] in
            await self?.runCommentaryProbe()
        }
    }

    private func selectBehavior() {
        debugLog("Behavior tick mood=\(innerState.mood.rawValue)")
        applyNaturalDrift()

        var weights = BehaviorWeights.weights(for: innerState.mood)
        let now = Date()

        if let context = latestContext ?? contextPoller.current,
           case .speak = decideCommentAction(context: context),
           shouldNudgeComment(now: now) {
            debugLog("Nudging immediate comment behavior after gate pass")
            executeBehavior(.comment)
            return
        }

        if let suppressedUntil = verbalSuppressedUntil, now < suppressedUntil {
            weights[.comment] = 0
            weights[.mutter] = 0
            weights[.emote] = 0
        } else if let penaltyUntil = verbalPenaltyUntil, now < penaltyUntil {
            weights[.comment] = (weights[.comment] ?? 0) * 0.5
            weights[.mutter] = (weights[.mutter] ?? 0) * 0.5
            weights[.emote] = (weights[.emote] ?? 0) * 0.5
        }

        guard let behavior = selectWeightedRandom(weights) else { return }
        executeBehavior(behavior)
    }

    private func shouldNudgeComment(now: Date) -> Bool {
        guard let lastCommentAt else { return true }
        let elapsed = now.timeIntervalSince(lastCommentAt)
        let requiredInterval = policyProvider().commentCooldown
        if elapsed < requiredInterval {
            debugLog("Comment nudge skipped: elapsed=\(format(elapsed)) required=\(format(requiredInterval))")
            return false
        }
        return true
    }

    private func forceBehavior(_ behavior: Behavior) {
        executeBehavior(behavior, forced: true)
    }

    private func executeBehavior(_ behavior: Behavior, forced: Bool = false) {
        currentBehavior = behavior

        switch behavior {
        case .walk_on_surface:
            onMovement?(.walk(direction: Bool.random() ? 1 : -1))
            clearSpeakingState()
            emitState()
        case .comment:
            Task { [weak self] in
                await self?.handleCommentBehavior()
            }
        case .mutter:
            let phrase = MutterLibrary.lookup(for: latestContext ?? FallbackPerceptionSnapshot.empty) ?? "hmm."
            publishSpeech(SpeechEvent(text: phrase, tier: .mutter, emotion: nil))
        case .emote:
            let emotes = ["💤", "😮", "🤔", "💡", "❤️", "🔥"]
            publishSpeech(SpeechEvent(text: emotes.randomElement() ?? "🤔", tier: .emote, emotion: nil))
        case .startle, .wave, .celebrate:
            clearSpeakingState()
            emitState()
        default:
            if !forced {
                clearSpeakingState()
            }
            emitState()
        }
    }

    private func handleCommentBehavior() async {
        guard let context = latestContext ?? contextPoller.current else {
            debugLog("Comment behavior: no context available")
            clearSpeakingState()
            emitState()
            return
        }

        switch decideCommentAction(context: context) {
        case .silent:
            debugLog("Comment behavior: decision=silent")
            clearSpeakingState()
            emitState()
        case .speak(let snapshot):
            debugLog("Comment behavior: decision=speak")
            await generateComment(for: snapshot)
        }
    }

    private func runCommentaryProbe() async {
        guard settingsProvider().ollamaEnabled else {
            debugLog("Commentary probe aborted: ollama feature disabled")
            onCommentaryHealthChanged?(.offline)
            return
        }

        let context = latestContext ?? contextPoller.current ?? FallbackPerceptionSnapshot.empty
        debugLog("Commentary probe running with context source=\(context.source.rawValue) app=\(context.appName) window=\(context.windowTitle)")
        await generateComment(for: context)
    }

    private func generateComment(for context: ContextSnapshot) async {
        debugLog("Generating comment for source=\(context.source.rawValue) app=\(context.appName) window=\(context.windowTitle) text=\"\(textPreview(context.visibleText))\"")
        isSpeaking = true
        emitState()

        do {
            let prompt = """
            App: \(context.appName)
            Window: \(context.windowTitle)
            Text: \(context.visibleText)
            """
            let response = try await ollamaClient.generate(
                prompt: prompt,
                system: Personality.systemPromptTemplate
            )

            guard let parsed = Self.parseCommentResponse(response) else {
                debugLog("Comment response parse failed")
                onCommentaryHealthChanged?(.degraded)
                clearSpeakingState()
                emitState()
                return
            }

            guard parsed.action == .speak else {
                debugLog("Comment response action=\(parsed.action.rawValue), skipping speech")
                onCommentaryHealthChanged?(.connected)
                clearSpeakingState()
                emitState()
                return
            }

            guard let rawText = parsed.text,
                  let text = Self.sanitizedCommentText(rawText, maxWords: maxCommentWords) else {
                debugLog("Comment response missing/invalid text")
                onCommentaryHealthChanged?(.degraded)
                clearSpeakingState()
                emitState()
                return
            }

            if policyProvider().dedupeOutput {
                guard commentCache.isOriginal(text) else {
                    debugLog("Comment dedupe rejected repeated text")
                    onCommentaryHealthChanged?(.degraded)
                    clearSpeakingState()
                    emitState()
                    return
                }
                commentCache.add(text)
            }

            lastCommentAt = Date()
            lastCommentFingerprint = Self.contextFingerprint(context)
            onCommentaryHealthChanged?(.connected)

            publishSpeech(SpeechEvent(text: text, tier: .comment, emotion: parsed.emotion))
        } catch {
            debugLog("Comment generation failed: \(error.localizedDescription)")
            onCommentaryHealthChanged?(.offline)
            clearSpeakingState()
            emitState()
        }
    }

    private func publishSpeech(_ event: SpeechEvent) {
        guard Thread.isMainThread else {
            Task { @MainActor [weak self] in
                self?.publishSpeech(event)
            }
            return
        }

        onDismissSpeech?()
        isSpeaking = true
        emitState()
        onSpeech?(event)

        let token = UUID()
        speechToken = token
        let duration = speechDuration(for: event.tier)

        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self, self.speechToken == token else { return }
            self.clearSpeakingState()
            self.emitState()
        }
    }

    private func clearSpeakingState() {
        speechToken = UUID()
        isSpeaking = false
    }

    private func speechDuration(for tier: SpeechTier) -> TimeInterval {
        switch tier {
        case .emote:
            return 2
        case .mutter:
            return 3
        case .comment:
            return 4
        }
    }

    private func emitState() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.emitState()
            }
            return
        }
        onStateChanged?(BehaviorOutput(mood: innerState.mood, state: currentBehavior, isSpeaking: isSpeaking))
    }

    private func selectWeightedRandom(_ weights: [Behavior: Float]) -> Behavior? {
        let total = weights.values.reduce(0, +)
        guard total > 0 else { return nil }
        let r = Float.random(in: 0..<total)
        var cumulative: Float = 0
        for (behavior, weight) in weights {
            cumulative += weight
            if r < cumulative { return behavior }
        }
        return nil
    }

    private func applyNaturalDrift() {
        innerState.energy -= 0.008
        let hour = Calendar.current.component(.hour, from: Date())
        if hour >= 22 {
            innerState.energy -= 0.015
        }
        innerState.clamp()
    }

    private func debugDecision(_ decision: String, reason: String, contextInfo: String) {
        debugLog("Decision=\(decision) reason=\(reason) \(contextInfo)")
    }

    private func debugLog(_ message: String) {
        #if DEBUG
        print("[masko-desktop][behavior] \(message)")
        #endif
    }

    private func contextDebugDescription(_ context: ContextSnapshot) -> String {
        "source=\(context.source.rawValue) app=\(context.appName) window=\(context.windowTitle) textPreview=\"\(textPreview(context.visibleText))\""
    }

    private func textPreview(_ text: String) -> String {
        let sanitized = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(sanitized.prefix(120))
    }

    private func format(_ value: Float) -> String {
        String(format: "%.2f", value)
    }

    private func format(_ value: TimeInterval) -> String {
        String(format: "%.2f", value)
    }

    private static func contextFingerprint(_ context: ContextSnapshot) -> String {
        let raw = "\(context.appName)|\(context.windowTitle)|\(context.visibleText.prefix(100))"
        let filtered = String(
            raw
            .lowercased()
            .map { char in
                (char.isLetter || char.isNumber || char.isWhitespace) ? char : " "
            }
        )
        return filtered.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func parseCommentResponse(_ response: String) -> LLMCommentResponse? {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let parsed = decodeCommentResponse(trimmed) {
            return parsed
        }

        let unfenced = trimmed
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if unfenced != trimmed, let parsed = decodeCommentResponse(unfenced) {
            return parsed
        }

        if let extracted = extractFirstJSONObject(from: trimmed) {
            return decodeCommentResponse(extracted)
        }

        return nil
    }

    private static func decodeCommentResponse(_ raw: String) -> LLMCommentResponse? {
        guard let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(LLMCommentResponse.self, from: data)
    }

    private static func extractFirstJSONObject(from text: String) -> String? {
        var startIndex: String.Index?
        var depth = 0
        var isInsideString = false
        var isEscaped = false

        for index in text.indices {
            let char = text[index]

            if isInsideString {
                if isEscaped {
                    isEscaped = false
                    continue
                }
                if char == "\\" {
                    isEscaped = true
                    continue
                }
                if char == "\"" {
                    isInsideString = false
                }
                continue
            }

            if char == "\"" {
                isInsideString = true
                continue
            }

            if char == "{" {
                if startIndex == nil {
                    startIndex = index
                }
                depth += 1
                continue
            }

            if char == "}" {
                guard depth > 0 else { continue }
                depth -= 1
                if depth == 0, let startIndex {
                    let endIndex = text.index(after: index)
                    return String(text[startIndex..<endIndex])
                }
            }
        }

        return nil
    }

    private static func sanitizedCommentText(_ text: String, maxWords: Int) -> String? {
        let oneLine = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !oneLine.isEmpty else { return nil }

        let words = oneLine
            .split(whereSeparator: \.isWhitespace)
            .prefix(maxWords)
        guard !words.isEmpty else { return nil }

        let sanitized = words.joined(separator: " ")
        return sanitized.isEmpty ? nil : sanitized
    }

}

private enum FallbackPerceptionSnapshot {
    static let empty = ContextSnapshot(
        appName: "None",
        windowTitle: "",
        visibleText: "",
        timestamp: Date(),
        source: .none
    )
}
