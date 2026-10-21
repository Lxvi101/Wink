---
summary: 'Install shell-native completions via wink completions'
read_when:
  - 'setting up tab completion for the Wink CLI'
  - 'debugging missing or stale zsh/bash/fish completions'
---

# `wink completions`

`wink completions` prints a shell script that enables tab completion for the
Wink CLI. The command derives its command tree, flags, aliases, and
descriptions from Commander metadata at runtime, so completions stay in sync
with the shipped CLI surface.

## Key options
| Flag | Description |
| --- | --- |
| `[shell]` | Optional shell name or shell path. Accepts `zsh`, `bash`, `fish`, or values like `/bin/zsh`. Defaults to the current `$SHELL`, then falls back to `zsh`. |

## Implementation notes
- The command renders from `CommanderRegistryBuilder.buildDescriptors()` rather than maintaining handwritten completion tables.
- Runtime aliases such as `--json-output` and `--log-level` are included because completion metadata is extracted from the fully normalized Commander signature.
- `wink help` is exposed in completions as a synthetic command tree so users can tab through `wink help <command> ...` just like the real CLI.
- The emitted script is shell-specific, but the command metadata is shared across zsh, bash, and fish via a single completion document.

## Examples
```bash
# Recommended: use the current login shell path directly
eval "$(wink completions $SHELL)"

# Explicit zsh
eval "$(wink completions zsh)"

# Explicit bash
eval "$(wink completions bash)"

# Fish uses source instead of eval
wink completions fish | source
```

## Persistent install

Add one of the following snippets to your shell startup file:

```bash
# ~/.zshrc
eval "$(wink completions $SHELL)"

# ~/.bashrc or ~/.bash_profile
eval "$(wink completions bash)"
```

```fish
# ~/.config/fish/config.fish
wink completions fish | source
```

## Troubleshooting
- Re-run the setup snippet after upgrading Wink so your shell reloads the latest generated script.
- If `$SHELL` points to a wrapper or unsupported shell, pass an explicit value such as `zsh`, `bash`, or `fish`.
- Verify the command resolves in your current session (`command -v wink`) before sourcing the generated script.
- Run `wink completions <shell> > /tmp/wink.<shell>` and inspect the file if your shell reports a syntax error.
