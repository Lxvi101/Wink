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

Grant **Accessibility** and **Screen Recording** to the app that launches the server (your terminal,
Claude Code, Codex, …). The process must run in an unlocked GUI session.

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
