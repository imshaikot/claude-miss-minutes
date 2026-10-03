<p align="center"><img src="docs/icon.png" width="128" alt="Miss Minutes icon"></p>

<h1 align="center">Claude Miss Minutes</h1>

<p align="center">An animated 1950s-cartoon clock who lives on your Mac desktop as a personal assistant, with Claude Code as her brain.</p>

<p align="center"><img src="docs/model-sheet.png" alt="Model sheet: every pose and mood, rendered by the app's own renderer"></p>

> An unofficial fan homage to a certain time-keeping hostess. The character is original vector art drawn in code; nothing here is affiliated with Marvel or Disney.

## What she does

- **Lives on your screen with no window around her.** A frameless, transparent overlay on every Space, including full-screen apps. Clicks pass straight through everywhere except her silhouette.
- **Moves like a cartoon.** Rubber-hose arms and legs, squash and stretch, a bouncing idle, blinking pie-cut eyes that follow your pointer, walk cycles with planted feet, hops with anticipation and landing squash, hologram teleports with scan lines and glitch tearing, and a cartoon hang-time before she falls.
- **Sits where it makes sense.** She reads the window layout and perches on the visible top edges of windows (never behind another window, never under the menu bar, clear of the traffic lights), stands on the Dock, and rides along when you drag the window she's sitting on. Close it and she falls to the next ledge down. Turn gravity off and she hovers anywhere you drop her.
- **Talks.** Replies stream into her speech bubble and are spoken sentence by sentence as they arrive, with lip sync driven by the voice's real audio amplitude.
- **Thinks with Claude Code.** One long-lived `claude -p` process in stream-json mode. Tool permission requests come up in her bubble with Allow and Deny.
- **Has a body Claude can use.** A Node MCP server exposes `emote`, `move_to`, `look_at_screen` and `set_reminder`, so she acts out her answers, walks to the app you mention, looks at your screen when you ask, and pops up ringing like an alarm clock when a reminder is due.
- **Is configured from the menu bar.** A little clock that shows the real time. Switch model (Fable, Opus, Sonnet, Haiku or any id), tool access and effort, toggle wandering, gravity, voice and hologram, or open Settings.

## Install

Requirements: macOS 14+, [Claude Code](https://claude.com/claude-code) installed and signed in. Node.js is optional; without it she can still talk, but Claude cannot move her or use her other body tools.

```sh
make install          # builds, signs ad-hoc, copies to /Applications
open "/Applications/Miss Minutes.app"
```

The build is ad-hoc signed and not notarized. If Gatekeeper complains, right-click ▸ Open once, or run `xattr -dr com.apple.quarantine "/Applications/Miss Minutes.app"`.

## Use

| Do this | To |
| --- | --- |
| Click her, or press **⌃⌥M** anywhere | Open her bubble and type |
| **Esc** while she talks | Interrupt her |
| Drag her | Pick her up and drop her anywhere |
| Menu bar clock | Model, tools, effort, wander, gravity, voice, settings |
| `open "missminutes://ask?q=What's on my screen?"` | Ask from Shortcuts, Raycast, Alfred or a script (`summon`, `show`, `hide` and `settings` work too) |

**Tool access** (menu bar ▸ Brain, or Settings):

- *Conversation only*: no file, shell or web tools.
- *Look & search* (default): read files, search, browse. Nothing that changes anything.
- *Full tools, ask first*: every Claude Code tool. Anything not already allowed in your Claude Code settings is asked in her bubble.

Her working folder is `~/Library/Application Support/Claude Miss Minutes/Workspace` unless you choose another in Settings. Screenshots for `look_at_screen` need Screen Recording permission, which macOS asks for the first time she looks.

## Build from source

```sh
make build            # swift build (debug)
make run              # run the debug build
make test             # Swift tests (swift-testing) + bridge tests (node --test)
make sheet            # render every pose and mood to dist/sheet.png
make app              # dist/Miss Minutes.app, universal (ARCHS=arm64 for a quick local build)
make dmg              # dist/MissMinutes-<version>.dmg
.build/debug/MissMinutes --say "Hey there, sugar."   # voice + lip-sync check, prints the jaw curve
```

On a Mac where the Xcode license is not accepted, prefix commands with `DEVELOPER_DIR=/Library/Developer/CommandLineTools`.

## How it's built

Native AppKit + Core Graphics + SwiftUI (settings and bubble) in SwiftPM modules with one-way dependencies, a zero-dependency Node MCP bridge, and Claude Code as a subprocess. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the module map, the data flow and how to add a gesture, a body tool, a perch surface or a different brain.

```
Sources/
  MinutesCore/        pure model: pose, motions, gestures, animator, perch planner,
                      settings, stream-json protocol, launch plan, director (no AppKit)
  MinutesCharacter/   rig (model sheet), Core Graphics renderer, display-linked view
  MinutesStage/       transparent windows, screen sensing, locomotion, speech bubble
  MinutesBrain/       Claude Code process, executable lookup, body bridge server
  MinutesVoice/       speech synthesis → audio engine → amplitude lip sync
  MinutesObjC/        catches AVFoundation's Objective-C exceptions
  MissMinutes/        app: composition root, menu bar, settings window, hotkey
bridge/               miss-minutes-mcp.mjs: MCP server Claude Code launches
Tests/                swift-testing suites (57 tests)
```

## License

Apache-2.0 © 2026 Shahriar. See [LICENSE](LICENSE).
