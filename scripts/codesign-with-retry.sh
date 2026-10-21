#!/usr/bin/env bash
set -euo pipefail

CODESIGN_BIN="${MAC_RELEASE_CODESIGN_BIN:-codesign}"
MAX_ATTEMPTS="${CODESIGN_TIMESTAMP_RETRY_ATTEMPTS:-8}"
BASE_DELAY_SECONDS="${CODESIGN_TIMESTAMP_RETRY_DELAY_SECONDS:-5}"

[[ "$MAX_ATTEMPTS" =~ ^[1-9][0-9]*$ ]] || {
  echo "CODESIGN_TIMESTAMP_RETRY_ATTEMPTS must be a positive integer" >&2
  exit 2
}
[[ "$BASE_DELAY_SECONDS" =~ ^[0-9]+$ ]] || {
  echo "CODESIGN_TIMESTAMP_RETRY_DELAY_SECONDS must be a nonnegative integer" >&2
  exit 2
}

output_file="$(mktemp "${TMPDIR:-/tmp}/wink-codesign.XXXXXX")"
trap 'rm -f "$output_file"' EXIT

attempt=1
while true; do
  : >"$output_file"
  command_rc=0
  "$CODESIGN_BIN" "$@" >"$output_file" 2>&1 || command_rc=$?
  cat "$output_file" >&2
  if [[ "$command_rc" -eq 0 ]]; then
    exit 0
  fi

  if ! grep -Eiq \
    'A timestamp was expected but was not found|timestamp service is not available' \
    "$output_file"; then
    exit "$command_rc"
  fi
  if [[ "$attempt" -ge "$MAX_ATTEMPTS" ]]; then
    echo "codesign timestamp retry limit reached after $attempt attempts" >&2
    exit "$command_rc"
  fi

  delay=$((BASE_DELAY_SECONDS * attempt))
  ((delay <= 30)) || delay=30
  echo "Transient Apple timestamp failure; retrying codesign in ${delay}s (attempt $((attempt + 1))/$MAX_ATTEMPTS)" >&2
  sleep "$delay"
  attempt=$((attempt + 1))
done
