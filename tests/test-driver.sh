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

near_max_run="$tmp/near-max-run"
near_max_invocations="$tmp/near-max-invocations"
FAKE_INVOCATION_LOG="$near_max_invocations" SEARCH_RUN_DIR="$near_max_run" SEARCH_BIN="$FAKE" \
  "$DRIVER" 9223372036854775797 10 10 3 0 20 \
  >"$tmp/near-max-results" 2>"$tmp/near-max-errors"
[[ "$(wc -l <"$near_max_invocations" | tr -d '[:space:]')" -eq 3 ]]
awk -F '\t' '
  $1 !~ /^[0-9]+$/ || $2 !~ /^[0-9]+$/ || $1 < 0 || $2 <= 0 { exit 1 }
  { total += $2 }
  END { exit(total == 10 ? 0 : 1) }
' "$near_max_invocations"
grep -q '^MANIFEST_OK start=9223372036854775797 count=10 ' "$tmp/near-max-errors"

capacity_run="$tmp/capacity-run"
capacity_invocations="$tmp/capacity-invocations"
MATCH_CAPACITY=17 FAKE_INVOCATION_LOG="$capacity_invocations" SEARCH_RUN_DIR="$capacity_run" SEARCH_BIN="$FAKE" \
  "$DRIVER" 0 19 3 2 7 5 >"$tmp/capacity-first" 2>"$tmp/capacity-first-errors"
first_capacity_calls="$(wc -l <"$capacity_invocations" | tr -d '[:space:]')"
awk -F '\t' '$3 != 17 { exit 1 }' "$capacity_invocations"
awk -F '\t' 'NR > 1 && $12 != 17 { exit 1 }' "$capacity_run/manifest.tsv"
MATCH_CAPACITY=17 FAKE_INVOCATION_LOG="$capacity_invocations" SEARCH_RUN_DIR="$capacity_run" \
  SEARCH_RESUME=1 SEARCH_BIN="$FAKE" "$DRIVER" 0 19 3 2 7 5 \
  >"$tmp/capacity-second" 2>"$tmp/capacity-second-errors"
[[ "$(wc -l <"$capacity_invocations" | tr -d '[:space:]')" -eq "$first_capacity_calls" ]]
MATCH_CAPACITY=18 FAKE_INVOCATION_LOG="$capacity_invocations" SEARCH_RUN_DIR="$capacity_run" \
  SEARCH_RESUME=1 SEARCH_BIN="$FAKE" "$DRIVER" 0 19 3 2 7 5 \
  >"$tmp/capacity-third" 2>"$tmp/capacity-third-errors"
[[ "$(wc -l <"$capacity_invocations" | tr -d '[:space:]')" -eq $(( first_capacity_calls * 2 )) ]]
awk -F '\t' 'NR > 1 && $12 != 18 { exit 1 }' "$capacity_run/manifest.tsv"
diff -u "$tmp/capacity-first" "$tmp/capacity-third"

set +e
MATCH_CAPACITY=0 SEARCH_BIN="$FAKE" "$DRIVER" 0 10 2 1 0 20 \
  >"$tmp/capacity-zero.out" 2>"$tmp/capacity-zero.err"
capacity_zero_rc="$?"
MATCH_CAPACITY=4294967296 SEARCH_BIN="$FAKE" "$DRIVER" 0 10 2 1 0 20 \
  >"$tmp/capacity-large.out" 2>"$tmp/capacity-large.err"
capacity_large_rc="$?"
set -e
[[ "$capacity_zero_rc" -eq 64 && "$capacity_large_rc" -eq 64 ]]

mutable_bin="$tmp/midrun-search.sh"
cp "$FAKE" "$mutable_bin"
chmod +x "$mutable_bin"
before_mutation_sha="$(shasum -a 256 "$mutable_bin" | awk '{print $1}')"
block_dir="$tmp/midrun-block"
FAKE_BLOCK_DIR="$block_dir" SEARCH_BIN="$mutable_bin" SEARCH_RUN_DIR="$tmp/midrun" \
  "$DRIVER" 0 10 10 1 0 20 >"$tmp/midrun.out" 2>"$tmp/midrun.err" &
midrun_pid="$!"
tries=0
while [[ ! -e "$block_dir/ready" && "$tries" -lt 500 ]]; do
  sleep 0.01
  tries=$(( tries + 1 ))
done
[[ -e "$block_dir/ready" ]]
printf '\n# source changed while snapshot runs\n' >>"$mutable_bin"
: >"$block_dir/release"
wait "$midrun_pid"
grep -q "$before_mutation_sha" "$tmp/midrun/manifest.tsv"
grep -q '^MANIFEST_OK ' "$tmp/midrun.err"

printf 'test_driver=pass cases=policy-resume-nearmax-capacity-snapshot\n'
