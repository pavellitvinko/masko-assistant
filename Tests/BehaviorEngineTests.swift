import XCTest
@testable import masko_code

final class BehaviorEngineTests: XCTestCase {
    override func tearDown() {
        #if DEBUG
        BehaviorDebugSettings.persist(nil)
        #endif
        super.tearDown()
    }

    func testCommentDecisionSpeaksForHighSignalContext() {
        let engine = makeEngine()
        engine.setOllamaHealth(.connected)

        switch engine.decideCommentAction(context: highSignalContext()) {
        case .speak:
            XCTAssertTrue(true)
        case .silent:
            XCTFail("Expected high-signal context to be commentable")
        }
    }

    func testCommentDecisionSilentForLowSignalContext() {
        let engine = makeEngine()
        engine.setOllamaHealth(.connected)

        switch engine.decideCommentAction(context: lowSignalContext()) {
        case .silent:
            XCTAssertTrue(true)
        case .speak:
            XCTFail("Expected low-signal context to remain silent")
        }
    }

    func testBubbleDismissalSuppressesCommenting() {
        let engine = makeEngine()
        engine.setOllamaHealth(.connected)

        engine.onBubbleDismissed()
        engine.onBubbleDismissed()
        engine.onBubbleDismissed()

        switch engine.decideCommentAction(context: highSignalContext()) {
        case .silent:
            XCTAssertTrue(true)
        case .speak:
            XCTFail("Expected speech suppression after repeated dismissals")
        }
    }

    func testBehaviorDisabledKeepsCommentarySilent() {
        let engine = makeEngine(settings: SmartFeatureSettings(
            spatialEnabled: false,
            behaviorEnabled: false,
            screenpipeEnabled: true,
            ollamaEnabled: true
        ))
        engine.setOllamaHealth(.connected)

        switch engine.decideCommentAction(context: highSignalContext()) {
        case .silent:
            XCTAssertTrue(true)
        case .speak:
            XCTFail("Expected behavior master toggle to disable commentary")
        }
    }

    func testScreenpipeDisabledKeepsCommentarySilent() {
        let engine = makeEngine(settings: SmartFeatureSettings(
            spatialEnabled: false,
            behaviorEnabled: true,
            screenpipeEnabled: false,
            ollamaEnabled: true
        ))
        engine.setOllamaHealth(.connected)

        switch engine.decideCommentAction(context: highSignalContext()) {
        case .silent:
            XCTAssertTrue(true)
        case .speak:
            XCTFail("Expected commentary to stay silent when screen perception is disabled")
        }
    }

    func testOllamaDisabledKeepsCommentarySilent() {
        let engine = makeEngine(settings: SmartFeatureSettings(
            spatialEnabled: false,
            behaviorEnabled: true,
            screenpipeEnabled: true,
            ollamaEnabled: false
        ))
        engine.setOllamaHealth(.connected)

        switch engine.decideCommentAction(context: highSignalContext()) {
        case .silent:
            XCTAssertTrue(true)
        case .speak:
            XCTFail("Expected commentary to stay silent when AI commentary is disabled")
        }
    }

    func testLegacyGateSettingsNoLongerAffectBehavior() {
        UserDefaults.standard.set(false, forKey: "comment_require_interest_threshold")
        defer { UserDefaults.standard.removeObject(forKey: "comment_require_interest_threshold") }

        let engine = makeEngine()
        engine.setOllamaHealth(.connected)

        switch engine.decideCommentAction(context: lowSignalContext()) {
        case .silent:
            XCTAssertTrue(true)
        case .speak:
            XCTFail("Legacy threshold gate toggle should no longer affect behavior")
        }
    }

    #if DEBUG
    func testDebugThresholdOverrideCanEnableLowSignalContext() {
        BehaviorDebugSettings.persist(0.0)
        let engine = makeEngine(debugThresholdOverride: BehaviorDebugSettings.load())
        engine.setOllamaHealth(.connected)

        switch engine.decideCommentAction(context: lowSignalContext()) {
        case .speak:
            XCTAssertTrue(true)
        case .silent:
            XCTFail("Expected debug threshold override to allow low-signal context")
        }
    }
    #endif

    private func makeEngine(
        settings: SmartFeatureSettings = .default,
        debugThresholdOverride: Double? = nil
    ) -> BehaviorEngine {
        let poller = ContextPoller(
            screenpipeClient: ScreenpipeClient(baseURL: "http://localhost:3030"),
            fallback: FallbackPerception(topology: DesktopTopology()),
            settingsProvider: { settings }
        )
        return BehaviorEngine(
            innerState: .initial(),
            contextPoller: poller,
            windowTracker: WindowTracker(),
            ollamaClient: OllamaClient(baseURL: "http://localhost:11434"),
            settingsProvider: { settings },
            policyProvider: { BehaviorPolicy.make(debugCommentInterestThresholdOverride: debugThresholdOverride) }
        )
    }

    private func highSignalContext() -> ContextSnapshot {
        ContextSnapshot(
            appName: "Cursor",
            windowTitle: "bugfix.swift",
            visibleText: "error fail pull request merge todo",
            timestamp: Date(),
            source: .screenpipe
        )
    }

    private func lowSignalContext() -> ContextSnapshot {
        ContextSnapshot(
            appName: "Finder",
            windowTitle: "Documents",
            visibleText: "just browsing files",
            timestamp: Date(),
            source: .screenpipe
        )
    }
}
