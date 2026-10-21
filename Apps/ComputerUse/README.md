# wink-cua — fast, Sky-style computer use for agents

`wink-cua` is a lean MCP server for driving macOS apps **in the background**. It doesn't take over
the user's mouse or keyboard, and an animated agent cursor shows what it is doing. It is a separate
fast path inside the Wink fork. It doesn't replace `wink mcp`, and it shares none of that
server's snapshot, bridge or receipt machinery.

It is a single 400 KB binary with no dependencies beyond system frameworks. It needs no companion
app and no Codex/ChatGPT install.

## Install

```bash
cd Apps/ComputerUse
./scripts/install.sh            # builds release, installs ~/.local/bin/wink-cua
claude mcp add wink-cua -- ~/.local/bin/wink-cua
```

The easiest way is XNotch's **Computer Use** extension. It bundles a notarized `Wink.app`, adds its
server to Claude Code, Codex, Cursor, Antigravity, VS Code, Claude Desktop, Windsurf and Gemini CLI
with one click (or takes it out of them all again), and walks you through Wink's permissions.

To cut a notarized, stapled universal `Wink.app` (and `dist/Wink-<version>-macos-universal.zip`):

```bash
NOTARY_PROFILE=<notarytool profile> ./scripts/release.sh
```

## Permissions

Wink asks for **Accessibility** and **Screen Recording** once, for itself. macOS normally charges a
command-line tool's permissions to whichever app launched it, so every client (Terminal, Cursor, Claude
Desktop, …) would need its own grant. Instead `wink-cua` disclaims its launcher: it re-launches itself
as responsible for its own privacy decisions, with stdio passed straight through. Inside `Wink.app`
(bundle id `dev.wink.cua`) the grants belong to Wink and survive updates. `WINK_CUA_DISCLAIM=0` turns
this off, so the launching app's grants apply again.

- `wink-cua permissions` prints Wink's grants as JSON. `wink-cua permissions request accessibility` or
  `… request screen-recording` shows macOS's prompt.
- When a tool needs a permission Wink lacks, the tool says so and `wink-cua` posts
  `dev.wink.cua.permission.needed`. XNotch's Computer Use extension answers it by opening System
  Settings with its guide and Wink's icon to drag in.
- macOS may apply a new Screen Recording grant only to servers started after it. Restart the MCP
  server (in Claude Code, `/mcp`) if screenshots still fail.

Built from source and run outside `Wink.app`, the server has no bundle to hold its grants, so allow
Accessibility and Screen Recording for the app that launches it, or run it with `WINK_CUA_DISCLAIM=0`.
The process must run in an unlocked GUI session.

## Agent loop

```
get_app_state(app)                 → tree with [index] per element + screenshot
click(app, element_index)          → acts, waits for the UI to settle, returns only what changed
type_text / press_key / scroll / … → same: every action returns the settled diff
```

- **One round trip per step.** Actions return the settled UI diff (`observe=false` to skip), so agents
  rarely call `get_app_state` twice.
- **Stable indices.** An element keeps its number while it exists. Diffs list only `~` changed, `+` added
  and `- removed` elements, and all other indices stay valid.
- **Background by default.** Clicks use the accessibility press when available, and otherwise mouse
  events posted to the target process. Keyboard input goes to the target process after making its
  window key *inside that app* (the front app and window order are unchanged). Scrolling moves the
  scroll bar through accessibility. Pass `foreground=true` to activate the app and use real HID input
  for apps that ignore background input.
- `app` accepts a display name, bundle id or pid. Apps that aren't running are launched in the background.

| Tool | Purpose |
| --- | --- |
| `list_apps` | Running apps with bundle ids, pids, window counts |
| `get_app_state` | Tree of the focused (or `window=`) window plus menu bar, and a JPEG screenshot; a diff on repeat calls |
| `click` | `element_index`, or `x`/`y` in screenshot pixels; `mouse_button`, `click_count` |
| `type_text` | Unicode typing into the focused element or `element_index` |
| `paste` | Clipboard insert for long text; the clipboard is restored |
| `press_key` | Chords: `cmd+s`, `shift+Tab`, `Return`, `KP_Enter`; space-separate several |
| `set_value` | Direct AX value for fields, sliders, steppers |
| `perform_action` | Secondary AX actions listed on an element (`ShowMenu`, `Raise`, `Increment`, …) |
| `scroll` | Element, point or window; `direction`, `pages` |
| `drag` | Between elements or screenshot points |

## Agent cursor

The agent pointer is drawn in a click-through overlay owned by the server process. It is our own
design, not the system cursor, and it never moves the user's real pointer.

- It is a navigation-style arrow: a black body with a light grey inner rim and a white outer rim,
  and a soft lavender halo behind it.

- It glides along a gently arced path. The duration scales with distance, and the pointer leans
  into the motion with a small settle overshoot. Short hops get a squash-and-stretch.
- Moves are interruptible. A new target starts from wherever the pointer currently is.
- Clicks land with a press squash and a ripple at the hotspot (purple for right clicks, a double
  ripple for double clicks). Typing and scrolling pulse the glow.
- By default the overlay is ordered **just above the target window**. If another window covers the
  target, it covers the cursor too. Set `WINK_CUA_CURSOR_LEVEL=top` to always draw it on top.
- It fades out after about 2.6 s idle. The animation never delays the action, because input is
  dispatched immediately and the effect plays when the pointer arrives.
- `WINK_CUA_CURSOR=0` disables it.

## Session events

`wink-cua` tells other apps when an agent starts and stops driving the Mac, so a companion can show
it. XNotch's Computer Use extension uses them to open the notch's eyes and keep them roughly on the
agent cursor. They are distributed notifications with plist user info:

| Notification | User info |
| --- | --- |
| `dev.wink.cua.session.start` | `session`, `pid`, `client` (the launching process: `claude`, `codex`, …), `app` |
| `dev.wink.cua.session.action` | `session`, `pid`, `tool`, `app`, `bundleID`, `x`/`y` when the cursor moves, `windowX`/`windowY` when a window is read |
| `dev.wink.cua.session.end` | `session`, `pid`, `reason` (`idle` or `exit`) |
| `dev.wink.cua.permission.needed` | `permission` (`accessibility` or `screenRecording`), `pid`, `client`, `app` (the `Wink.app` path) |

Points are AppKit screen coordinates (origin at the bottom left of the main display). A session starts
with the first tool call and ends `WINK_CUA_SESSION_IDLE` seconds (default 20) after the last one, or
when the server exits. `WINK_CUA_EVENTS=0` turns the events off.

## Performance

Measured on the same Mac and Calculator window, with a persistent MCP process and no model in the loop.
Sky is OpenAI's computer-use runtime (Codex Computer Use) 0.7.8, and Wink is stock `wink mcp`
4.9.6. Both were measured earlier with the same task (`7 + 8 =`).

| | Sky 0.7.8 | Wink 4.9.6 | **wink-cua** |
| --- | ---: | ---: | ---: |
| Click dispatch | 27 ms | 893 ms (and an MCP error) | **~13 ms** |
| Click + updated state | 501 ms (two calls) | 1,462 ms (two calls) | **~235 ms (one call, settled diff)** |
| Warm diff, no image | 72 ms (diff + image) | 95 ms (AX only) | **~38 ms** |
| Warm full state + screenshot | 71 ms | 476 ms | ~100 ms |
| `7 + 8 =` (4 clicks) | 2.0 s | 5.9 s | **~0.95 s** |

Reproduce with `node scripts/bench-calculator.mjs .build/release/wink-cua 5`. Small local
samples are not a general benchmark.

## Debugging

```bash
wink-cua call list_apps
wink-cua call get_app_state '{"app":"Calculator","screenshot":false}'
node scripts/mcp-steps.mjs .build/release/wink-cua '[["get_app_state",{"app":"Calculator"}],["click",{"app":"Calculator","element_index":"$id:Seven"}]]'
```

`WINK_CUA_DEBUG=1` logs the overlay window id (capture just the overlay with `screencapture -l <id>`).

## Known limits

- Some apps (notably Chromium-based browsers and games) ignore background mouse events for coordinate
  clicks. Prefer `element_index` (AX press) or `foreground=true`.
- Wheel-based scrolling of non-AX scroll views in background apps isn't supported. AX scroll bars are used.
- When the screen is locked, app UI isn't accessible and `get_app_state` reports that.
