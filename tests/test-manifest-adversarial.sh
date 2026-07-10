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
awk -F '\t' 'BEGIN { OFS="\t" } NR == 1 { $7="deadbeef" } { print }' \
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
expect_manifest_failure malformed-result 'invalid result line'

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

printf 'test_manifest_adversarial=pass cases=6\n'
