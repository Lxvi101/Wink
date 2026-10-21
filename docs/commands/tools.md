---
summary: 'List the MCP tool catalog via wink tools'
read_when:
  - 'deciding which automation tool to call from agents or scripts'
  - 'debugging missing tool registrations'
---

# `wink tools`

`wink tools` prints the background-only MCP tool catalog that `wink mcp` exposes (Image, See, Click, Press, Action, Window, Browser, Inspect UI, etc.). `wink tools describe <name>` prints one tool's policy-aware JSON input schema for token-cheap, on-demand discovery. Tools with no background-safe form, such as `move`, are omitted. `drag` is included for bounded linear gestures inside one explicit fresh exact-window snapshot, with unverified, retry-unsafe dispatch. Mixed-capability tools retain their background-safe actions and describe which foreground shapes require a human-authorized foreground Agent or standalone CLI route. The public Agent catalog is a separate Shell-free surface; run `wink learn` for that exact guide. The CLI keeps `browser` as a dedicated wrapper and exposes AX-only inspection through `wink see --tree --no-screenshot`; run `wink --help` for the full CLI command list.

## Key options
| Flag | Description |
| --- | --- |
| `--no-sort` | Preserve registration order instead of alphabetizing every tool. |
| `--verbose` | Include each tool's description alongside its name. |
| `--json` | Emit `{tools:[…], count:n}` for machine parsing. |

## Subcommands

| Name | Purpose |
| --- | --- |
| `describe <tool-name>` | Print the tool name, abstract, and pretty JSON input schema. With `--json`, emit `{name, description, input_schema}`. Unknown names fail and list every valid name. |

## Implementation notes
- The command and MCP server both use `MCPToolCatalog`, so tool additions only need to be registered once.
- Tool schemas receive the same execution policy as the catalog. Background `app`/`window` descriptions omit focus and switch actions, while foreground-capable Agent schemas expose them under explicit human authority.
- Background clipboard discovery exposes only `get` and `save`. `set`, `clear`, and `restore` persistently change the user's shared clipboard state and require a foreground-authorized workflow; prefer exact targeted transactional paste when possible.
- Allow/deny filtering happens before formatting (`ToolFiltering.apply`), so the output matches MCP server behavior.
- Input-strategy availability filtering also runs before formatting, so action-only tools are hidden when the current policy cannot support them.
- The command runs locally by default because it only reports the static native catalog; use per-tool wrappers or an attached MCP client to execute tools.
- Because the command implements `RuntimeOptionsConfigurable`, it respects global `--json`/`--verbose` flags even when invoked from other commands (e.g., `wink learn` can embed the summaries verbatim).

## Examples
```bash
# Produce a JSON blob for an agent integration test
wink tools --json > /tmp/tools.json

# Fetch only the click tool's schema
wink tools describe click
wink tools describe verify_state --json
```

## Troubleshooting
- Verify Screen Recording + Accessibility permissions (`wink permissions status`).
- Confirm your process with `wink app list`, its exact window with `wink window list`, and current UI with `wink see` before rerunning.
- Re-run with `--json` or `--verbose` to surface detailed errors.
