# Architecture

Miss Minutes is a set of small modules with one-way dependencies. The
behavioural core is pure Swift with no AppKit, so it is unit-tested; the
AppKit, audio and process layers are thin adapters behind protocols ("ports").
What she does from the user's side is in [CAPABILITIES.md](CAPABILITIES.md).

```
                    ┌────────────────────────────────────────────┐
                    │ MissMinutes (app)                           │
                    │ AppDelegate = composition root, menu bar,   │
                    │ settings, ⌃⌥M + hold-⌃ keys, URL scheme     │
                    └──┬─────────┬──────────┬──────────┬─────────┘
                       │         │          │          │
        ┌──────────────▼──┐ ┌────▼──────┐ ┌─▼────────┐ ┌▼─────────────┐
        │ MinutesStage    │ │MinutesBrain│ │MinutesVoice│ │MinutesCharacter│
        │ windows, sense, │ │ claude -p  │ │ TTS → PCM  │ │ rig, renderer, │
        │ locomotion,     │ │ bridge     │ │ → engine,  │ │ display-linked │
        │ bubble          │ │ server     │ │ lip sync,  │ │ view           │
        │                 │ │            │ │ dictation  │ │                │
        └──────┬──────────┘ └────┬──────┘ └──┬────────┘ └──┬────────────┘
               └─────────────────┴───────────┴─────────────┘
                                     │
                       ┌─────────────▼──────────────┐
                       │ MinutesCore (pure)          │
                       │ Pose · Motions · Gestures · │
                       │ Animator · ScreenMap ·      │
                       │ PerchPlanner ·              │
                       │ Settings · StreamJSON ·     │
                       │ LaunchPlan · HoldToTalk ·   │
                       │ Director+Ports              │
                       └─────────────────────────────┘
```

## The pieces

| Module | Owns | Key types |
| --- | --- | --- |
| `MinutesCore` | Everything that can be decided without the OS | `Pose`, `Motions`, `Gestures`, `Expression`, `Animator`, `ScreenMap`, `PerchPlanner`, `IdleLife`, `SceneSnapshot`, `StreamJSONParser`, `ClaudeLaunchPlanner`, `SentenceStream`, `BodyCommand`, `HoldToTalk`, `YesNo`, `Director`, the `*Port` protocols |
| `MinutesCharacter` | Drawing her | `Rig` (model sheet: proportions, palette), `CharacterRenderer`, `CharacterView`, `ModelSheet` |
| `MinutesStage` | Being on screen | `Stage` (perching, routes, travel, physics, drag, the mapping step), `Puppet`, `ScreenSense`, `ScreenCapturer`, `BubbleController` |
| `MinutesBrain` | The Claude Code process and the body bridge | `ClaudeCodeBrain`, `BodyBridgeServer`, `ExecutableLocator` |
| `MinutesVoice` | Speech out (with lip sync) and in | `SpeechEngine`, `KokoroVoice`, `SpeechListener` |
| `MissMinutes` | Composition root and OS glue | `AppDelegate`, `HotKey` (⌃⌥M), `HoldKey` (hold ⌃), menu bar, settings window |
| `bridge/` (Node) | MCP tool schemas for her body | `miss-minutes-mcp.mjs` |
| `voice/` (Node) | Kokoro neural TTS, installed on request | `miss-minutes-voice.mjs` |

## Animation stack

Each display frame (`CADisplayLink`, 60 fps by default) the stage advances
locomotion, then asks the `Animator` for a `Pose`, then the renderer draws it.
The animator layers, bottom to top:

1. **Base motion**: `stand`, `sit`, `float`, `walk`, `crawl`, `hop`, `fall`, `dangle`, `hang`, `shimmy`, `cling`, `climb`. Procedural functions of time in `Motions`, cross-faded on change. The gaits (walk, crawl, climb, shimmy) advance their phase from the distance actually travelled (`distance / 2·stride`), so planted hands and feet never slide. Hands that hold something (a floor, an edge) are placed in anchor space and converted to body space, so they stay put while the body sways. A far arm can be drawn behind the body (`leftArmBehind`/`rightArmBehind`) when she is side-on.
2. **Mood**: an `Expression` (smile, brows, squint, blush, pupils…), blended over 0.35 s.
3. **Activity loop**: `listen`, `think`, `talk`, `ask`. Looping keyframed gestures that hold while the director is in that phase.
4. **One-shot gestures**: `wave`, `point`, `shrug`, `clap`, `jump`, `bow`, `ring`… Keyframe tracks with override or additive channels and a fade envelope.
5. **Secondary motion**: inertia sway from window acceleration, look-at springs for pupils and face turn, autonomous glances, landing bounce.
6. **Blinks, lip sync, clock hands, hologram presence**: how she comes and goes (`PresenceStyle`: a projector `beam` for teleports; a `twirl` for hiding and coming back, a pirouette that speeds up until she shrinks into a glint, played backwards to return) and the idle flicker.

The renderer is stateless: the same `Pose` always draws the same picture, so
`MissMinutes --render-sheet out.png` shows exactly what plays on screen, and
the app icon is drawn by the same code.

## Where she can be: the screen map

Her anchor is always level with her feet, whatever the posture, so every way
of travelling lines up with every way of resting. `ScreenMap` (pure, built from
one `SceneSnapshot`) lists every **ledge** on screen:

| Ledge | Posture | She moves along it by | Room needed |
| --- | --- | --- | --- |
| Window top | `sit` | walking or crawling | headroom under the menu bar, clear of the traffic lights |
| Window side (outside, left or right) | `cling` | climbing | her width beside the window, on screen |
| Window bottom | `hang` | shimmying hand over hand | her height between the edge and the Dock |
| Display floor (top of the Dock) | `stand` | walking or crawling | none |

Each ledge keeps only the **spans** where her body fits and no window in front
overlaps it. The same scene always gives the same map. On it:

- **`check`** is the mapping step. The stage polls the window list twice a second and runs it whenever the layout (displays, window ids and frames) has changed, or straight away on a display change, an app switch, a Space switch or a settings change. The verdict is `stay` (moved along with her window if it moved), `fall` (her window closed) or `move` to `safeSpot`.
- **`safeSpot`** takes the nearest point of every free span and ranks them by distance plus fixed preferences: her own window first, then the frontmost app, sitting over hanging over clinging over standing, and away from the pointer. Ties go to the ledge listed first, so there is no randomness in it.
- **`route`** runs Dijkstra over span ends, her start and goal, and their nearest points on other spans within hop reach (300 pt), plus drops of up to 420 pt onto a top or floor below that don't pass through the window she is leaving. Moving along a ledge costs its length at that gait's speed. A hop costs more than its airtime, so she keeps to the ledges where she can. From a window's top to underneath it she walks to the corner, hops onto the side, climbs down, swings under the bottom edge and shimmies across. The stage plays a route leg by leg, and hops or teleports when there is no route or it would take over 14 s.

`PerchPlanner` adds taste on top: sampled, scored candidates and
weighted-random picks for `random`, `explore(app:)` (another spot on an app's
windows, favouring a different posture), `hang(app:)` and `stroll` (a short way
along her own ledge).

**Idle life** (`IdleLife`, used by the director). Every few seconds
(`idleInterval`, set by Restlessness) she has a beat: a fidget that suits her
posture or, a third of the time, a stroll. Hanging or clinging, she only does
gestures that leave a hand on the edge. Every minute or so (`wanderInterval`)
she moves somewhere new, usually another edge of the frontmost app. Switching
apps often brings her along.

## A conversation, end to end

```
click (after the double-click wait) / ⌃⌥M / missminutes://ask
  → Director.listen → Bubble input → Director.ask
double-click → Director.hide: stop talking, close the bubble, Stage.vanish (twirl)
hold ⌃ (HoldKey → HoldToTalk)
  → Director.holdToTalk(.began) → Stage.appear if hidden → SpeechListener partials → Bubble hearing
  → let go: .ended → SpeechListener final → Director.ask
  → ClaudeCodeBrain.send  (stdin: {"type":"user",…})
  ← stream_event text deltas ─→ Bubble.setReply + SentenceStream → SpeechEngine.speak
                                  → KokoroVoice (node sidecar, PCM over stdio) or AVSpeechSynthesizer.write
  ← control_request can_use_tool ─→ Bubble permission ─→ control_response allow/deny
        answered by a click, or by voice: hold ⌃, or hands-free once she has asked
        → SpeechListener (.confirmation hint) → YesNo.parse → Director.answerPermission
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

**A new perch surface** (hanging from the menu bar, sitting on a Dock icon…).
Add a `Surface` case and build its `Ledge` in `ScreenMap.build` (anchor line,
spans, and the band her body occupies, for `clear`). Teach
`ScreenMap.anchor(on:frame:offset:)` where the anchor goes when its window
moves. Give it a `Posture` with a resting base motion, and say how she moves
along it in `Ledge.locomotion`. Routes, safe spots, ride-along and the mapping
step then work without further changes. Add a sheet entry with a `Prop` to
check her grip.

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
- **Lip sync from real audio.** Each sentence is rendered to PCM, by Kokoro or by `AVSpeechSynthesizer.write`, and played through one `AVAudioEngine` while its RMS envelope drives the jaw; letters at the current position shape the lips. A sentence from the other voice (a fallback mid-reply) is resampled to the connected format rather than reconnecting and cutting off queued audio.
- **Kokoro as a Node sidecar, downloaded on request.** Kokoro-82M (Apache-2.0) sounds human where the compact macOS voices sound robotic. It runs through `kokoro-js` and ONNX Runtime in a long-lived `node voice/miss-minutes-voice.mjs serve` process: JSON lines in, base64 float32 PCM out. Node is already needed for the body bridge, and nothing third-party ships in the app: `install` runs `npm ci` from the pinned lockfile into Application Support, prunes other platforms' binaries and downloads the q8 model (~330 MB total). `serve` then refuses the network. While Kokoro is starting the engine waits up to 12 s rather than open with a different voice, and any sentence Kokoro fails on is said by the macOS voice.
- **Hold ⌃ without permissions.** Carbon can't register a modifier-only hotkey and an event tap needs Input Monitoring, so `HoldKey` polls `CGEventSource.flagsState` and the window server's key/click/scroll counters at 30 Hz; neither needs a permission. `HoldToTalk` (pure, tested) turns that into began/ended/cancelled: ⌃ alone for 0.3 s begins, any other input while it's down means a shortcut.
- **Dictation with `SFSpeechRecognizer`**, on-device when the language model is installed. It needs the microphone and speech-recognition usage strings in Info.plist, so it only works from the .app, not `swift run`.
- **Spoken permission answers are strict.** A yes lets Claude Code run a command, so `YesNo` (pure, tested) accepts only an utterance that is wholly yes phrases or wholly no phrases, plus fillers ("um, yeah, go ahead"); a sentence that merely contains "yes", a mix of both, or a qualified "yes, but…" is no answer. Hands-free, a clear answer must stand for 0.8 s before she acts ("no… problem" is a yes), her ears open only after her own voice has finished, close after 8 s, and only open at all if macOS has already granted the microphone (`EarsPort.isAuthorized`), so no system prompt appears mid-question. Held ⌃, the answer is what was said when it is let go, and a muddled one gets "Was that a yes or a no?".
- **Deterministic re-perching, lively wandering.** Deciding where she *must* go when the screen changes is pure geometry (`ScreenMap.check`/`safeSpot`), so the same screen always gets the same answer and she never jumps somewhere arbitrary because a window moved. Choosing where she *likes* to go when idle is weighted-random (`PerchPlanner`), so she doesn't repeat herself.
- **Window geometry without permissions.** `CGWindowListCopyWindowInfo` gives frames and owners with no prompt. Screenshots (only on request) need Screen Recording.
- **Her own working folder** in Application Support keeps Claude Code from scanning your home folder (which would trigger macOS privacy prompts for Desktop, Documents and Downloads).
