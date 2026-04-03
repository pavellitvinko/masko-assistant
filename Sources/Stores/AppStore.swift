import AppKit
import Foundation

@Observable
final class AppStore {
    struct AssistantEventIngestionStatus {
        let isActive: Bool
        let text: String
    }

    let eventBus = MaskoEventBus()
    let claudeCodeAdapter = ClaudeCodeAdapter()
    let copilotAdapter = CopilotAdapter()
    let codexAdapter = CodexAdapter()
    let eventStore = EventStore()
    let sessionStore = SessionStore()
    let notificationStore = NotificationStore()
    let notificationService = NotificationService.shared
    let pendingPermissionStore = PendingPermissionStore()
    let mascotStore = MascotStore()
    let hotkeyManager = GlobalHotkeyManager()
    let sessionSwitcherStore = SessionSwitcherStore()
    let sessionFinishedStore = SessionFinishedStore()
    let approvalHistoryStore = ApprovalHistoryStore()
    private let defaults: UserDefaults

    // Spatial & behavior
    private(set) var desktopTopology: DesktopTopology?
    private(set) var movementController: MovementController?
    private(set) var behaviorEngine: BehaviorEngine?
    private(set) var contextPoller: ContextPoller?
    private(set) var screenpipeClient: ScreenpipeClient?
    private(set) var ollamaClient: OllamaClient?
    private(set) var screenpipeHealth: ServiceHealth = .offline
    private(set) var isScreenpipeAudioCaptureDetected = false
    private(set) var ollamaHealth: ServiceHealth = .offline
    private var smartHealthTimer: Timer?

    private(set) var eventProcessor: EventProcessor!
    private(set) var isReady = false
    private(set) var isRunning = false
    private var lastReconcileDate: Date = .distantPast
    private(set) var smartFeatureSettings: SmartFeatureSettings {
        didSet {
            guard oldValue != smartFeatureSettings else { return }
            smartFeatureSettings.persist(in: defaults)
            guard isRunning else { return }
            applySmartFeatureLifecycle()
        }
    }
    #if DEBUG
    private(set) var debugCommentInterestThresholdOverride: Double? {
        didSet {
            guard oldValue != debugCommentInterestThresholdOverride else { return }
            BehaviorDebugSettings.persist(debugCommentInterestThresholdOverride, in: defaults)
        }
    }
    #endif

    /// Cached IDE detection results — survives across SettingsView recreations.
    /// Updated by SettingsView.task and install/uninstall actions.
    var cachedIDEStatuses: [ExtensionInstaller.IDEStatus] = []

    /// Convenience access to the Claude Code local server for UI status indicators
    var localServer: LocalServer { claudeCodeAdapter.localServer }

    /// Called when an agent event is received - wire to OverlayManager.handleEvent
    var onEventForOverlay: ((AgentEvent) -> Void)?
    /// Called when a custom input is received via POST /input
    var onInputForOverlay: ((String, ConditionValue) -> Void)?
    /// Called when session phases change outside of events (e.g. interrupt detection via transcript)
    var onRefreshOverlay: (() -> Void)?
    /// Called when the session-finished toast appears/dismisses — trigger panel reposition
    var onToastChanged: (() -> Void)?

    /// Expanded permission panel callback — wire to OverlayManager
    var onExpandPermission: (() -> Void)?

    /// Session switcher overlay callbacks — wire to OverlayManager
    var onSessionSwitcherShow: (() -> Void)?
    var onSessionSwitcherUpdate: (() -> Void)?
    var onSessionSwitcherDismiss: (() -> Void)?

    /// Set by URL handler to navigate to a mascot after install
    var navigateToMascotId: UUID?

    static func assistantEventIngestionStatus(
        localServerRunning: Bool,
        localServerPort: UInt16,
        codexMonitorRunning: Bool
    ) -> AssistantEventIngestionStatus {
        let text: String
        switch (localServerRunning, codexMonitorRunning) {
        case (true, true):
            text = "Listening on \(localServerPort) + Codex logs"
        case (true, false):
            text = "Listening on \(localServerPort)"
        case (false, true):
            text = "Listening to Codex logs"
        case (false, false):
            text = "Offline"
        }
        return AssistantEventIngestionStatus(
            isActive: localServerRunning || codexMonitorRunning,
            text: text
        )
    }

    var hasUnreadNotifications: Bool { notificationStore.unreadCount > 0 }
    var assistantEventIngestionStatus: AssistantEventIngestionStatus {
        Self.assistantEventIngestionStatus(
            localServerRunning: localServer.isRunning,
            localServerPort: localServer.port,
            codexMonitorRunning: codexAdapter.isRunning
        )
    }
    var isAssistantEventIngestionActive: Bool { assistantEventIngestionStatus.isActive }
    var assistantEventIngestionStatusText: String { assistantEventIngestionStatus.text }
    var screenpipeHealthText: String { screenpipeHealth.displayText }
    var screenpipeAudioWarningText: String? {
        guard isScreenpipeAudioCaptureDetected else { return nil }
        return "Screenpipe audio capture detected. Restart with --disable-audio."
    }
    var ollamaHealthText: String { ollamaHealth.displayText }

    var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: "hasCompletedOnboarding") }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        SmartFeatureSettings.registerDefaults(in: defaults)
        SmartFeatureSettings.migrateLegacySettings(in: defaults)
        self.smartFeatureSettings = SmartFeatureSettings.load(from: defaults)
        self.hasCompletedOnboarding = defaults.bool(forKey: "hasCompletedOnboarding")
        #if DEBUG
        self.debugCommentInterestThresholdOverride = BehaviorDebugSettings.load(from: defaults)
        #endif
        self.eventProcessor = EventProcessor(
            eventStore: eventStore,
            sessionStore: sessionStore,
            notificationStore: notificationStore,
            notificationService: notificationService
        )

        // Register adapters with the event bus
        eventBus.register(claudeCodeAdapter)
        eventBus.register(copilotAdapter)
        eventBus.register(codexAdapter)

        // Wire event bus -> event processor + overlay state machine
        eventBus.onEvent = { [weak self] event in
            guard let self else { return }
            Task { @MainActor in
                await self.eventProcessor.process(event)

                // If a subsequent event arrives for a session with pending permissions,
                // the user may have resolved a permission from the terminal - dismiss it.
                // For postToolUse/postToolUseFailure: only dismiss the SPECIFIC tool use
                // that completed (by toolUseId), not all permissions for the agent.
                // For stop/userPromptSubmit: session is ending, dismiss all for that agent.
                if let eventType = event.eventType,
                   let sid = event.sessionId {
                    // Cache PreToolUse toolUseId - fires immediately before PermissionRequest
                    // for the same tool call, and carries the tool_use_id that PermissionRequest lacks.
                    if eventType == .preToolUse,
                       let toolUseId = event.toolUseId,
                       let toolName = event.toolName {
                        self.pendingPermissionStore.cachePreToolUse(
                            sessionId: sid, agentId: event.agentId,
                            toolName: toolName, toolUseId: toolUseId
                        )
                    }

                    // Codex approvals answered in the terminal can emit follow-up events
                    // (for example a second PreToolUse/exec begin) before the tool completes.
                    // If we see any later non-permission event for the same toolUseId, the
                    // approval card is stale and should close immediately.
                    if eventType != .permissionRequest,
                       let toolUseId = event.toolUseId {
                        self.pendingPermissionStore.dismissByToolUseId(sessionId: sid, toolUseId: toolUseId)
                    }

                    if [.stop, .userPromptSubmit].contains(eventType),
                       self.pendingPermissionStore.pending.contains(where: {
                           $0.event.sessionId == sid && $0.event.agentId == event.agentId
                       }) {
                        self.pendingPermissionStore.dismissForAgent(sessionId: sid, agentId: event.agentId)
                    } else if [.postToolUse, .postToolUseFailure].contains(eventType),
                              let toolUseId = event.toolUseId {
                        self.pendingPermissionStore.dismissByToolUseId(sessionId: sid, toolUseId: toolUseId)
                    }
                }

                // Show "task completed" toast when agent finishes (skip interrupts)
                if event.eventType == .stop,
                   event.reason != "interrupted",
                   !self.pendingPermissionStore.pending.contains(where: { $0.event.sessionId == event.sessionId }) {
                    self.sessionFinishedStore.show(
                        sessionId: event.sessionId ?? "",
                        projectName: event.projectName ?? "Project"
                    )
                    self.syncActiveCard()
                    self.onToastChanged?()
                }

                // Dismiss toast when user starts typing (already back in the loop)
                if event.eventType == .userPromptSubmit {
                    self.sessionFinishedStore.dismiss()
                }

                self.onEventForOverlay?(event)
                
                // Feed agent events to behavior engine for reactions
                if self.smartFeatureSettings.behaviorEnabled {
                    self.behaviorEngine?.onAgentEvent(event)
                }
            }
        }

        // Wire event bus -> custom input endpoint
        eventBus.onInput = { [weak self] name, value in
            guard let self else { return }
            Task { @MainActor in
                self.onInputForOverlay?(name, value)
            }
        }

        // Wire Claude Code adapter -> direct mascot install from web app
        claudeCodeAdapter.onInstall = { [weak self] config in
            guard let self else { return }
            self.mascotStore.addOrUpdateFromPush(config: config)
            if let mascot = self.mascotStore.mascots.first(where: { $0.name == config.name }) {
                self.navigateToMascotId = mascot.id
            }
            AppDelegate.showDashboard()
        }

        // Wire event bus -> permission requests (with transport for responding)
        eventBus.onPermissionRequest = { [weak self] event, transport in
            guard let self else { return }
            Task { @MainActor in
                self.pendingPermissionStore.add(event: event, transport: transport)
            }
        }

        // Wire interrupt detection → overlay refresh + session count sync + switcher refresh
        sessionStore.onPhasesChanged = { [weak self] in
            guard let self else { return }
            self.onRefreshOverlay?()
            let activeCount = self.sessionStore.activeSessions.count
            self.hotkeyManager.activeSessionCount = activeCount

            // Auto-dismiss or refresh session switcher when sessions change
            if self.sessionSwitcherStore.isActive {
                if activeCount < 2 {
                    self.sessionSwitcherStore.close()
                    self.syncActiveCard()
                    self.onSessionSwitcherDismiss?()
                } else {
                    self.sessionSwitcherStore.refresh(sessions: self.sessionStore.activeSessions)
                    self.onSessionSwitcherUpdate?()
                }
            }
        }

        // Wire pending permission count → sync active card
        pendingPermissionStore.onPendingCountChange = { [weak self] in
            self?.syncActiveCard()
        }

        // Wire session finished toast dismiss → sync active card + panel reposition
        sessionFinishedStore.onDismiss = { [weak self] in
            self?.syncActiveCard()
            self?.onToastChanged?()
        }

        // Set initial count
        hotkeyManager.activeSessionCount = sessionStore.activeSessions.count

        // Wire session switcher tap-to-confirm (clicked a row)
        sessionSwitcherStore.onTapConfirm = { [weak self] session in
            guard let self else { return }
            self.sessionSwitcherStore.close()
            self.syncActiveCard()
            IDETerminalFocus.focusSession(session)
            self.onSessionSwitcherDismiss?()
        }

        // Auto-dismiss session switcher after inactivity to prevent stuck keyboard capture
        sessionSwitcherStore.onAutoDismiss = { [weak self] in
            guard let self else { return }
            self.syncActiveCard()
            self.onSessionSwitcherDismiss?()
        }

        // Wire hotkey manager — session switcher open (double-tap Cmd)
        hotkeyManager.onSessionSwitcherOpen = { [weak self] in
            guard let self else { return }
            // Don't open session switcher if expanded permission panel has focus
            if self.hotkeyManager.isExpandedPermissionActive { return }
            let active = self.sessionStore.activeSessions
            self.sessionSwitcherStore.open(sessions: active)
            self.syncActiveCard()
            self.onSessionSwitcherShow?()
        }

        hotkeyManager.onSessionSwitcherNext = { [weak self] in
            self?.sessionSwitcherStore.selectNext()
            self?.onSessionSwitcherUpdate?()
        }

        hotkeyManager.onSessionSwitcherPrev = { [weak self] in
            self?.sessionSwitcherStore.selectPrevious()
            self?.onSessionSwitcherUpdate?()
        }

        // Wire hotkey manager — ⌘N selects Nth item within topmost card
        hotkeyManager.onSelect = { [weak self] index in
            guard let self else { return }
            switch self.hotkeyManager.activeCard {
            case .sessionSwitcher:
                self.sessionSwitcherStore.selectIndex(index)
                // Immediately confirm — Cmd+N is a direct jump
                if let session = self.sessionSwitcherStore.confirm() {
                    IDETerminalFocus.focusSession(session)
                }
                self.syncActiveCard()
                self.onSessionSwitcherDismiss?()
            case .permission:
                guard !self.pendingPermissionStore.pending.isEmpty else { return }
                if self.hotkeyManager.selectedButtonIndex == index {
                    self.hotkeyManager.selectedButtonIndex = nil
                } else {
                    self.hotkeyManager.selectedButtonIndex = index
                }
            case .expandedPermission:
                // Route through same mechanism - PermissionContentView observes selectedButtonIndex
                if self.hotkeyManager.selectedButtonIndex == index {
                    self.hotkeyManager.selectedButtonIndex = nil
                } else {
                    self.hotkeyManager.selectedButtonIndex = index
                }
            case .toast, .none:
                break
            }
        }

        // Wire hotkey manager — ⌘Enter confirms the topmost card
        hotkeyManager.onConfirm = { [weak self] in
            guard let self else { return }
            switch self.hotkeyManager.activeCard {
            case .sessionSwitcher:
                if let session = self.sessionSwitcherStore.confirm() {
                    IDETerminalFocus.focusSession(session)
                }
                self.syncActiveCard()
                self.onSessionSwitcherDismiss?()
            case .permission:
                self.hotkeyManager.confirmTrigger += 1
            case .expandedPermission:
                self.hotkeyManager.confirmTrigger += 1
            case .toast:
                self.sessionFinishedStore.dismiss()
            case .none:
                break
            }
        }

        // Wire hotkey manager — Esc/⌘Esc dismisses the topmost card
        hotkeyManager.onDismiss = { [weak self] in
            guard let self else { return }
            switch self.hotkeyManager.activeCard {
            case .sessionSwitcher:
                self.sessionSwitcherStore.close()
                self.syncActiveCard()
                self.onSessionSwitcherDismiss?()
            case .expandedPermission:
                self.onExpandPermission?() // Toggle close
            case .permission:
                let reversed = Array(self.pendingPermissionStore.pending.reversed())
                guard let topPerm = reversed.first(where: { !self.pendingPermissionStore.collapsed.contains($0.id) }) else { return }
                self.pendingPermissionStore.resolve(id: topPerm.id, decision: .deny)
            case .toast:
                self.sessionFinishedStore.dismiss()
            case .none:
                break
            }
        }

        // Wire hotkey manager — ⌘L toggles collapse: collapse topmost, or expand if all collapsed
        // If expanded panel is open, close it and collapse the permission
        hotkeyManager.onCollapsePermission = { [weak self] in
            guard let self else { return }
            if self.hotkeyManager.isExpandedPermissionActive {
                self.onExpandPermission?() // Close expanded panel
            }
            let reversed = Array(self.pendingPermissionStore.pending.reversed())
            if let topNonCollapsed = reversed.first(where: { !self.pendingPermissionStore.collapsed.contains($0.id) }) {
                self.pendingPermissionStore.collapse(id: topNonCollapsed.id)
            } else if let topCollapsed = reversed.first {
                self.pendingPermissionStore.expand(id: topCollapsed.id)
            }
        }

        // Wire hotkey manager — ⌘P expands topmost permission to fullscreen
        hotkeyManager.onExpandPermission = { [weak self] in
            self?.onExpandPermission?()
        }

        // Wire hotkey manager — toggle focus via configurable shortcut (⌘M)
        // Focuses the terminal of the topmost card's session, or toggles dashboard.
        hotkeyManager.onToggleFocus = { [weak self] in
            guard let self else { return }
            let reversed = Array(self.pendingPermissionStore.pending.reversed())
            if let topPerm = reversed.first {
                // For Codex events without terminal PID, use the interactive bridge
                if topPerm.event.terminalPid == nil,
                   CodexInteractiveBridge.focus(event: topPerm.event) {
                    return
                }
                let sessionDir = self.sessionStore.sessions.first(where: { $0.id == topPerm.event.sessionId })?.projectDir
                IDETerminalFocus.focus(
                    terminalPid: topPerm.event.terminalPid,
                    shellPid: topPerm.event.shellPid,
                    projectDir: sessionDir ?? topPerm.event.cwd
                )
            } else if let toast = self.sessionFinishedStore.current,
                      let session = self.sessionStore.sessions.first(where: { $0.id == toast.sessionId }) {
                IDETerminalFocus.focusSession(session)
                self.sessionFinishedStore.dismiss()
            } else if let session = self.sessionStore.sessions.last(where: { $0.terminalPid != nil }) {
                IDETerminalFocus.focusSession(session)
            } else {
                self.hotkeyManager.toggleFocus()
            }
        }

        // Write resolved permission to approval history
        pendingPermissionStore.onResolved = { [weak self] event, outcome in
            guard let self else { return }
            let record = ApprovalRecord(
                id: UUID(),
                toolName: event.toolName ?? "Unknown",
                toolInputSummary: event.toolInput?["command"]?.value as? String ?? event.toolInput?["file_path"]?.value as? String,
                projectName: event.projectName,
                assistantName: event.assistantDisplayName,
                outcome: outcome,
                createdAt: event.receivedAt,
                resolvedAt: Date(),
                sessionId: event.sessionId
            )
            self.approvalHistoryStore.append(record)
        }
    }

    var behaviorPolicy: BehaviorPolicy {
        BehaviorPolicy.make(
            debugCommentInterestThresholdOverride: {
                #if DEBUG
                debugCommentInterestThresholdOverride
                #else
                nil
                #endif
            }()
        )
    }

    func updateSmartFeatureSettings(_ update: (inout SmartFeatureSettings) -> Void) {
        var next = smartFeatureSettings
        update(&next)
        smartFeatureSettings = next
    }

    #if DEBUG
    func setDebugCommentInterestThresholdOverride(_ value: Double?) {
        debugCommentInterestThresholdOverride = value
    }
    #endif

    /// Recompute which overlay card has priority and sync to the hotkey shared state.
    /// Call whenever any card's visibility changes.
    func syncActiveCard() {
        // Don't overwrite expanded permission state - only dismiss controls it
        if hotkeyManager.activeCard == .expandedPermission { return }
        if sessionSwitcherStore.isActive {
            hotkeyManager.activeCard = .sessionSwitcher
        } else if !pendingPermissionStore.pending.isEmpty {
            hotkeyManager.activeCard = .permission
        } else if sessionFinishedStore.current != nil {
            hotkeyManager.activeCard = .toast
        } else {
            hotkeyManager.activeCard = .none
        }
    }

    /// Call once from .task {} on the menu bar view
    func start() async {
        guard !isRunning else { return }
        isRunning = true
        eventBus.installAll()

        // Evict cached videos older than 30 days
        VideoCache.shared.evictStaleFiles()

        // ── Spatial awareness ──
        let topology = DesktopTopology()
        let surfaces = SurfaceGraph()
        let windowTracker = WindowTracker()
        self.desktopTopology = topology
        
        // WindowTracker -> SurfaceGraph & BehaviorEngine wiring
        windowTracker.onEvent = { [weak self] event in
            if let snapshot = self?.desktopTopology?.currentSnapshot {
                surfaces.update(with: snapshot)
            }
            // behaviorEngine gets this via its poll loop actually, 
            // but we could push immediate events here
        }

        // ── Perception ──
        let spClient = ScreenpipeClient()
        let poller = ContextPoller(
            screenpipeClient: spClient,
            fallback: FallbackPerception(topology: topology),
            settingsProvider: { [weak self] in
                self?.smartFeatureSettings ?? .default
            }
        )
        self.screenpipeClient = spClient
        self.contextPoller = poller
        poller.onHealthChanged = { [weak self] health in
            Task { @MainActor in
                self?.screenpipeHealth = health
            }
        }

        poller.onSnapshot = { [weak self] snapshot in
            Task { @MainActor in
                self?.behaviorEngine?.onContextChanged(snapshot)
            }
        }
        
        // Wire contextPoller -> Activity Feed (EventStore)
        poller.onContextChanged = { [weak self] snapshot in
            guard let self else { return }
            let textSnippet = snapshot.visibleText.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: " ")
            let displayMessage = "\(snapshot.appName) - \(snapshot.windowTitle)\n\(textSnippet)"
            
            let event = AgentEvent(
                hookEventName: HookEventType.perception.rawValue,
                message: displayMessage,
                title: "Screen context updated"
            )
            Task { @MainActor in
                self.eventStore.append(event)
            }
        }

        // ── LLM ──
        let ollama = OllamaClient()
        self.ollamaClient = ollama

        // ── Brain ──
        let state = InnerState.restore()
        let engine = BehaviorEngine(
            innerState: state,
            contextPoller: poller,
            windowTracker: windowTracker,
            ollamaClient: ollama,
            settingsProvider: { [weak self] in
                self?.smartFeatureSettings ?? .default
            },
            policyProvider: { [weak self] in
                self?.behaviorPolicy ?? BehaviorPolicy.make()
            }
        )
        self.behaviorEngine = engine
        engine.onCommentaryHealthChanged = { [weak self] health in
            Task { @MainActor in
                self?.ollamaHealth = health
                self?.behaviorEngine?.setOllamaHealth(health)
            }
        }
        
        // Wire behavior -> movement
        engine.onMovement = { [weak self] command in
            Task { @MainActor in
                self?.movementController?.execute(command)
            }
        }

        // ── Navigation ──
        let movement = MovementController(surfaces: surfaces, topology: topology)
        self.movementController = movement

        // ── Start lifecycle based on current toggles ──
        applySmartFeatureLifecycle()
        startSmartHealthTimer()
        refreshSmartServiceHealth()

        // Only request permissions if onboarding is done.
        // During onboarding, each permission is requested by its dedicated step.
        if hasCompletedOnboarding {
            await MainActor.run { hotkeyManager.start() }
            await notificationService.requestPermission()

            // Auto-upgrade IDE extension if a newer version is bundled
            if UserDefaults.standard.bool(forKey: "ideExtensionEnabled") {
                ExtensionInstaller.upgradeIfNeeded()
            }
        }

        eventBus.startAll()

        // Reconcile sessions when app comes to foreground (crash recovery).
        // Throttled to at most once per 30 seconds — this notification fires on every
        // app switch (Cmd+Tab), not just when Masko activates.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let now = Date()
            if now.timeIntervalSince(self.lastReconcileDate) >= 30 {
                self.lastReconcileDate = now
                self.sessionStore.reconcileIfNeeded()
            }
            // Retry hotkey manager if not yet active (user may have just granted Accessibility)
            if !self.hotkeyManager.isActive {
                self.hotkeyManager.start()
            }
        }

        // Clean up on app termination to avoid zombie NWListener processes
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.stop()
        }

        isReady = true
    }

    func applySmartFeatureLifecycle() {
        if smartFeatureSettings.spatialEnabled || smartFeatureSettings.behaviorEnabled {
            desktopTopology?.startPolling()
        } else {
            desktopTopology?.stopPolling()
        }

        if smartFeatureSettings.spatialEnabled {
            movementController?.start()
        } else {
            movementController?.stop()
        }

        if smartFeatureSettings.behaviorEnabled {
            contextPoller?.start()
        } else {
            contextPoller?.stop()
            screenpipeHealth = .offline
            isScreenpipeAudioCaptureDetected = false
        }

        if smartFeatureSettings.behaviorEnabled {
            behaviorEngine?.start()
        } else {
            behaviorEngine?.stop()
        }

        if !smartFeatureSettings.ollamaEnabled {
            ollamaHealth = .offline
            behaviorEngine?.setOllamaHealth(.offline)
        }

        refreshSmartServiceHealth()
    }

    private func startSmartHealthTimer() {
        smartHealthTimer?.invalidate()
        smartHealthTimer = Timer.scheduledTimer(withTimeInterval: 8.0, repeats: true) { [weak self] _ in
            self?.refreshSmartServiceHealth()
        }
    }

    func refreshSmartServiceHealth() {
        Task { [weak self] in
            guard let self else { return }

            let screenpipeResult: (health: ServiceHealth, audioDetected: Bool)
            if self.smartFeatureSettings.behaviorEnabled && self.smartFeatureSettings.screenpipeEnabled {
                let pollerHealth = self.contextPoller?.health ?? .offline
                let healthSnapshot = await self.screenpipeClient?.fetchHealth()
                let audioDetected = healthSnapshot?.isAudioCaptureDetected ?? false

                if pollerHealth == .offline {
                    let healthy = healthSnapshot?.isHealthy == true
                    screenpipeResult = (healthy ? .degraded : .offline, audioDetected)
                } else {
                    screenpipeResult = (audioDetected ? .degraded : pollerHealth, audioDetected)
                }
            } else {
                screenpipeResult = (.offline, false)
            }

            let nextOllamaHealth: ServiceHealth
            if self.smartFeatureSettings.behaviorEnabled && self.smartFeatureSettings.ollamaEnabled {
                let healthy = await self.ollamaClient?.checkHealth() ?? false
                nextOllamaHealth = healthy ? .connected : .offline
            } else {
                nextOllamaHealth = .offline
            }

            await MainActor.run {
                self.screenpipeHealth = screenpipeResult.health
                self.isScreenpipeAudioCaptureDetected = screenpipeResult.audioDetected
                self.ollamaHealth = nextOllamaHealth
                self.behaviorEngine?.setOllamaHealth(nextOllamaHealth)
            }
        }
    }

    func triggerCommentaryProbe() {
        behaviorEngine?.triggerCommentaryProbe()
    }

    /// Tear down adapters and timers to prevent zombie processes
    func stop() {
        smartHealthTimer?.invalidate()
        smartHealthTimer = nil
        contextPoller?.stop()
        behaviorEngine?.stop()
        movementController?.stop()
        desktopTopology?.stopPolling()
        eventBus.stopAll()
        sessionStore.stopTimers()
        pendingPermissionStore.stopTimers()
        hotkeyManager.stop()
    }
}
