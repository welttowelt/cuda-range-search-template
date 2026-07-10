#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CPU="$ROOT/build/cpu-reference"
DRIVER="$ROOT/scripts/search-driver.sh"

"$ROOT/scripts/build-cpu.sh" >/dev/null
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM

"$CPU" 100 5000 987654321 8 >"$tmp/direct" 2>"$tmp/direct-summary"
SEARCH_BIN="$CPU" SEARCH_RUN_DIR="$tmp/run" \
  "$DRIVER" 100 5000 317 3 987654321 8 \
  >"$tmp/partitioned" 2>"$tmp/partitioned-summary"
diff -u "$tmp/direct" "$tmp/partitioned"
grep -q '^MANIFEST_OK start=100 count=5000 ' "$tmp/partitioned-summary"

first_output="$(find "$tmp/run/chunks" -name '*.out' | sort | head -1)"
printf 'CORRUPTION\n' >>"$first_output"
binary_sha="$(shasum -a 256 "$CPU" | awk '{print $1}')"
set +e
"$ROOT/scripts/verify-manifest.sh" "$tmp/run" 100 5000 987654321 8 "$binary_sha" \
  >"$tmp/corrupt-result" 2>"$tmp/corrupt-error"
corrupt_rc="$?"
set -e
[[ "$corrupt_rc" -ne 0 ]]
grep -q 'output hash mismatch' "$tmp/corrupt-error"

set +e
"$CPU" 0 100 0 1 1 >"$tmp/capacity-output" 2>"$tmp/capacity-error"
capacity_rc="$?"
set -e
[[ "$capacity_rc" -eq 75 ]]
[[ ! -s "$tmp/capacity-output" ]]
grep -q '^CAPACITY_ERROR ' "$tmp/capacity-error"

printf 'test_reference=pass\n'
