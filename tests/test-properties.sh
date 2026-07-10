#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CPU="$ROOT/build/cpu-reference"
DRIVER="$ROOT/scripts/search-driver.sh"

"$ROOT/scripts/build-cpu.sh" >/dev/null
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM

# Deterministic pseudo-random parameter matrix. Every partitioned result must
# be byte-identical to the single-process CPU reference result.
case_id=1
while [[ "$case_id" -le 24 ]]; do
  start=$(( (case_id * 7919 + case_id * case_id * 17) % 50000 ))
  count=$(( 37 + (case_id * 1543) % 1800 ))
  chunk=$(( 1 + (case_id * 97) % 311 ))
  workers=$(( 1 + (case_id * 7) % 6 ))
  seed=$(( (case_id * 104729 + 12345) % 2000000000 ))
  bits=$(( 3 + (case_id * 5) % 11 ))
  case_dir="$tmp/case-$case_id"
  mkdir -p "$case_dir"

  "$CPU" "$start" "$count" "$seed" "$bits" \
    >"$case_dir/direct" 2>"$case_dir/direct-summary"
  SEARCH_BIN="$CPU" SEARCH_RUN_DIR="$case_dir/run" \
    "$DRIVER" "$start" "$count" "$chunk" "$workers" "$seed" "$bits" \
    >"$case_dir/partitioned" 2>"$case_dir/partitioned-summary"

  diff -u "$case_dir/direct" "$case_dir/partitioned"
  grep -q "^MANIFEST_OK start=$start count=$count " "$case_dir/partitioned-summary"
  grep -q "^COVERAGE_OK start=$start count=$count workers=" "$case_dir/partitioned-summary"
  case_id=$(( case_id + 1 ))
done

printf 'test_properties=pass cases=24\n'
