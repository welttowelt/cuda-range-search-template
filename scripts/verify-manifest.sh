#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

[[ $# -eq 6 ]] || {
  printf 'usage: %s RUN_DIR START COUNT SEED ZERO_BITS BINARY_SHA256\n' "$0" >&2
  exit 64
}

run_dir="$1"
expected_start="$2"
expected_count="$3"
expected_seed="$4"
expected_bits="$5"
expected_binary_sha="$6"
chunks_dir="$run_dir/chunks"

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

[[ -d "$chunks_dir" ]] || {
  printf 'MANIFEST_ERROR chunks directory missing: %s\n' "$chunks_dir" >&2
  exit 75
}

sorted="$(mktemp)"
normalized="$(mktemp)"
records="$(mktemp)"
certified_outputs="$(mktemp)"
trap 'rm -f "$sorted" "$normalized" "$records" "$certified_outputs"' EXIT INT TERM
find "$chunks_dir" -maxdepth 1 -type f -name '*.tsv' -print | sort >"$sorted"
[[ -s "$sorted" ]] || {
  printf 'MANIFEST_ERROR no chunk metadata found\n' >&2
  exit 75
}

cursor="$expected_start"
expected_end=$(( expected_start + expected_count ))
total_matches=0
chunk_count=0
: >"$normalized"
: >"$certified_outputs"
while IFS= read -r metadata; do
  cat "$metadata"
done <"$sorted" | sort -t $'\t' -k1,1n >"$records"

while IFS=$'\t' read -r chunk_start chunk_count_value chunk_end seed bits gpu \
  binary_sha output_sha matches status output_name extra; do
  [[ -z "${extra:-}" && "$status" == complete ]] || {
    printf 'MANIFEST_ERROR malformed metadata at start=%s\n' "${chunk_start:-unknown}" >&2
    exit 75
  }
  [[ "$gpu" =~ ^[0-9]+$ ]] || {
    printf 'MANIFEST_ERROR invalid GPU index at start=%s\n' "$chunk_start" >&2
    exit 75
  }
  [[ "$chunk_start" == "$cursor" ]] || {
    printf 'MANIFEST_ERROR gap_or_overlap expected_start=%s actual_start=%s\n' \
      "$cursor" "$chunk_start" >&2
    exit 75
  }
  (( chunk_count_value > 0 && chunk_end == chunk_start + chunk_count_value )) || {
    printf 'MANIFEST_ERROR invalid chunk bounds at start=%s\n' "$chunk_start" >&2
    exit 75
  }
  [[ "$seed" == "$expected_seed" && "$bits" == "$expected_bits" && \
     "$binary_sha" == "$expected_binary_sha" ]] || {
    printf 'MANIFEST_ERROR run identity mismatch at start=%s\n' "$chunk_start" >&2
    exit 75
  }
  [[ "$output_name" == "${chunk_start}-${chunk_count_value}.out" ]] || {
    printf 'MANIFEST_ERROR unexpected output name: %s\n' "$output_name" >&2
    exit 75
  }
  output="$chunks_dir/$output_name"
  [[ -f "$output" && "$(sha256_file "$output")" == "$output_sha" ]] || {
    printf 'MANIFEST_ERROR output hash mismatch: %s\n' "$output" >&2
    exit 75
  }
  if grep -Ev '^MATCH value=[0-9]+$' "$output" | grep -q .; then
    printf 'MANIFEST_ERROR invalid result line: %s\n' "$output" >&2
    exit 75
  fi
  actual_matches="$(grep -c '^MATCH value=' "$output" 2>/dev/null || true)"
  [[ "$actual_matches" == "$matches" ]] || {
    printf 'MANIFEST_ERROR match count mismatch: %s\n' "$output" >&2
    exit 75
  }
  sort -t= -k2,2n -u "$output" >"$output.sorted"
  if ! cmp -s "$output" "$output.sorted"; then
    rm -f "$output.sorted"
    printf 'MANIFEST_ERROR results are not sorted and unique: %s\n' "$output" >&2
    exit 75
  fi
  rm -f "$output.sorted"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$chunk_start" "$chunk_count_value" "$chunk_end" "$seed" "$bits" "$gpu" \
    "$binary_sha" "$output_sha" "$matches" "$status" "$output_name" >>"$normalized"
  printf '%s\n' "$output_name" >>"$certified_outputs"
  cursor="$chunk_end"
  total_matches=$(( total_matches + matches ))
  chunk_count=$(( chunk_count + 1 ))
done <"$records"

[[ "$cursor" == "$expected_end" ]] || {
  printf 'MANIFEST_ERROR incomplete coverage expected_end=%s actual_end=%s\n' \
    "$expected_end" "$cursor" >&2
  exit 75
}

while IFS= read -r output; do
  output_name="${output##*/}"
  if ! grep -Fqx "$output_name" "$certified_outputs"; then
    printf 'MANIFEST_ERROR uncertified output file present: %s\n' "$output_name" >&2
    exit 75
  fi
done < <(find "$chunks_dir" -maxdepth 1 -type f -name '*.out' -print | sort)

{
  printf 'start\tcount\tend\tseed\tzero_bits\tgpu\tbinary_sha256\toutput_sha256\tmatches\tstatus\toutput\n'
  cat "$normalized"
} >"$run_dir/manifest.tsv"

printf 'MANIFEST_OK start=%s count=%s chunks=%s matches=%s binary_sha256=%s\n' \
  "$expected_start" "$expected_count" "$chunk_count" "$total_matches" \
  "$expected_binary_sha"
