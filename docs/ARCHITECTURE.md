# Architecture

Miss Minutes is a set of small modules with one-way dependencies. The
behavioural core is pure Swift with no AppKit, so it is unit-tested; the
AppKit, audio and process layers are thin adapters behind protocols ("ports").

```
                    ┌────────────────────────────────────────────┐
                    │ MissMinutes (app)                           │
                    │ AppDelegate = composition root, menu bar,   │
                    │ settings window, ⌃⌥M hotkey, URL scheme     │
                    └──┬─────────┬──────────┬──────────┬─────────┘
                       │         │          │          │
        ┌──────────────▼──┐ ┌────▼──────┐ ┌─▼────────┐ ┌▼─────────────┐
        │ MinutesStage    │ │MinutesBrain│ │MinutesVoice│ │MinutesCharacter│
        │ windows, sense, │ │ claude -p  │ │ TTS → PCM  │ │ rig, renderer, │
        │ locomotion,     │ │ bridge     │ │ → engine,  │ │ display-linked │
        │ bubble          │ │ server     │ │ lip sync   │ │ view           │
        └──────┬──────────┘ └────┬──────┘ └──┬────────┘ └──┬────────────┘
               └─────────────────┴───────────┴─────────────┘
                                     │
                       ┌─────────────▼──────────────┐
                       │ MinutesCore (pure)          │
                       │ Pose · Motions · Gestures · │
                       │ Animator · PerchPlanner ·   │
                       │ Settings · StreamJSON ·     │
                       │ LaunchPlan · Director+Ports │
                       └─────────────────────────────┘
```

## The pieces

| Module | Owns | Key types |
| --- | --- | --- |
| `MinutesCore` | Everything that can be decided without the OS | `Pose`, `Motions`, `Gestures`, `Expression`, `Animator`, `PerchPlanner`, `SceneSnapshot`, `StreamJSONParser`, `ClaudeLaunchPlanner`, `SentenceStream`, `BodyCommand`, `Director`, the `*Port` protocols |
| `MinutesCharacter` | Drawing her | `Rig` (model sheet: proportions, palette), `CharacterRenderer`, `CharacterView`, `ModelSheet` |
| `MinutesStage` | Being on screen | `Stage` (perching, travel, physics, drag), `Puppet`, `ScreenSense`, `ScreenCapturer`, `BubbleController` |
| `MinutesBrain` | The Claude Code process and the body bridge | `ClaudeCodeBrain`, `BodyBridgeServer`, `ExecutableLocator` |
| `MinutesVoice` | Speech and lip sync | `SpeechEngine` |
| `bridge/` (Node) | MCP tool schemas for her body | `miss-minutes-mcp.mjs` |

## Animation stack

Each display frame (`CADisplayLink`, 60 fps by default) the stage advances
locomotion, then asks the `Animator` for a `Pose`, then the renderer draws it.
The animator layers, bottom to top:

1. **Base motion**: `stand`, `sit`, `float`, `walk`, `hop`, `fall`, `dangle`. Procedural functions of time in `Motions`, cross-faded on change. The walk advances its phase from the distance actually travelled (`dx / 2·stride`), so feet never slide.
2. **Mood**: an `Expression` (smile, brows, squint, blush, pupils…), blended over 0.35 s.
3. **Activity loop**: `listen`, `think`, `talk`, `ask`. Looping keyframed gestures that hold while the director is in that phase.
4. **One-shot gestures**: `wave`, `point`, `shrug`, `clap`, `jump`, `bow`, `ring`… Keyframe tracks with override or additive channels and a fade envelope.
5. **Secondary motion**: inertia sway from window acceleration, look-at springs for pupils and face turn, autonomous glances, landing bounce.
6. **Blinks, lip sync, clock hands, hologram presence** (materialize, dematerialize, idle flicker).

The renderer is stateless: the same `Pose` always draws the same picture, so
`MissMinutes --render-sheet out.png` shows exactly what plays on screen, and
the app icon is drawn by the same code.

## A conversation, end to end

```
click / ⌃⌥M / missminutes://ask
  → Director.listen → Bubble input → Director.ask
  → ClaudeCodeBrain.send  (stdin: {"type":"user",…})
  ← stream_event text deltas ─→ Bubble.setReply + SentenceStream → SpeechEngine.speak
  ← control_request can_use_tool ─→ Bubble permission ─→ control_response allow/deny
  ← tool_use mcp__minutes__move_to
        Claude Code → node bridge (MCP stdio) → TCP 127.0.0.1 + token → BodyBridgeServer
        → BodyCommand.decode → Director.handle(body:) → Stage.move → reply "Arrived."
  ← result ─→ flush speech; turn ends when the voice finishes
```

## Extension recipes

**A new gesture.** Add a case to `GestureName`, a `Gesture` in `Gestures`
(keyframes in body space; shoulders at (±47, -6)), add it to the `GESTURES`
list in `bridge/miss-minutes-mcp.mjs` (a test keeps the two in sync), and an
entry to `ModelSheet.all` to review it with `make sheet`.

**A new mood.** Add a `Mood` case and its row in `Expression.of`; mirror it in
the bridge's `MOODS`.

**A new body tool.** Declare its schema in the bridge's `TOOLS`, add a
`BodyCommand` case and its decoding, handle it in `Director.handle(body:)`.
Mention it in `Persona.builtIn` so the brain knows to use it.

**A new perch surface** (hanging from the menu bar, leaning on a window's
side…). Add a `Surface` case, produce ledges for it in `PerchPlanner.ledges`,
teach `relocate` how it moves, and give it a `Posture` and base motion.

**A different brain.** Implement `BrainPort` (emit `BrainEvent`s). The
director never sees Claude Code specifics: a sidecar in Node or Rust, the
Anthropic API directly, or a local model all fit behind the same port. Wire it
in `AppDelegate`.

**A new setting.** Add the field with a default to the relevant settings
struct *and* to its `init(from:)` (`c.value(.key, d.key)`), so settings saved
by older versions still load. Surface it in `SettingsWindow.swift` and, if it
is a quick toggle, in `StatusMenuController`.

## Decisions worth knowing

- **One long-lived `claude -p` process** in stream-json mode, not a process per message: warm start, prompt caching, and a real multi-turn session. Restarts resume the session (`--resume`) unless you ask for a new conversation.
- **Permissions over stdio** (`--permission-prompt-tool stdio`): the CLI asks, the bubble answers. Her own MCP server is pre-allowed (`--allowedTools mcp__minutes`).
- **Persona appended, not replacing** Claude Code's system prompt, so its tool guidance stays intact.
- **The body bridge is Node** because Claude Code speaks MCP to subprocesses; it has zero dependencies and talks to the app over loopback TCP with a per-launch random token.
- **No Rust yet.** Nothing in v1 needs it. A natural first Rust component would be a sidecar for heavy local work (wake word, on-device vision) behind `BrainPort` or a new port.
- **Lip sync from real audio.** `AVSpeechSynthesizer.write` renders PCM, which is played through `AVAudioEngine` while its RMS envelope drives the jaw; letters at the current position shape the lips.
- **Window geometry without permissions.** `CGWindowListCopyWindowInfo` gives frames and owners with no prompt. Screenshots (only on request) need Screen Recording.
- **Her own working folder** in Application Support keeps Claude Code from scanning your home folder (which would trigger macOS privacy prompts for Desktop, Documents and Downloads).
