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
grep -q '^COVERAGE_OK start=0 count=10 workers=2 chunk=2$' "$tmp/coverage"

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
grep -q 'range exceeds' "$tmp/overflow-errors"

printf 'test_driver=pass\n'
