#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
version="$(/usr/bin/plutil -extract version raw -o - "$ROOT_DIR/package.json")"

assert_value() {
  local label="$1"
  local actual="$2"
  [[ "$actual" == "$version" ]] || {
    printf '%s version mismatch: expected %s, found %s\n' "$label" "$version" "${actual:-missing}" >&2
    exit 1
  }
}

assert_value 'root version.json' "$(/usr/bin/plutil -extract version raw -o - "$ROOT_DIR/version.json")"
assert_value 'CLI version.json' "$(/usr/bin/plutil -extract version raw -o - \
  "$ROOT_DIR/Apps/CLI/Sources/Resources/version.json")"
cli_plist="$ROOT_DIR/Apps/CLI/Sources/Resources/Info.plist"
test_host_plist="$ROOT_DIR/Apps/CLI/TestHost/Info.plist"
assert_value 'CLI CFBundleShortVersionString' "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$cli_plist")"
assert_value 'CLI CFBundleVersion' "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$cli_plist")"
display="$(/usr/libexec/PlistBuddy -c 'Print :WinkVersionDisplayString' "$cli_plist")"
assert_value 'CLI display version' "${display#Wink }"
assert_value 'TestHost CFBundleShortVersionString' \
  "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$test_host_plist")"
assert_value 'TestHost CFBundleVersion' "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$test_host_plist")"
mcp_version="$(/usr/bin/sed -n 's/.*static[[:space:]]*let[[:space:]]*current[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' \
  "$ROOT_DIR/Core/WinkCore/Sources/WinkAgentRuntime/MCP/WinkMCPVersion.swift")"
assert_value 'MCP server' "$mcp_version"

for project in \
  "$ROOT_DIR/Apps/Mac/Wink.xcodeproj/project.pbxproj" \
  "$ROOT_DIR/Apps/WinkInspector/Inspector.xcodeproj/project.pbxproj" \
  "$ROOT_DIR/Apps/Playground/Playground.xcodeproj/project.pbxproj"; do
  found=0
  while IFS= read -r marketing_version; do
    found=1
    assert_value "$(basename "$(dirname "$project")") MARKETING_VERSION" "$marketing_version"
  done < <(/usr/bin/sed -n 's/.*MARKETING_VERSION = \([^;[:space:]]*\);.*/\1/p' "$project")
  ((found == 1)) || {
    printf 'MARKETING_VERSION missing: %s\n' "$project" >&2
    exit 1
  }
done

printf '%s\n' "$version"
