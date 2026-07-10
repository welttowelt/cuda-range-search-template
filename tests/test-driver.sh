#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRIVER="$ROOT/scripts/search-driver.sh"
FAKE="$ROOT/tests/fake-search.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM

SEARCH_BIN="$FAKE" "$DRIVER" 0 10 2 2 0 20 \
  >"$tmp/results" 2>"$tmp/coverage"
printf '%s\n' \
  'MATCH value=0' \
  'MATCH value=3' \
  'MATCH value=6' \
  'MATCH value=9' >"$tmp/expected"
diff -u "$tmp/expected" "$tmp/results"
grep -q '^MANIFEST_OK start=0 count=10 chunks=6 matches=4 ' "$tmp/coverage"
grep -q '^COVERAGE_OK start=0 count=10 workers=2 chunk=2 ' "$tmp/coverage"

set +e
FAKE_FAIL_AT=2 SEARCH_BIN="$FAKE" "$DRIVER" 0 10 2 2 0 20 \
  >"$tmp/failed-results" 2>"$tmp/failed-errors"
failure_rc="$?"
set -e
[[ "$failure_rc" -ne 0 ]]
[[ ! -s "$tmp/failed-results" ]]
grep -q 'SEARCH_FAILED' "$tmp/failed-errors"
grep -q 'synthetic worker failure' "$tmp/failed-errors"

set +e
SEARCH_BIN="$FAKE" "$DRIVER" 9223372036854775807 2 1 1 0 20 \
  >"$tmp/overflow-results" 2>"$tmp/overflow-errors"
overflow_rc="$?"
set -e
[[ "$overflow_rc" -eq 64 ]]
grep -q 'range exclusive end exceeds' "$tmp/overflow-errors"

set +e
SEARCH_BIN="$FAKE" "$DRIVER" 1 9223372036854775807 1 4 0 20 \
  >"$tmp/end-overflow-results" 2>"$tmp/end-overflow-errors"
end_overflow_rc="$?"
set -e
[[ "$end_overflow_rc" -eq 64 ]]
[[ ! -s "$tmp/end-overflow-results" ]]
grep -q 'range exclusive end exceeds' "$tmp/end-overflow-errors"

run_dir="$tmp/resume-run"
invocations="$tmp/invocations"
FAKE_INVOCATION_LOG="$invocations" SEARCH_RUN_DIR="$run_dir" SEARCH_BIN="$FAKE" \
  "$DRIVER" 0 10 2 2 0 20 >"$tmp/resume-first" 2>"$tmp/resume-first-errors"
first_invocations="$(wc -l <"$invocations" | tr -d '[:space:]')"
FAKE_FAIL_AT=0 FAKE_INVOCATION_LOG="$invocations" SEARCH_RUN_DIR="$run_dir" \
  SEARCH_RESUME=1 SEARCH_BIN="$FAKE" "$DRIVER" 0 10 2 2 0 20 \
  >"$tmp/resume-second" 2>"$tmp/resume-second-errors"
second_invocations="$(wc -l <"$invocations" | tr -d '[:space:]')"
[[ "$first_invocations" == "$second_invocations" ]]
diff -u "$tmp/resume-first" "$tmp/resume-second"
grep -q 'RESUME_OK' "$run_dir/gpu-0.err"
grep -q '^start[[:space:]]count[[:space:]]end' "$run_dir/manifest.tsv"

printf 'MATCH value=123456789\n' >"$run_dir/chunks/orphan.out"
set +e
SEARCH_RUN_DIR="$run_dir" SEARCH_RESUME=1 SEARCH_BIN="$FAKE" \
  "$DRIVER" 0 10 2 2 0 20 >"$tmp/orphan-results" 2>"$tmp/orphan-errors"
orphan_rc="$?"
set -e
[[ "$orphan_rc" -eq 75 ]]
[[ ! -s "$tmp/orphan-results" ]]
grep -q 'uncertified output file present: orphan.out' "$tmp/orphan-errors"

printf 'test_driver=pass\n'
