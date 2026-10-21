#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/wink-codesign-retry-test.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT

cat >"$TEST_DIR/codesign" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
count=0
[[ ! -f "$CODESIGN_TEST_COUNT" ]] || count="$(<"$CODESIGN_TEST_COUNT")"
count=$((count + 1))
printf '%s\n' "$count" >"$CODESIGN_TEST_COUNT"
if [[ "${CODESIGN_TEST_MODE:-transient}" == "transient" && "$count" -lt 3 ]]; then
  echo "fixture: A timestamp was expected but was not found." >&2
  exit 1
fi
if [[ "${CODESIGN_TEST_MODE:-transient}" == "permanent" ]]; then
  echo "fixture: signing identity missing" >&2
  exit 7
fi
echo "fixture: signed"
MOCK
chmod 700 "$TEST_DIR/codesign"

export MAC_RELEASE_CODESIGN_BIN="$TEST_DIR/codesign"
export CODESIGN_TIMESTAMP_RETRY_ATTEMPTS=3
export CODESIGN_TIMESTAMP_RETRY_DELAY_SECONDS=0
export CODESIGN_TEST_COUNT="$TEST_DIR/count"

"$ROOT_DIR/scripts/codesign-with-retry.sh" --timestamp=http://timestamp.apple.com/ts01 fixture
[[ "$(<"$CODESIGN_TEST_COUNT")" == "3" ]]

printf '0\n' >"$CODESIGN_TEST_COUNT"
export CODESIGN_TEST_MODE=permanent
permanent_rc=0
"$ROOT_DIR/scripts/codesign-with-retry.sh" --timestamp=http://timestamp.apple.com/ts01 fixture || permanent_rc=$?
[[ "$permanent_rc" == "7" ]]
[[ "$(<"$CODESIGN_TEST_COUNT")" == "1" ]]

echo "test-codesign-with-retry: ok"
