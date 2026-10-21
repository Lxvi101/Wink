#!/bin/sh
# Build peekaboo-cua in release mode and install it to ~/.local/bin (override with PREFIX=/some/bin).
set -eu
cd "$(dirname "$0")/.."
swift build -c release
dest="${PREFIX:-$HOME/.local/bin}"
mkdir -p "$dest"
install -m 755 .build/release/peekaboo-cua "$dest/peekaboo-cua"
echo "Installed $dest/peekaboo-cua"
echo "Add to Claude Code: claude mcp add peekaboo-cua -- $dest/peekaboo-cua"
echo "Add to Codex:       codex mcp add peekaboo-cua -- $dest/peekaboo-cua"
