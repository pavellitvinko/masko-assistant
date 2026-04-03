import XCTest
@testable import masko_code

final class ContextPollerTests: XCTestCase {
    @MainActor
    func testPrefersFocusedScreenpipeContext() async {
        let focused = ScreenpipeClient.ScreenpipeContext(
            app_name: "Cursor",
            window_name: "Focused.swift",
            text: "focused content",
            timestamp: "2026-01-01T00:00:00Z",
            focused: true
        )
        let other = ScreenpipeClient.ScreenpipeContext(
            app_name: "Slack",
            window_name: "General",
            text: "noise",
            timestamp: "2026-01-01T00:00:00Z",
            focused: false
        )
        let client = MockScreenpipeClient(contextsByCall: [[other, focused]], healthy: true)
        let poller = makePoller(client: client)

        let exp = expectation(description: "context changed")
        poller.onContextChanged = { _ in exp.fulfill() }
        poller.start()
        await fulfillment(of: [exp], timeout: 1.0)
        poller.stop()

        XCTAssertEqual(poller.current?.appName, "Cursor")
        XCTAssertEqual(poller.current?.windowTitle, "Focused.swift")
        XCTAssertEqual(poller.health, .offline)
    }

    @MainActor
    func testPrefersActiveWindowHintOverFocusedOtherApp() async {
        let focusedOtherApp = ScreenpipeClient.ScreenpipeContext(
            app_name: "Slack",
            window_name: "General",
            text: "focused noise",
            timestamp: "2026-01-01T00:00:05Z",
            focused: true
        )
        let activeWindowMatch = ScreenpipeClient.ScreenpipeContext(
            app_name: "Antigravity",
            window_name: "masko-assistant — README.md",
            text: "current editor text",
            timestamp: "2026-01-01T00:00:04Z",
            focused: false
        )
        let client = MockScreenpipeClient(contextsByCall: [[focusedOtherApp, activeWindowMatch]], healthy: true)
        let fallback = MockFallbackPerception(
            appName: "Antigravity",
            windowTitle: "masko-assistant — README.md"
        )
        let poller = makePoller(client: client, fallback: fallback)

        let exp = expectation(description: "context changed")
        poller.onContextChanged = { _ in exp.fulfill() }
        poller.start()
        await fulfillment(of: [exp], timeout: 1.0)
        poller.stop()

        XCTAssertEqual(poller.current?.appName, "Antigravity")
        XCTAssertEqual(poller.current?.windowTitle, "masko-assistant — README.md")
    }

    @MainActor
    func testPrefersNewestFocusedRecordWhenMultipleAreFocused() async {
        let olderFocused = ScreenpipeClient.ScreenpipeContext(
            app_name: "Cursor",
            window_name: "Old.swift",
            text: "old content",
            timestamp: "2026-01-01T00:00:00Z",
            focused: true
        )
        let newerFocused = ScreenpipeClient.ScreenpipeContext(
            app_name: "Cursor",
            window_name: "New.swift",
            text: "new content",
            timestamp: "2026-01-01T00:00:05Z",
            focused: true
        )
        let client = MockScreenpipeClient(contextsByCall: [[olderFocused, newerFocused]], healthy: true)
        let poller = makePoller(client: client)

        let exp = expectation(description: "context changed")
        poller.onContextChanged = { _ in exp.fulfill() }
        poller.start()
        await fulfillment(of: [exp], timeout: 1.0)
        poller.stop()

        XCTAssertEqual(poller.current?.windowTitle, "New.swift")
    }

    @MainActor
    func testFallsBackToAppScopedQueryWhenWindowScopedQueryHasNoRows() async {
        let appScoped = ScreenpipeClient.ScreenpipeContext(
            app_name: "Antigravity",
            window_name: "masko-assistant — README.md",
            text: String(repeating: "A", count: 260),
            timestamp: "2026-01-01T00:00:05Z",
            focused: false
        )
        let client = MockScreenpipeClient(contextsByCall: [[], [appScoped]], healthy: true)
        let fallback = MockFallbackPerception(
            appName: "Antigravity",
            windowTitle: "masko-assistant — README.md"
        )
        let poller = makePoller(client: client, fallback: fallback)

        let exp = expectation(description: "context changed")
        poller.onContextChanged = { _ in exp.fulfill() }
        poller.start()
        await fulfillment(of: [exp], timeout: 1.0)
        poller.stop()

        XCTAssertEqual(client.recordedRequests.count, 2)
        XCTAssertEqual(client.recordedRequests[0].appName, "Antigravity")
        XCTAssertEqual(client.recordedRequests[0].windowName, "masko-assistant — README.md")
        XCTAssertNil(client.recordedRequests[0].minLength)
        XCTAssertEqual(client.recordedRequests[1].appName, "Antigravity")
        XCTAssertNil(client.recordedRequests[1].windowName)
        XCTAssertNil(client.recordedRequests[1].minLength)
        XCTAssertEqual(poller.current?.appName, "Antigravity")
    }

    @MainActor
    func testFallsBackToGlobalQueryAfterScopedQueriesMiss() async {
        let globalMatch = ScreenpipeClient.ScreenpipeContext(
            app_name: "Codex",
            window_name: "Codex",
            text: String(repeating: "B", count: 450),
            timestamp: "2026-01-01T00:00:09Z",
            focused: false
        )
        let client = MockScreenpipeClient(contextsByCall: [[], [], [globalMatch]], healthy: true)
        let fallback = MockFallbackPerception(
            appName: "Antigravity",
            windowTitle: "masko-assistant — README.md"
        )
        let poller = makePoller(client: client, fallback: fallback)

        let exp = expectation(description: "context changed")
        poller.onContextChanged = { _ in exp.fulfill() }
        poller.start()
        await fulfillment(of: [exp], timeout: 1.0)
        poller.stop()

        XCTAssertEqual(client.recordedRequests.count, 3)
        XCTAssertNil(client.recordedRequests[2].appName)
        XCTAssertNil(client.recordedRequests[2].windowName)
        XCTAssertEqual(client.recordedRequests[2].limit, 20)
        XCTAssertNil(client.recordedRequests[2].minLength)
        XCTAssertEqual(poller.current?.appName, "Codex")
    }

    @MainActor
    func testFallsBackToNewestRecordWhenFocusedFlagMissing() async {
        let older = ScreenpipeClient.ScreenpipeContext(
            app_name: "Cursor",
            window_name: "Old",
            text: "old",
            timestamp: "2026-01-01T00:00:00Z",
            focused: nil
        )
        let newer = ScreenpipeClient.ScreenpipeContext(
            app_name: "Terminal",
            window_name: "New",
            text: "new",
            timestamp: "2026-01-01T00:00:09Z",
            focused: nil
        )
        let client = MockScreenpipeClient(contextsByCall: [[older, newer]], healthy: true)
        let poller = makePoller(client: client)

        let exp = expectation(description: "context changed")
        poller.onContextChanged = { _ in exp.fulfill() }
        poller.start()
        await fulfillment(of: [exp], timeout: 1.0)
        poller.stop()

        XCTAssertEqual(poller.current?.appName, "Terminal")
        XCTAssertEqual(poller.current?.windowTitle, "New")
    }

    @MainActor
    func testPrefersNewestRecordWhenNoActiveOrFocusedContextExists() async {
        let lowSignal = ScreenpipeClient.ScreenpipeContext(
            app_name: "Control Centre",
            window_name: "Clock",
            text: "Thu 2 Apr 16:28",
            timestamp: "2026-01-01T00:00:09Z",
            focused: nil
        )
        let meaningful = ScreenpipeClient.ScreenpipeContext(
            app_name: "Codex",
            window_name: "Codex",
            text: "Implement parser and update tests for comment dedupe pipeline.",
            timestamp: "2026-01-01T00:00:08Z",
            focused: nil
        )
        let client = MockScreenpipeClient(contextsByCall: [[lowSignal, meaningful]], healthy: true)
        let poller = makePoller(client: client)

        let exp = expectation(description: "context changed")
        poller.onContextChanged = { _ in exp.fulfill() }
        poller.start()
        await fulfillment(of: [exp], timeout: 1.0)
        poller.stop()

        XCTAssertEqual(poller.current?.appName, "Control Centre")
        XCTAssertEqual(poller.current?.windowTitle, "Clock")
    }

    @MainActor
    func testPrefersFocusedContextWithoutJudgingCommentWorthiness() async {
        let focusedButLowSignal = ScreenpipeClient.ScreenpipeContext(
            app_name: "Control Centre",
            window_name: "Clock",
            text: "16:28",
            timestamp: "2026-01-01T00:00:09Z",
            focused: true
        )
        let unfocusedMeaningful = ScreenpipeClient.ScreenpipeContext(
            app_name: "Sublime Text",
            window_name: "Clippy.json",
            text: "{\"name\":\"Clippy\",\"edges\":[{\"id\":\"a1\"}]}",
            timestamp: "2026-01-01T00:00:08Z",
            focused: false
        )
        let client = MockScreenpipeClient(contextsByCall: [[focusedButLowSignal, unfocusedMeaningful]], healthy: true)
        let poller = makePoller(client: client)

        let exp = expectation(description: "context changed")
        poller.onContextChanged = { _ in exp.fulfill() }
        poller.start()
        await fulfillment(of: [exp], timeout: 1.0)
        poller.stop()

        XCTAssertEqual(poller.current?.appName, "Control Centre")
        XCTAssertEqual(poller.current?.windowTitle, "Clock")
    }

    @MainActor
    func testFallsBackAndMarksDegradedWhenHealthyButNoData() async {
        let client = MockScreenpipeClient(contextsByCall: [[]], healthy: true)
        let poller = makePoller(client: client)
        let healthExp = expectation(description: "health changed")
        poller.onHealthChanged = { status in
            if status == .degraded {
                healthExp.fulfill()
            }
        }

        poller.start()
        await fulfillment(of: [healthExp], timeout: 1.0)
        poller.stop()
    }

    @MainActor
    func testScreenpipeDisabledUsesFallbackWithoutOCRRequests() async {
        let client = MockScreenpipeClient(contextsByCall: [[]], healthy: true)
        let fallback = MockFallbackPerception(appName: "Finder", windowTitle: "Documents")
        let settings = SmartFeatureSettings(
            spatialEnabled: false,
            behaviorEnabled: true,
            screenpipeEnabled: false,
            ollamaEnabled: true
        )
        let poller = makePoller(client: client, fallback: fallback, settings: settings)

        let exp = expectation(description: "context changed")
        poller.onContextChanged = { _ in exp.fulfill() }
        poller.start()
        await fulfillment(of: [exp], timeout: 1.0)
        poller.stop()

        XCTAssertEqual(client.recordedRequests.count, 0)
        XCTAssertEqual(poller.current?.appName, "Finder")
        XCTAssertEqual(poller.current?.windowTitle, "Documents")
    }

    @MainActor
    func testOnSnapshotFiresEvenWhenContextIsUnchanged() async {
        let snapshot = ScreenpipeClient.ScreenpipeContext(
            app_name: "masko-code",
            window_name: "Activity Feed",
            text: "same text",
            timestamp: "2026-01-01T00:00:00Z",
            focused: true
        )
        let client = MockScreenpipeClient(contextsByCall: [[snapshot], [snapshot]], healthy: true)
        let poller = makePoller(client: client)

        let first = expectation(description: "first snapshot")
        let second = expectation(description: "second snapshot")
        var snapshotCount = 0
        var changedCount = 0

        poller.onSnapshot = { _ in
            snapshotCount += 1
            if snapshotCount == 1 {
                first.fulfill()
            } else if snapshotCount == 2 {
                second.fulfill()
            }
        }
        poller.onContextChanged = { _ in
            changedCount += 1
        }

        poller.start()
        await fulfillment(of: [first], timeout: 1.0)
        poller.stop()

        poller.start()
        await fulfillment(of: [second], timeout: 1.0)
        poller.stop()

        XCTAssertEqual(snapshotCount, 2)
        XCTAssertEqual(changedCount, 1)
    }

    private func makePoller(
        client: MockScreenpipeClient,
        fallback: FallbackPerception = FallbackPerception(topology: DesktopTopology()),
        settings: SmartFeatureSettings = .default
    ) -> ContextPoller {
        ContextPoller(
            screenpipeClient: client,
            fallback: fallback,
            settingsProvider: { settings }
        )
    }
}

private final class MockScreenpipeClient: ScreenpipeClient {
    private var contextsByCall: [[ScreenpipeClient.ScreenpipeContext]]
    private let healthy: Bool
    private(set) var recordedRequests: [ScreenpipeClient.SearchRequest] = []

    init(contextsByCall: [[ScreenpipeClient.ScreenpipeContext]], healthy: Bool) {
        self.contextsByCall = contextsByCall
        self.healthy = healthy
        super.init(baseURL: "http://localhost:3030")
    }

    override func checkHealth() async -> Bool {
        healthy
    }

    override func getRecentContext(request: ScreenpipeClient.SearchRequest) async throws -> [ScreenpipeClient.ScreenpipeContext] {
        recordedRequests.append(request)
        if contextsByCall.isEmpty {
            return []
        }
        return contextsByCall.removeFirst()
    }
}

private final class MockFallbackPerception: FallbackPerception {
    private let appName: String
    private let windowTitle: String

    init(appName: String, windowTitle: String) {
        self.appName = appName
        self.windowTitle = windowTitle
        super.init(topology: DesktopTopology())
    }

    override func snapshot() -> ContextSnapshot {
        ContextSnapshot(
            appName: appName,
            windowTitle: windowTitle,
            visibleText: "",
            timestamp: Date(),
            source: .windowList
        )
    }
}
