#!/bin/zsh
# Build a universal, Developer ID-signed and notarized wink-cua into dist/.
# usage: scripts/release.sh
#   CODE_SIGN_IDENTITY  signing identity (default: the keychain's Developer ID Application identity)
#   NOTARY_PROFILE      notarytool keychain profile; unset skips notarization
# A bare executable can't carry a stapled ticket: Gatekeeper looks the notarization up online.
set -euo pipefail
cd "${0:A:h:h}"

IDENTITY=${CODE_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)}
[[ -n "$IDENTITY" ]] || { echo "No Developer ID Application identity; set CODE_SIGN_IDENTITY." >&2; exit 1; }
VERSION=$(sed -n 's/.*"serverInfo".*"version": "\([^"]*\)".*/\1/p' Sources/WinkCUA/MCPServer.swift)
[[ -n "$VERSION" ]] || { echo "Can't read the version from MCPServer.swift." >&2; exit 1; }

swift build -c release --arch arm64 --arch x86_64
BIN=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/wink-cua
DIST=dist
rm -rf "$DIST"
mkdir -p "$DIST"
cp "$BIN" "$DIST/wink-cua"
codesign --force --sign "$IDENTITY" --options runtime --timestamp --identifier dev.wink.cua "$DIST/wink-cua"
codesign --verify --strict --verbose=2 "$DIST/wink-cua"

ARCHIVE="$DIST/wink-cua-$VERSION-macos-universal.zip"
ditto -c -k --keepParent "$DIST/wink-cua" "$ARCHIVE"
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    xcrun notarytool submit "$ARCHIVE" --keychain-profile "$NOTARY_PROFILE" --wait
    spctl --assess --type install --verbose=2 "$DIST/wink-cua" 2>&1 || true
fi
shasum -a 256 "$ARCHIVE" | tee "$ARCHIVE.sha256"
echo "$ARCHIVE"
