# Haiku Behavior Engine — Making It Loveable

> The old Decision Engine was a gatekeeper. This is a nervous system.

---

## The Problem With v2's Decision Engine

It treated Haiku as a **commentary delivery system with rate limiting**. The character sits idle, waiting for the Decision Engine to approve a speech event. 95% of the time it does nothing visible. That's not a creature — it's a notification system wearing a costume.

Shimeji has millions of fans and it **never speaks a single word**. People love it because it's constantly alive — walking, climbing, sitting, falling, reacting. The aliveness IS the product. Speech is seasoning, not the meal.

---

## The Shift

```
OLD: Perception → Decision (speak or shut up) → LLM → Speech bubble
NEW: Perception → Inner State → Behavior Stream → (mostly physical, sometimes verbal)
```

The character is ALWAYS doing something. Every 3-8 seconds it picks a new behavior. Most behaviors are physical (walk, climb, sit, peek, fidget). Rarely, one behavior is verbal (comment). The constant physical life makes the occasional speech feel natural and special, not like a pop-up ad.

---

## Inner State (The Creature's Mood)

Haiku has a simple emotional model that **drifts over time** and is **nudged by what's happening on screen**. This drives behavior selection.

```swift
struct InnerState {
    var energy: Float    // 0.0 (exhausted) → 1.0 (hyper)
    var curiosity: Float // 0.0 (bored) → 1.0 (fascinated)  
    var comfort: Float   // 0.0 (anxious) → 1.0 (cozy)
    
    // Derived mood for behavior selection
    var mood: Mood {
        if energy < 0.2 { return .sleepy }
        if comfort < 0.3 { return .nervous }
        if curiosity > 0.7 && energy > 0.5 { return .excited }
        if energy > 0.7 { return .playful }
        if comfort > 0.7 { return .content }
        return .neutral
    }
}

enum Mood {
    case sleepy, nervous, excited, playful, content, neutral
}
```

### How Context Nudges State

```swift
func nudge(with context: ScreenpipeContext) {
    // Errors → comfort drops, curiosity spikes
    if containsError(context.visibleText) {
        state.comfort -= 0.15
        state.curiosity += 0.2
    }
    
    // Meetings/Zoom → energy drops
    if context.appName.contains("zoom") || context.appName.contains("meet") {
        state.energy -= 0.05  // slowly drains during meetings
    }
    
    // Creative apps (Figma, music) → comfort rises
    if ["figma", "sketch", "logic", "ableton"].contains(where: { 
        context.appName.lowercased().contains($0) }) {
        state.comfort += 0.05
    }
    
    // Browsing fun stuff → energy rises
    if context.visibleText.contains("youtube") || 
       context.visibleText.contains("reddit") {
        state.energy += 0.1
        state.curiosity += 0.1
    }
    
    // Deep focus (same app 10+ min) → comfort rises, curiosity drops
    if sameAppDuration > 600 {
        state.comfort += 0.03
        state.curiosity -= 0.02
    }
    
    // Natural energy decay over time (gets tired)
    state.energy -= 0.01  // per cycle
    
    // Late night → energy drops faster
    if hour >= 22 { state.energy -= 0.03 }
    
    // Clamp all values 0.0 - 1.0
    state.clamp()
}
```

The user never sees these numbers. They see a creature that **gradually gets sleepy during long meetings**, **perks up when you open YouTube**, **gets fidgety when errors pile up**, and **settles down during deep focus work**.

---

## Behavior Stream

Every 4-8 seconds (randomized), the Behavior Engine picks one action from a weighted pool. The weights change based on mood.

### Behavior Categories

```
PHYSICAL (90% of all behaviors — the creature's life)
├── Locomotion
│   ├── walk_on_surface      — walk left/right on current window edge
│   ├── jump_to_window       — leap to a nearby window
│   ├── climb_window_edge    — climb up the side of a window
│   ├── slide_down           — slide down a window edge  
│   └── fall_to_dock         — fall with gravity to dock/bottom
├── Idle
│   ├── stand_idle           — just standing, blinking
│   ├── sit_down             — sit on edge, legs dangling
│   ├── look_around          — head turns left/right
│   ├── fidget               — small body shake/stretch
│   ├── yawn                 — yawn animation
│   └── nod_off              — head drops, catches self
├── Play
│   ├── peek_behind_window   — hide behind window, eyes visible
│   ├── hang_from_edge       — hang from window top by hands
│   ├── balance_on_edge      — wobble on narrow window edge  
│   ├── inspect_window       — lean forward, squint at screen
│   └── tap_on_window        — knock on the window (tiny animation)
├── React (triggered by events, not random)
│   ├── startle              — jump up when window moves suddenly
│   ├── wave                 — wave when new window appears
│   ├── duck                 — duck when window expands toward character
│   └── celebrate            — little dance on successful build
└── Environmental
    ├── sit_on_dock           — perch on dock, swing legs
    ├── lean_on_menubar       — lean against menu bar
    └── surf_window           — ride a window that's being moved

VERBAL (10% of behaviors — rare and therefore precious)
├── comment                   — LLM-generated remark about screen context
├── mutter                    — short canned phrase, no LLM needed
└── emote                     — emoji/symbol in speech bubble (💤 😮 🤔 ...)
```

### Mood-Based Weights

```swift
func behaviorWeights(for mood: Mood) -> [Behavior: Float] {
    switch mood {
    case .sleepy:
        return [
            .sit_down: 30, .nod_off: 25, .yawn: 20,
            .stand_idle: 15, .look_around: 5,
            .mutter: 3, .emote_zzz: 2
            // no walking, climbing, or playing when sleepy
        ]
    case .playful:
        return [
            .walk_on_surface: 15, .jump_to_window: 15, 
            .climb_window_edge: 10, .peek_behind_window: 12,
            .hang_from_edge: 10, .balance_on_edge: 8,
            .tap_on_window: 8, .inspect_window: 5,
            .fidget: 5, .sit_down: 2,
            .comment: 5, .mutter: 3, .emote: 2
        ]
    case .nervous:
        return [
            .look_around: 25, .fidget: 20, .walk_on_surface: 15,
            .peek_behind_window: 10, .duck: 5,
            .stand_idle: 10,
            .comment: 8, .mutter: 5, .emote: 2
            // more likely to comment when nervous (errors happening)
        ]
    case .excited:
        return [
            .jump_to_window: 20, .climb_window_edge: 15,
            .walk_on_surface: 10, .celebrate: 5,
            .inspect_window: 15, .tap_on_window: 10,
            .hang_from_edge: 5, .balance_on_edge: 5,
            .comment: 8, .mutter: 5, .emote: 2
        ]
    case .content:
        return [
            .sit_down: 30, .stand_idle: 20, .look_around: 15,
            .walk_on_surface: 10, .lean_on_menubar: 10,
            .sit_on_dock: 5,
            .mutter: 5, .comment: 3, .emote: 2
        ]
    case .neutral:
        return [
            .walk_on_surface: 20, .stand_idle: 15,
            .sit_down: 15, .look_around: 10,
            .jump_to_window: 8, .fidget: 8,
            .peek_behind_window: 5, .inspect_window: 5,
            .climb_window_edge: 4,
            .comment: 4, .mutter: 3, .emote: 3
        ]
    }
}
```

### LLM Comment Rate (Emergent, Not Hard-Coded)

Notice: `comment` is always in the weight pool, but with low weight (3-8%). Combined with the 4-8 second behavior cycle, this means:

- On average, ~1 comment attempt every 60-120 seconds
- But it's **probabilistic, not on a timer** — feels organic
- When nervous (errors on screen), comment weight rises to 8% → more frequent
- When content (deep focus), comment weight drops to 3% → very rare
- When sleepy, comments disappear entirely → character just dozes

**There's no hard cooldown.** The rarity emerges naturally from the weight system. And because the character is constantly doing physical things between comments, a comment every 90 seconds feels like a natural part of its behavior, not an interruption.

### The Safety Valve

One simple rule prevents spam without feeling rigid:

```swift
// If the last comment got dismissed (user clicked X on bubble),
// halve the comment weight for 10 minutes.
// If the last 3 comments were dismissed, comment weight → 0 for 30 min.
// "The creature learns you want quiet right now."
```

This is responsive to the USER, not to an arbitrary timer.

---

## Mutters vs. Comments vs. Emotes

Three tiers of verbal behavior, each with different cost:

| Type | LLM call? | Example | Frequency |
|------|-----------|---------|-----------|
| **Emote** | No | 💤 😮 🤔 💡 ❤️ (in tiny bubble) | Common |
| **Mutter** | No | "hmm." / "oh." / "nice." / "oof." | Occasional |
| **Comment** | Yes (Ollama) | "JWT again? We've all been there." | Rare, precious |

Emotes are free, instant, and add life. Mutters are canned one-word reactions — still no LLM but feel responsive. Comments are the full LLM-powered contextual one-liners.

This means **even without Ollama running**, the character still has personality through emotes and mutters. The LLM just makes it brilliant.

### Mutter Library (Keyed to Context Patterns)

```swift
let mutters: [String: [String]] = [
    // Detected in visible text
    "error":       ["oof.", "yikes.", "hmm.", "that's not great."],
    "TODO":        ["still?", "someday.", "we believe in you."],
    "stackoverflow": ["classic.", "the oracle.", "been there."],
    "npm install": ["here we go.", "patience.", "node_modules grows."],
    "merge conflict": ["oh no.", "deep breaths.", "who did this."],
    "PASSED":      ["nice.", "clean.", "✓"],
    "FAILED":      ["oof.", "again?", "we'll get it."],
    
    // App-based
    "zoom":        ["oh.", "here we go.", "..."],
    "slack":       ["ping.", "another one.", "mhm."],
    "youtube":     ["research?", "sure.", "heh."],
    "figma":       ["ooh.", "pretty.", "nice."],
    "calendar":    ["ugh.", "how many?", "oh."],
    "mail":        ["don't.", "careful.", "hmm."],
    
    // Time-based
    "late_night":  ["still?", "you sure?", "zzz."],
    "morning":     ["morning.", "let's go.", "coffee?"],
    "friday_5pm":  ["go home.", "done?", "weekend."],
]
```

---

## Context-Aware Physical Behavior

The behavior engine doesn't just use mood — it uses context to pick **contextually appropriate** physical actions:

```swift
// In a code editor → inspect_window, tap_on_window more likely
// (character peers at your code curiously)
if context.appName.contains("Code") || context.appName.contains("cursor") {
    boost(.inspect_window, by: 3.0)
    boost(.tap_on_window, by: 2.0)
}

// In a browser → peek_behind_window, hang_from_edge
// (character is more playful/nosy)  
if context.appName.contains("Chrome") || context.appName.contains("Safari") {
    boost(.peek_behind_window, by: 3.0)
    boost(.hang_from_edge, by: 2.0)
}

// Terminal with long output → surf_window, climb_window_edge
// (character treats scrolling output like a waterfall)
if context.appName.contains("Terminal") && context.visibleText.count > 500 {
    boost(.climb_window_edge, by: 3.0)
}

// Active window just moved → startle, then chase it
if activeWindowMoved {
    forceNext(.startle)
    queueAfter(.jump_to_window, delay: 0.5)
}

// Build succeeded (PASSED / SUCCESS / ✓ in text) → celebrate
if detectsSuccess(context.visibleText) {
    forceNext(.celebrate)
}
```

This creates **emergent storytelling**: the character seems to understand your work, not because it's commenting, but because it's physically reacting to your context. It peers at your code. It gets startled when your build fails. It celebrates when tests pass. It falls asleep in meetings.

---

## Session Arc (The Long Game)

The inner state creates a natural story arc across a work session:

```
Morning:
  Energy: 0.8, Curiosity: 0.5, Comfort: 0.6
  → Mood: playful
  → Lots of walking, jumping, exploring windows
  → Occasional excited comments

Mid-morning focus:
  Energy: 0.6, Curiosity: 0.3, Comfort: 0.8  
  → Mood: content
  → Sitting quietly, occasional look around
  → Rare, thoughtful comments

After meeting:
  Energy: 0.3, Curiosity: 0.2, Comfort: 0.5
  → Mood: sleepy
  → Sitting, yawning, nodding off
  → Emotes only (💤, 😴)

Error spike:  
  Energy: 0.3 → 0.5, Curiosity: 0.8, Comfort: 0.3
  → Mood: nervous
  → Fidgeting, looking around, peeking at screen
  → More frequent comments ("that stack trace though.")

Late afternoon:
  Energy: 0.4, Curiosity: 0.4, Comfort: 0.7
  → Mood: content
  → Settled in, sitting on dock, occasional walk
  → Gentle comments ("wrapping up?")

Late night:
  Energy: 0.1, Curiosity: 0.1, Comfort: 0.5
  → Mood: sleepy  
  → Nods off, yawns, barely moves
  → If comment triggers: "it's late. this code will still be here."
```

**The user doesn't configure this. They just feel it.** The character seems to have its own energy level that mirrors their day.

---

## Implementation Complexity

The Behavior Engine replaces the Decision Engine. Same file count, different philosophy:

```
Brain/
├── InnerState.swift         # 3 floats + nudge logic (~80 lines)
├── BehaviorEngine.swift     # Weighted random selection (~150 lines)
├── BehaviorWeights.swift    # Mood → weight tables (~100 lines)
├── ContextBoosters.swift    # App-specific behavior boosts (~60 lines)
├── MutterLibrary.swift      # Canned phrases dictionary (~80 lines)
└── ErrorDetector.swift      # Pattern matching (unchanged, ~40 lines)
```

**~510 lines total** — about the same as v2's Decision Engine, but producing a vastly richer experience.

---

## Why This Creates Love

1. **The creature is never static.** Every few seconds it does something. Most are small (blink, fidget, look around). Some are dramatic (climb a window, fall to dock). This constant micro-behavior triggers the Tamagotchi effect — you start attributing consciousness.

2. **Commentary is rare and earned.** Because physical behavior fills the space between comments, a verbal comment feels like the character couldn't help itself — it had to say something. That's endearing, not annoying.

3. **Context-aware physical behavior is magic.** When the character squints at your code, or ducks when a window resizes, or celebrates when tests pass — that's not just cute, it's *uncanny*. It creates the feeling that the creature understands, even when it hasn't said a word.

4. **The session arc creates narrative.** Users will notice their creature getting sleepy after meetings, or perking up after lunch. This creates an emotional rhythm that mirrors their own workday. People will screenshot "look, Haiku fell asleep during standup" and share it.

5. **The safety valve respects the user.** Dismiss a comment → creature learns to be quiet. No settings panel needed. No "frequency slider." Just a creature that picks up on your cues.

---

*"I speak about 10% of the time. The other 90%? I'm climbing your VS Code window, sitting on your dock, and pretending to read your Slack messages. That's the part people actually love."*
— Haiku, if it were self-aware
