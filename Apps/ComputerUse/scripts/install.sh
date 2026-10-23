#!/bin/sh
# Build wink-cua and install it into Wink.app, with ~/.local/bin/wink-cua handing off to it.
# Accessibility and Screen Recording are granted to Wink.app (dev.wink.cua) once. Updating the binary
# inside the Developer ID-signed bundle keeps those grants; a loose binary outside the bundle has none.
#   APP     the Wink.app to update (default ~/Applications/Wink.app; create it with scripts/release.sh)
#   PREFIX  where the wink-cua launcher goes (default ~/.local/bin)
#   CODE_SIGN_IDENTITY  signing identity (default: the keychain's Developer ID Application identity)
set -eu
cd "$(dirname "$0")/.."
app="${APP:-$HOME/Applications/Wink.app}"
[ -d "$app/Contents/MacOS" ] || { echo "No Wink.app at $app. Build one with scripts/release.sh first." >&2; exit 1; }
identity=${CODE_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)}
[ -n "$identity" ] || { echo "No Developer ID Application identity; set CODE_SIGN_IDENTITY." >&2; exit 1; }
swift build -c release -j 4
install -m 755 .build/release/wink-cua "$app/Contents/MacOS/wink-cua"
codesign --force --sign "$identity" --options runtime "$app"
codesign --verify --strict "$app"
dest="${PREFIX:-$HOME/.local/bin}"
mkdir -p "$dest"
printf '#!/bin/sh\nexec "%s/Contents/MacOS/wink-cua" "$@"\n' "$app" > "$dest/wink-cua"
chmod 755 "$dest/wink-cua"
echo "Updated $app; $dest/wink-cua launches it."
"$dest/wink-cua" permissions
