#!/bin/zsh
# Build Wink.app, a universal, Developer ID-signed and notarized bundle around wink-cua, into dist/.
# usage: scripts/release.sh
#   CODE_SIGN_IDENTITY  signing identity (default: the keychain's Developer ID Application identity)
#   NOTARY_PROFILE      notarytool keychain profile; unset skips notarization
# The bundle gives Wink a privacy identity of its own: wink-cua disclaims its launcher, so macOS asks
# for Accessibility and Screen Recording once, for Wink, whichever agent app starts it.
set -euo pipefail
cd "${0:A:h:h}"
REPO=${0:A:h:h:h:h}

IDENTITY=${CODE_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)}
[[ -n "$IDENTITY" ]] || { echo "No Developer ID Application identity; set CODE_SIGN_IDENTITY." >&2; exit 1; }
VERSION=$(sed -n 's/.*"serverInfo".*"version": "\([^"]*\)".*/\1/p' Sources/WinkCUA/MCPServer.swift)
[[ -n "$VERSION" ]] || { echo "Can't read the version from MCPServer.swift." >&2; exit 1; }

swift build -c release --arch arm64 --arch x86_64
BIN=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/wink-cua
DIST=dist
APP="$DIST/Wink.app"
rm -rf "$DIST"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/wink-cua"

ICONSET="$DIST/Wink.iconset"
mkdir -p "$ICONSET"
cp "$REPO"/Apps/Mac/Wink/Assets.xcassets/AppIcon.appiconset/icon_*.png "$ICONSET/"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Wink.icns"
rm -rf "$ICONSET"
cp "$REPO/LICENSE" "$APP/Contents/Resources/LICENSE"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>dev.wink.cua</string>
    <key>CFBundleName</key><string>Wink</string>
    <key>CFBundleDisplayName</key><string>Wink</string>
    <key>CFBundleExecutable</key><string>wink-cua</string>
    <key>CFBundleIconFile</key><string>Wink</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHumanReadableCopyright</key><string>MIT License. Based on Peekaboo by Peter Steinberger.</string>
</dict>
</plist>
PLIST
codesign --force --sign "$IDENTITY" --options runtime --timestamp "$APP"
codesign --verify --strict --verbose=2 "$APP"

ARCHIVE="$DIST/Wink-$VERSION-macos-universal.zip"
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    ditto -c -k --keepParent "$APP" "$DIST/notarize.zip"
    xcrun notarytool submit "$DIST/notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait
    rm "$DIST/notarize.zip"
    xcrun stapler staple "$APP"
    spctl --assess --type execute --verbose=2 "$APP"
fi
ditto -c -k --keepParent "$APP" "$ARCHIVE"
shasum -a 256 "$ARCHIVE" | tee "$ARCHIVE.sha256"
echo "$APP"
