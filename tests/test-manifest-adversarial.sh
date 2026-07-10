#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRIVER="$ROOT/scripts/search-driver.sh"
VERIFY="$ROOT/scripts/verify-manifest.sh"
FAKE="$ROOT/tests/fake-search.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM
binary_sha="$(shasum -a 256 "$FAKE" | awk '{print $1}')"

make_run() {
  local name="$1"
  SEARCH_BIN="$FAKE" SEARCH_RUN_DIR="$tmp/$name" \
    "$DRIVER" 100 23 4 3 19 6 >"$tmp/$name.out" 2>"$tmp/$name.err"
}

expect_manifest_failure() {
  local name="$1" pattern="$2"
  set +e
  "$VERIFY" "$tmp/$name" 100 23 19 6 "$binary_sha" \
    >"$tmp/$name.verify.out" 2>"$tmp/$name.verify.err"
  local rc="$?"
  set -e
  [[ "$rc" -eq 75 ]]
  grep -q "$pattern" "$tmp/$name.verify.err"
}

make_run missing-metadata
rm "$(find "$tmp/missing-metadata/chunks" -name '*.tsv' | sort | sed -n '2p')"
expect_manifest_failure missing-metadata 'gap_or_overlap\|incomplete coverage'

make_run overlap
first_meta="$(find "$tmp/overlap/chunks" -name '*.tsv' | sort | sed -n '1p')"
cp "$first_meta" "$tmp/overlap/chunks/duplicate.tsv"
expect_manifest_failure overlap 'gap_or_overlap'

make_run wrong-binary
first_meta="$(find "$tmp/wrong-binary/chunks" -name '*.tsv' | sort | sed -n '1p')"
awk -F '\t' 'BEGIN { OFS="\t" } NR == 1 { $7="0000000000000000000000000000000000000000000000000000000000000000" } { print }' \
  "$first_meta" >"$first_meta.part"
mv "$first_meta.part" "$first_meta"
expect_manifest_failure wrong-binary 'run identity mismatch'

make_run corrupt-output
first_output="$(find "$tmp/corrupt-output/chunks" -name '*.out' | sort | sed -n '1p')"
printf 'CORRUPTION\n' >>"$first_output"
expect_manifest_failure corrupt-output 'output hash mismatch'

make_run malformed-result
first_output="$(find "$tmp/malformed-result/chunks" -name '*.out' | sort | sed -n '1p')"
printf 'MATCH value=not-a-number\n' >>"$first_output"
output_sha="$(shasum -a 256 "$first_output" | awk '{print $1}')"
first_meta="${first_output%.out}.tsv"
awk -F '\t' -v sha="$output_sha" 'BEGIN { OFS="\t" } NR == 1 { $8=sha; $9=$9+1 } { print }' \
  "$first_meta" >"$first_meta.part"
mv "$first_meta.part" "$first_meta"
expect_manifest_failure malformed-result 'invalid or out-of-range result line'

make_run arithmetic-injection
first_meta="$(find "$tmp/arithmetic-injection/chunks" -name '*.tsv' | sort | sed -n '1p')"
injection_marker="$tmp/arithmetic-was-evaluated"
awk -F '\t' -v payload="BASH_VERSINFO[\$(touch $injection_marker)]" \
  'BEGIN { OFS="\t" } NR == 1 { $2=payload } { print }' \
  "$first_meta" >"$first_meta.part"
mv "$first_meta.part" "$first_meta"
expect_manifest_failure arithmetic-injection 'invalid numeric or hash field'
[[ ! -e "$injection_marker" ]]

make_run wrapped-count
first_meta="$(find "$tmp/wrapped-count/chunks" -name '*.tsv' | sort | sed -n '1p')"
awk -F '\t' 'BEGIN { OFS="\t" } NR == 1 { $2="18446744073709551619" } { print }' \
  "$first_meta" >"$first_meta.part"
mv "$first_meta.part" "$first_meta"
expect_manifest_failure wrapped-count 'invalid numeric or hash field'

make_run huge-invalid-output
first_output="$(find "$tmp/huge-invalid-output/chunks" -name '*.out' | sort | sed -n '1p')"
awk 'BEGIN { for (i=1; i<=200000; i++) print "BAD value=" i }' >"$first_output"
output_sha="$(shasum -a 256 "$first_output" | awk '{print $1}')"
first_meta="${first_output%.out}.tsv"
awk -F '\t' -v sha="$output_sha" 'BEGIN { OFS="\t" } NR == 1 { $8=sha; $9=0 } { print }' \
  "$first_meta" >"$first_meta.part"
mv "$first_meta.part" "$first_meta"
expect_manifest_failure huge-invalid-output 'invalid or out-of-range result line'

make_run snapshot-race
expected_snapshot="$tmp/snapshot-race.expected"
cat "$tmp/snapshot-race/chunks"/*.out | sort -t= -k2,2n -u >"$expected_snapshot"
first_output="$(find "$tmp/snapshot-race/chunks" -name '*.out' | sort | sed -n '1p')"
rm -f "$tmp/snapshot-race/manifest.tsv"
race_marker="$tmp/snapshot-race.changed"
(
  while [[ ! -f "$tmp/snapshot-race/manifest.tsv" ]]; do :; done
  printf 'MATCH value=999999999\n' >"$first_output"
  : >"$race_marker"
) &
race_pid="$!"
"$VERIFY" --emit "$tmp/snapshot-race" 100 23 19 6 "$binary_sha" \
  >"$tmp/snapshot-race.emitted" 2>"$tmp/snapshot-race.verify.err"
wait "$race_pid"
[[ -e "$race_marker" ]]
diff -u "$expected_snapshot" "$tmp/snapshot-race.emitted"
grep -q '^MANIFEST_OK ' "$tmp/snapshot-race.verify.err"

# A changed executable invalidates every prior chunk during resume. The driver
# must rerun the work instead of trusting metadata bound to the old binary.
cp "$FAKE" "$tmp/mutable-search.sh"
chmod +x "$tmp/mutable-search.sh"
invocations="$tmp/resume-invocations"
SEARCH_BIN="$tmp/mutable-search.sh" SEARCH_RUN_DIR="$tmp/stale-resume" \
  FAKE_INVOCATION_LOG="$invocations" "$DRIVER" 0 19 3 2 7 5 \
  >"$tmp/stale-first.out" 2>"$tmp/stale-first.err"
first_count="$(wc -l <"$invocations" | tr -d '[:space:]')"
printf '\n# identity change\n' >>"$tmp/mutable-search.sh"
SEARCH_BIN="$tmp/mutable-search.sh" SEARCH_RUN_DIR="$tmp/stale-resume" SEARCH_RESUME=1 \
  FAKE_INVOCATION_LOG="$invocations" "$DRIVER" 0 19 3 2 7 5 \
  >"$tmp/stale-second.out" 2>"$tmp/stale-second.err"
second_count="$(wc -l <"$invocations" | tr -d '[:space:]')"
[[ "$second_count" -eq $(( first_count * 2 )) ]]
diff -u "$tmp/stale-first.out" "$tmp/stale-second.out"

printf 'test_manifest_adversarial=pass cases=10\n'
