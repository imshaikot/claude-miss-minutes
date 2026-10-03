# Capabilities

What Miss Minutes does, how to drive her and what she asks your Mac for. For
how it works inside, see [ARCHITECTURE.md](ARCHITECTURE.md).

## On your screen

- **No window around her.** A frameless, transparent overlay on every Space, including full-screen apps. Clicks pass straight through everywhere except her silhouette.
- **Moves like a cartoon.** Rubber-hose arms and legs, squash and stretch, a bouncing idle, blinking pie-cut eyes that follow your pointer, walk and crawl cycles with planted hands and feet, hand-over-hand climbing and shimmying, hops with anticipation and landing squash, a little Charleston, hologram teleports with scan lines and glitch tearing, and a cartoon hang-time before she falls.
- **Never still for long.** Every few seconds she fidgets or strolls a little way along whatever she's on; every minute or so she heads somewhere new, usually another edge of the app you're working in. A Restlessness slider sets the pace.
- **Climbs all over your windows.** She sits on window tops, clings to their sides, hangs from their bottom edges and stands on the Dock, only where she fits and nothing is in front (never under the menu bar, clear of the traffic lights). She goes round a window's frame rather than through it, and hops the gaps between windows.
- **Keeps up with your layout.** She rides along when you drag her window. Whenever the layout changes she maps the screen again and, if her spot is now covered or squeezed, moves to the nearest safe one. That choice is fixed geometry, not chance, so the same screen always gets the same answer. Close her window and she falls to the next ledge down. Turn gravity off and she hovers anywhere you drop her.

## Conversation

- **Talks.** Replies stream into her speech bubble and are spoken sentence by sentence as they arrive, with lip sync driven by the voice's real audio amplitude. See [Voice](#voice).
- **Listens.** Hold **⌃ Control** anywhere and talk; let go and she answers. Apple's own recognizer turns speech into text, on your Mac when the language's on-device model is installed.
- **Thinks with Claude Code.** One long-lived `claude -p` process in stream-json mode, resumed across restarts. Tool permission requests come up in her bubble with Allow and Deny, and she asks them out loud: answer with a click, or say yes or no.
- **Takes a spoken yes or no.** Once she has finished asking, she listens for about 8 seconds (a pulsing mic in the bubble), or hold ⌃ and say it at any time. Only a plain answer counts ("yeah, go ahead", "no thanks", "don't"): anything she isn't sure of, such as "yes, but only…", a mix of both or other talk in the room, is no answer, and the buttons stay. Hands-free listening only starts once macOS has already let her use the microphone, and can be turned off in Settings ▸ General.
- **Has a body Claude can use.** A Node MCP server exposes `emote`, `move_to`, `look_at_screen` and `set_reminder`, so she acts out her answers, walks, crawls or climbs to the app you mention, looks at your screen when you ask, and pops up ringing like an alarm clock when a reminder is due.

## Controls

| Do this | To |
| --- | --- |
| Hold **⌃** anywhere and talk, then let go | Ask her out loud (cuts her off if she's talking), or answer her permission question with yes or no |
| Say "yes" or "no" right after she asks permission | Allow or deny, hands-free |
| Click her, or press **⌃⌥M** anywhere | Open her bubble and type |
| **Esc** while she talks | Interrupt her |
| Drag her | Pick her up and drop her anywhere |
| Menu bar clock | Model, tools, effort, wander, gravity, voice, hologram, settings |
| `open "missminutes://ask?q=What's on my screen?"` | Ask from Shortcuts, Raycast, Alfred or a script (`summon`, `show`, `hide` and `settings` work too) |

The menu bar clock shows the real time. From it you can switch model (Fable,
Opus, Sonnet, Haiku or any id), tool access and effort, and toggle wandering,
gravity, voice and hologram.

## Tool access

Set from menu bar ▸ Brain, or Settings.

- *Conversation only*: no file, shell or web tools.
- *Look & search* (default): read files, search, browse. Nothing that changes anything.
- *Full tools, ask first*: every Claude Code tool. Anything not already allowed in your Claude Code settings is asked in her bubble.

## Voice

Her voice is [Kokoro](https://huggingface.co/hexgrad/Kokoro-82M), an
open-source neural text-to-speech model that runs on your Mac. Settings ▸
Voice ▸ Download fetches it (about 330 MB: npm packages and the model, into
`~/Library/Application Support/Claude Miss Minutes/Voice`). It needs Node.js,
runs offline afterwards, and uses roughly 400–550 MB of memory while she's
using it; switch the engine to *macOS voices* to free it.

Until Kokoro is downloaded, or if it fails on a sentence, she uses a macOS
voice. For a better one, download an Enhanced or Premium voice (Ava or Zoe)
under System Settings ▸ Accessibility ▸ Spoken Content.

## Permissions and files

- **Working folder**: `~/Library/Application Support/Claude Miss Minutes/Workspace` unless you choose another in Settings. Running Claude Code in your home folder would trigger macOS privacy prompts for Desktop, Documents and Downloads.
- **Screen Recording**: only for `look_at_screen`; macOS asks the first time she looks. Window positions need no permission.
- **Microphone and Speech Recognition**: for hold-to-talk and spoken yes/no answers; asked the first time you hold ⌃, never by the hands-free listening. ⌃ shortcuts (⌃C, ⌃-click) never trigger it: any other key, click or modifier while ⌃ is down cancels.
- **Node.js** (optional): without it she still talks, in a macOS voice, but Claude cannot move her or use her other body tools.
