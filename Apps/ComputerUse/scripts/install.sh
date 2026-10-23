#!/bin/sh
# Build wink-cua in release mode and install it to ~/.local/bin (override with PREFIX=/some/bin).
set -eu
cd "$(dirname "$0")/.."
swift build -c release -j 4
dest="${PREFIX:-$HOME/.local/bin}"
mkdir -p "$dest"
install -m 755 .build/release/wink-cua "$dest/wink-cua"
# macOS ties Accessibility/Screen Recording grants of an ad-hoc signed binary to that exact build, so
# every reinstall silently lost them. Signed with a stable identity, the grants survive rebuilds.
identity=${CODE_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)}
if [ -n "$identity" ]; then
  codesign --force --sign "$identity" --identifier wink-cua "$dest/wink-cua"
  echo "Signed with $identity"
else
  echo "No Developer ID identity: ad-hoc signed, so permissions must be granted again after each install."
fi
echo "Installed $dest/wink-cua"
echo "Add to Claude Code: claude mcp add wink-cua -- $dest/wink-cua"
echo "Add to Codex:       codex mcp add wink-cua -- $dest/wink-cua"
