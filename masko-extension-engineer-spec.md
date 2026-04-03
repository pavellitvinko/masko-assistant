# Masko Code — Spatial Awareness & Autonomous Behavior Extension

> Spec for engineer. Fork masko-code, keep everything, add five modules.
> The mascot walks on windows, has moods, sees your screen, and comments.

---

## 1. Overview

We extend Masko Code with:

1. **Spatial awareness** — the mascot knows where every window, the dock, and menu bar are. It physically walks on window title bars and falls when windows close.
2. **Autonomous behavior** — the mascot has an inner emotional state (energy, curiosity, comfort) that shifts over time and in response to screen context. It picks behaviors from a weighted pool every 4-8 seconds.
3. **Screen perception** — via screenpipe (localhost:3030), the mascot sees the actual text on screen: code, errors, URLs, Slack messages.
4. **LLM commentary** — via Ollama (localhost:11434), the mascot occasionally generates a witty one-liner about what it sees.
5. **A new mascot skin** — "Clawd" (or any name), created via Masko's existing `MaskoAnimationConfig` system, whose state machine responds to the new inputs.

Nothing is removed. All existing Masko features, adapters, extensions, mascots, and tests remain intact.

---

## 2. New files

```
Sources/
├── Spatial/
│   ├── DesktopTopology.swift         # CGWindowListCopyWindowInfo + NSScreen polling
│   ├── SurfaceGraph.swift            # walkable surfaces from window/dock/menubar edges
│   ├── DockDetector.swift            # dock position, size, orientation
│   └── WindowTracker.swift           # detects app switches, window moves, appears/disappears
│
├── Navigation/
│   ├── MovementController.swift      # character screen position, walk/jump/fall execution
│   └── PathPlanner.swift             # route between surfaces
│
├── Brain/
│   ├── InnerState.swift              # energy/curiosity/comfort → mood derivation
│   ├── BehaviorEngine.swift          # weighted random behavior selection, event reactions
│   ├── BehaviorWeights.swift         # mood → behavior weight tables
│   ├── ContextNudger.swift           # screen context → inner state shifts
│   ├── InterestScorer.swift          # score 0-10 how "commentable" current context is
│   ├── ErrorDetector.swift           # pattern matching for errors/successes in screen text
│   ├── MutterLibrary.swift           # canned phrases keyed to app/pattern/time
│   └── BehaviorScheduler.swift       # randomized 4-8s tick driving the behavior loop
│
├── Perception/
│   ├── ScreenpipeClient.swift        # HTTP client for localhost:3030
│   ├── ContextPoller.swift           # polls screenpipe every 10s, diffs results
│   ├── ContextSnapshot.swift         # unified context data model
│   └── FallbackPerception.swift      # CGWindowList-only context when screenpipe absent
│
├── LLM/
│   ├── OllamaClient.swift            # POST localhost:11434/api/generate, 3s timeout
│   ├── Personality.swift             # system prompt template
│   └── CommentCache.swift            # dedup: don't repeat comments in a session
│
└── Views/Overlay/
    └── SpeechBubblePanel.swift       # child panel above mascot for emotes/mutters/comments

Resources/Defaults/
└── clawd.json                        # new mascot config using MaskoAnimationConfig format
```

**22 new Swift files + 1 JSON config. 0 files deleted.**

---

## 3. Modified files (4 total)

### 3.1 AppStore.swift

Add stored properties:

```swift
// Spatial & behavior
private(set) var desktopTopology: DesktopTopology?
private(set) var movementController: MovementController?
private(set) var behaviorEngine: BehaviorEngine?
private(set) var contextPoller: ContextPoller?
private(set) var screenpipeClient: ScreenpipeClient?
private(set) var ollamaClient: OllamaClient?
```

Add to `start()`, after existing initialization completes:

```swift
// ── Spatial awareness ──
let topology = DesktopTopology()
let surfaces = SurfaceGraph(topology: topology)
let windowTracker = WindowTracker(topology: topology)
self.desktopTopology = topology

// ── Perception ──
let spClient = ScreenpipeClient()
Task { await spClient.checkHealth() }
let poller = ContextPoller(
    screenpipeClient: spClient,
    fallback: FallbackPerception(topology: topology)
)
self.screenpipeClient = spClient
self.contextPoller = poller

// ── LLM ──
let ollama = OllamaClient()
Task { await ollama.checkHealth() }
self.ollamaClient = ollama

// ── Brain ──
let state = InnerState.restore()
let engine = BehaviorEngine(
    innerState: state,
    contextPoller: poller,
    windowTracker: windowTracker,
    ollamaClient: ollama
)
self.behaviorEngine = engine

// ── Navigation ──
let movement = MovementController(surfaces: surfaces, topology: topology)
self.movementController = movement

// ── Start if enabled ──
if UserDefaults.standard.bool(forKey: "spatial_enabled") {
    topology.startPolling()
}
if UserDefaults.standard.bool(forKey: "screenpipe_enabled") {
    poller.start()
}
if UserDefaults.standard.bool(forKey: "behavior_enabled") {
    engine.start()
}
```

Add to the existing `eventBus.onEvent` closure, after `self.onEventForOverlay?(event)`:

```swift
// Feed agent events to behavior engine for reactions
if UserDefaults.standard.bool(forKey: "behavior_enabled") {
    self.behaviorEngine?.onAgentEvent(event)
}
```

### 3.2 OverlayManager.swift

Add method for spatial positioning:

```swift
private var movementController: MovementController?

func bindToMovement(_ controller: MovementController) {
    self.movementController = controller
    controller.onPositionChanged = { [weak self] position in
        guard let self,
              let panel = self.panel,
              UserDefaults.standard.bool(forKey: "spatial_enabled") else { return }
        
        let size = panel.frame.size
        let origin = CGPoint(
            x: position.x - size.width / 2,
            y: position.y - size.height / 2
        )
        let screen = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let clamped = Self.clampedMascotRect(origin: origin, side: size.width, screenFrame: screen)
        panel.setFrame(clamped, display: false, animate: false)
        self.scheduleHUDReposition()
    }
}
```

Add speech bubble panel management (follows same pattern as `statsPanel` and `permissionPanel`):

```swift
private var speechPanel: OverlayPanel?

func showSpeech(_ event: SpeechEvent) {
    // Create or reuse speechPanel as a child above the mascot
    // Position using the same logic as repositionStats()
    // Auto-dismiss after 2-4 seconds based on tier
}

func dismissSpeech() {
    speechPanel?.orderOut(nil)
    behaviorEngine?.onBubbleDismissed()
}
```

### 3.3 MaskoDesktopApp.swift

Add wiring in the `.task` modifier, after existing setup:

```swift
// Wire behavior engine → state machine inputs
appStore.behaviorEngine?.onStateChanged = { [weak overlayManager] output in
    guard let sm = overlayManager?.currentStateMachine else { return }
    sm.setInput("mascot_mood", .number(Double(output.mood.rawValue)))
    sm.setInput("mascot_behavior", .number(Double(output.state.rawValue)))
    sm.setInput("mascot_speaking", .bool(output.isSpeaking))
}

// Wire behavior engine → speech display
appStore.behaviorEngine?.onSpeech = { [weak overlayManager] event in
    overlayManager?.showSpeech(event)
}

// Wire behavior engine → movement commands
appStore.behaviorEngine?.onMovement = { [weak appStore] command in
    appStore?.movementController?.execute(command)
}

// Wire movement → overlay position
if let mc = appStore.movementController {
    overlayManager.bindToMovement(mc)
}
```

### 3.4 SettingsView.swift

Add a new section to the settings form:

```swift
Section {
    Toggle("Spatial awareness", isOn: $spatialEnabled)
    Text("Mascot walks on window edges and follows your active app")
        .font(Constants.body(size: 12))
        .foregroundStyle(Constants.textMuted)
    
    Toggle("Autonomous behavior", isOn: $behaviorEnabled)
    Text("Mascot has moods, idle behaviors, and reacts to events")
        .font(Constants.body(size: 12))
        .foregroundStyle(Constants.textMuted)
    
    Toggle("Screen perception", isOn: $screenpipeEnabled)
    if screenpipeEnabled {
        HStack {
            Text("Screenpipe")
                .font(Constants.body(size: 13))
            Spacer()
            Text(screenpipeStatus)
                .font(Constants.body(size: 12))
                .foregroundStyle(screenpipeConnected ? .green : Constants.textMuted)
        }
    }
    Text("Reads screen text via screenpipe for context-aware reactions")
        .font(Constants.body(size: 12))
        .foregroundStyle(Constants.textMuted)
    
    Toggle("AI commentary", isOn: $ollamaEnabled)
    if ollamaEnabled {
        TextField("Model", text: $ollamaModel)
            .font(Constants.body(size: 13))
        HStack {
            Text("Ollama")
                .font(Constants.body(size: 13))
            Spacer()
            Text(ollamaStatus)
                .font(Constants.body(size: 12))
                .foregroundStyle(ollamaConnected ? .green : Constants.textMuted)
        }
    }
    Text("Generates witty one-liners about what's on screen")
        .font(Constants.body(size: 12))
        .foregroundStyle(Constants.textMuted)
    
} header: {
    Text("Smart Mascot")
        .font(Constants.heading(size: 14))
}
```

---

## 4. Feature flags (UserDefaults keys)

```swift
// In Constants.swift, add:
static let spatialEnabledKey = "spatial_enabled"
static let behaviorEnabledKey = "behavior_enabled"
static let screenpipeEnabledKey = "screenpipe_enabled"
static let ollamaEnabledKey = "ollama_enabled"
static let speechEnabledKey = "speech_enabled"
static let commentFrequencyKey = "comment_frequency"  // Double, 0.0-2.0
static let ollamaModelKey = "ollama_model"             // String, default "gemma3:4b"

static let topologyPollInterval: TimeInterval = 1.0
static let contextPollInterval: TimeInterval = 10.0
static let behaviorTickRange: ClosedRange<TimeInterval> = 4.0...8.0
static let screenpipeBaseURL = "http://localhost:3030"
static let ollamaBaseURL = "http://localhost:11434"
static let defaultOllamaModel = "gemma3:4b"
```

All flags default to `false`. When all are off, stock Masko behavior.

---

## 5. The Clawd mascot config

A new `MaskoAnimationConfig` JSON file at `Resources/Defaults/clawd.json`. Uses the exact same format as `clippy.json`, `masko.json`, etc. Registered in `MascotStore.presets`:

```swift
// Add to MascotStore.presets array:
PresetInfo(slug: "clawd", filename: "clawd"),
```

The config declares three custom inputs that our behavior engine sets:

```json
{
  "version": "2.0",
  "name": "Clawd",
  "initialNode": "idle",
  "autoPlay": true,
  "inputs": [
    {"name": "mascot_mood", "type": "number", "default": 2},
    {"name": "mascot_behavior", "type": "number", "default": 0},
    {"name": "mascot_speaking", "type": "boolean", "default": false}
  ],
  "nodes": [...],
  "edges": [...]
}
```

The state machine evaluates these inputs via conditions on edges, exactly like how existing mascots evaluate `agent::isWorking` and `agent::isIdle`. No state machine code changes. Old mascots that don't declare `mascot_*` inputs simply ignore them.

**Producing animation assets:** The Clawd character videos (HEVC with alpha) can be created via Rive→export, After Effects, masko.ai's AI tools, or sprite art→ffmpeg. Each node needs a looping video (idle, working, thinking, attention, sleepy, celebrate, startle). Each transition edge needs a short one-shot clip. Minimum: 6 loop clips + 10 transition clips.

---

## 6. Module specifications

### 6.1 Spatial/ — Desktop topology

Polls `CGWindowListCopyWindowInfo` every 1 second. Builds:

```swift
struct DesktopSnapshot {
    let windows: [WindowInfo]
    let activeWindow: WindowInfo?
    let dockRect: CGRect
    let dockPosition: DockPosition  // .bottom, .left, .right
    let menuBarHeight: CGFloat
    let screenFrame: CGRect
    let visibleFrame: CGRect
}

struct WindowInfo {
    let id: CGWindowID
    let title: String
    let appName: String
    let bounds: CGRect
    let isOnScreen: Bool
}
```

`SurfaceGraph` extracts walkable surfaces: top edge of each window, dock top edge, menu bar bottom edge, screen bottom. Returns `[Surface]` sorted by y-coordinate.

`WindowTracker` diffs consecutive snapshots to detect `appSwitch`, `windowMoved` (delta > 20px), `windowAppeared`, `windowDisappeared`. Fires callbacks that the behavior engine listens to.

`DockDetector` compares `NSScreen.main.frame` with `NSScreen.main.visibleFrame` to compute dock rect and position. Treats delta < 10px as "dock hidden."

Requires **Screen Recording** permission on macOS 14+ for window titles. Without it, titles are empty but bounds still work. Add to onboarding prompt.

### 6.2 Navigation/ — Movement

`MovementController` maintains the character's screen position and executes movement commands from the behavior engine.

```swift
class MovementController {
    var currentPosition: CGPoint
    var currentSurface: Surface?
    var isOnSurface: Bool
    var direction: CGFloat  // -1 left, 0 still, 1 right
    
    var onPositionChanged: ((CGPoint) -> Void)?
    
    func execute(_ command: MovementCommand)
    func update(dt: TimeInterval)  // called at 60fps
}
```

Movement types:
- **Walk**: linear interpolation along surface at ~40px/sec. Updates `direction`.
- **Jump**: parametric arc between surfaces. Sets `isOnSurface = false` during arc, `true` on landing.
- **Fall**: simulated gravity (v += 400*dt). Triggered when surface disappears.
- **Follow active window**: PathPlanner computes route to active window's top edge.

Position updates at 60fps via `Timer` or `CADisplayLink`. Calls `onPositionChanged` which OverlayManager uses to move the panel.

### 6.3 Brain/ — Behavior engine

**InnerState**: three floats (0.0-1.0) — `energy`, `curiosity`, `comfort`. Derived `Mood` enum (sleepy, nervous, neutral, content, playful, excited). Persisted to UserDefaults on app termination, restored on launch.

Natural drift per behavior tick: `energy -= 0.008`. After 10 PM: `energy -= 0.015`.

**ContextNudger**: called on each `ContextPoller` update. Adjusts inner state:
- Error detected → comfort -= 0.15, curiosity += 0.2
- Meeting app active → energy -= 0.05
- Creative app active → comfort += 0.05
- YouTube/Reddit → energy += 0.1, curiosity += 0.1
- Same app 10+ min → comfort += 0.03, curiosity -= 0.02

**BehaviorScheduler**: fires every 4-8 seconds (randomized). Calls `BehaviorEngine.selectBehavior()`.

**BehaviorEngine**: weighted random selection from behavior pool. Weights change with mood. See `haiku-behavior-engine.md` for complete weight tables.

Behaviors are grouped:
- **Locomotion** (walk, jump, climb, fall) — ~30-40% weight
- **Idle** (stand, sit, look around, fidget, yawn, nod off) — ~30-40% weight
- **Play** (peek, hang, balance, inspect, tap on window) — ~10-20% weight
- **Verbal** (emote, mutter, comment) — ~5-10% weight

When verbal is selected:
- Emote: random emoji from pool, shown via SpeechBubblePanel. No LLM.
- Mutter: lookup from MutterLibrary keyed to current app/pattern/time. No LLM.
- Comment: call OllamaClient with context from ContextPoller. 3s timeout. On timeout/unavailable, fall back to mutter.

**Agent event reactions** — `onAgentEvent()` forces immediate behaviors:
- `sessionStart` → energy += 0.15, force `wave` behavior
- `taskCompleted` / `stop` → force `celebrate`
- `toolFailed` → force `startle`, comfort -= 0.1
- `preCompact` → energy -= 0.05 (compacting is tiring)
- `permissionRequest` → force `wave` (existing permission UI handles the prompt)

**Safety valve** — `onBubbleDismissed()`:
- First dismiss: halve verbal weights for 10 minutes
- Third dismiss in session: verbal weight → 0 for 30 minutes
- Resets on app restart

### 6.4 Perception/ — Screen awareness

`ScreenpipeClient`: single endpoint.

```
GET http://localhost:3030/search?limit=3&offset=0&content_type=ocr
```

Returns app_name, window_name, text, timestamp, focused. Health check via `GET /health`.

`ContextPoller`: polls every 10 seconds. Builds `ContextSnapshot`:

```swift
struct ContextSnapshot {
    let appName: String
    let windowTitle: String
    let visibleText: String  // truncated to 500 chars
    let timestamp: Date
    let source: PerceptionSource // .screenpipe, .windowList, .none
}
```

Maintains rolling history of last 12 snapshots (~2 minutes). Fires `onContextChanged` callback when content changes meaningfully (different app, different title, or first 100 chars of visibleText differ).

`FallbackPerception`: when screenpipe is unavailable, builds snapshot from `DesktopTopology.current.activeWindow` — has appName and title, but visibleText is empty.

### 6.5 LLM/ — Commentary

`OllamaClient`: `POST http://localhost:11434/api/generate`. Stream disabled. 3-second hard timeout. Model from UserDefaults (default `gemma3:4b`).

`Personality`: system prompt template. The mascot is instructed to respond under 15 words, be specific to screen context, and respond with JSON (`{"action":"silent"}` or `{"action":"speak","text":"...","emotion":"..."}`).

`CommentCache`: stores last 20 comments. Rejects duplicates before showing.

### 6.6 Views/Overlay/SpeechBubblePanel.swift

A child `OverlayPanel` positioned above the mascot panel. Three visual tiers:

| Tier | Style | Duration | Dismiss |
|------|-------|----------|---------|
| Emote | 16px emoji, no border | 2s fade | No |
| Mutter | 11px italic, cream background | 3s fade | No |
| Comment | 12px, bordered, warm shadow | 4s fade | Click to dismiss |

Follows the same positioning and lifecycle pattern as `statsPanel` in OverlayManager. Anchored above mascot, clamped to screen edges, repositioned when mascot moves.

---

## 7. Data flow summary

### Every 1 second (topology)
```
CGWindowListCopyWindowInfo → DesktopTopology.current
  → SurfaceGraph recomputes walkable surfaces
  → WindowTracker detects changes → fires WindowEvent callbacks
  → BehaviorEngine receives window events (startle, follow)
  → MovementController gets updated surfaces
```

### Every 4-8 seconds (behavior tick)
```
BehaviorScheduler fires
  → InnerState.mood evaluated
  → BehaviorWeights selected for mood
  → Weighted random → Behavior
  → Physical: MovementController.execute(command) → panel position updates
  → State machine: overlayStateMachine.setInput("mascot_*", ...)
  → Verbal: SpeechBubblePanel.show(emote/mutter) OR OllamaClient.generate → comment
```

### Every 10 seconds (perception)
```
ScreenpipeClient.getRecentContext() → ContextSnapshot
  → ContextNudger.nudge(innerState, snapshot) → mood shifts
  → ErrorDetector checks for errors/successes
  → InterestScorer computes commentability
```

### On agent event (from Claude Code / Codex / Copilot hooks)
```
AgentEvent arrives via existing pipeline
  → EventProcessor (existing) processes it
  → OverlayStateMachine (existing) updates agent:: inputs
  → BehaviorEngine.onAgentEvent() forces dramatic reactions
```

---

## 8. Testing

### Existing tests (must all pass after every change)
All 12 test files in `Tests/`. Run `swift test` after each integration day.

### New tests
```
Tests/
├── DesktopTopologyTests.swift
├── SurfaceGraphTests.swift
├── BehaviorEngineTests.swift
├── InnerStateTests.swift
├── ContextNudgerTests.swift
├── ErrorDetectorTests.swift
├── InterestScorerTests.swift
├── ScreenpipeClientTests.swift
├── OllamaClientTests.swift
├── MovementControllerTests.swift
└── CommentCacheTests.swift
```

### Manual testing matrix

| Scenario | Expected |
|----------|----------|
| All flags off | Stock Masko behavior. Identical to upstream. |
| Spatial only | Mascot follows active window, falls on minimize. |
| Spatial + behavior | Mascot walks, sits, sleeps, fidgets autonomously. |
| Spatial + behavior + screenpipe | Mood responds to screen content. |
| Full stack | LLM comments appear. Errors trigger startle + comment. |
| Claude Code working | Mascot animates to working state (existing) + behavior engine sets energy up. |
| Claude Code task complete | Existing stop handling + forced celebrate behavior. |
| Screenpipe down | FallbackPerception. Emotes/mutters work. Comments reference app name only. |
| Ollama down | Verbal falls back to mutters/emotes. No crash. |
| Select Clippy skin | All smart mascot inputs ignored (Clippy config doesn't declare them). Stock Masko. |
| Select Clawd skin | Full experience — config declares mascot_* inputs, edges respond. |
| 8-hour soak test | CPU < 5%, no memory leak, mood arc visible, no frozen states. |

---

## 9. Timeline

| Day | Deliverable |
|-----|-------------|
| 1 | Fork, build, run, verify all 12 tests pass. Read key files. |
| 2 | Spatial/: DesktopTopology, DockDetector, SurfaceGraph, WindowTracker. Tests. |
| 3 | Navigation/: MovementController, PathPlanner. Wire to OverlayManager. Mascot follows active window. |
| 4 | Fall on minimize. Startle on window move. Polish spatial feel. Tests. |
| 5 | Brain/ core: InnerState, BehaviorWeights, BehaviorScheduler. Random physical behaviors. Tests. |
| 6 | BehaviorEngine: wire to state machine inputs. Wire agent events → reactions. Tests. |
| 7 | Perception/: ScreenpipeClient, ContextPoller, FallbackPerception. Wire to ContextNudger. Tests. |
| 8 | Brain/ remaining: ErrorDetector, InterestScorer, MutterLibrary. Emotes and mutters appear. Tests. |
| 9 | LLM/: OllamaClient, Personality, CommentCache. Full comment flow. Tests. |
| 10 | clawd.json config with placeholder videos. Register in MascotStore.presets. |
| 11 | SpeechBubblePanel. Settings UI. Feature flags. |
| 12 | Clawd animation videos (final or near-final). |
| 13 | Integration testing: full matrix. |
| 14 | Performance audit. Multi-monitor. Bug fixes. |
| 15 | README. Demo video. |
| 16 | Tag, build DMG, publish. |

---

## 10. Principles

1. **Nothing is removed.** Zero deleted files. All adapters, extensions, skins, and tests stay.
2. **Everything is additive.** 22 new files, 4 modified files. Flags gate every feature.
3. **Clawd is a Masko skin.** Same `MaskoAnimationConfig` format. Same video pipeline. Same state machine. New inputs, new edges.
4. **Screenpipe and Ollama are optional.** App works without them. Each adds a layer of intelligence.
5. **Existing tests are the guardrail.** If they break, we broke something. Fix before proceeding.
