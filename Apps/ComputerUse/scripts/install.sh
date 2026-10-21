#!/bin/sh
# Build wink-cua in release mode and install it to ~/.local/bin (override with PREFIX=/some/bin).
set -eu
cd "$(dirname "$0")/.."
swift build -c release
dest="${PREFIX:-$HOME/.local/bin}"
mkdir -p "$dest"
install -m 755 .build/release/wink-cua "$dest/wink-cua"
echo "Installed $dest/wink-cua"
echo "Add to Claude Code: claude mcp add wink-cua -- $dest/wink-cua"
echo "Add to Codex:       codex mcp add wink-cua -- $dest/wink-cua"
