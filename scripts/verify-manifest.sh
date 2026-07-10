#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

emit_results=0
if [[ "${1:-}" == "--emit" ]]; then
  emit_results=1
  shift
fi

[[ $# -eq 6 || $# -eq 7 ]] || {
  printf 'usage: %s [--emit] RUN_DIR START COUNT SEED ZERO_BITS BINARY_SHA256 [MATCH_CAPACITY]\n' "$0" >&2
  exit 64
}

run_dir="$1"
expected_start="$2"
expected_count="$3"
expected_seed="$4"
expected_bits="$5"
expected_binary_sha="$6"
expected_capacity="${7:-4096}"
chunks_dir="$run_dir/chunks"

is_canonical_uint() {
  [[ "${1:-}" =~ ^(0|[1-9][0-9]*)$ ]]
}

decimal_le() {
  local left="$1" right="$2" index left_digit right_digit
  if [[ "${#left}" -ne "${#right}" ]]; then
    (( ${#left} < ${#right} ))
    return
  fi
  for ((index = 0; index < ${#left}; index++)); do
    left_digit="${left:index:1}"
    right_digit="${right:index:1}"
    if (( 10#$left_digit < 10#$right_digit )); then return 0; fi
    if (( 10#$left_digit > 10#$right_digit )); then return 1; fi
  done
  return 0
}

is_i63() {
  is_canonical_uint "${1:-}" && decimal_le "$1" "9223372036854775807"
}

for value in "$expected_start" "$expected_count" "$expected_seed"; do
  is_i63 "$value" || {
    printf 'MANIFEST_ERROR invalid expected run identity\n' >&2
    exit 64
  }
done
is_canonical_uint "$expected_bits" && (( expected_bits >= 1 && expected_bits <= 63 )) \
  && is_canonical_uint "$expected_capacity" && (( expected_capacity > 0 )) \
  && decimal_le "$expected_capacity" "4294967295" \
  && [[ "$expected_binary_sha" =~ ^[0-9a-f]{64}$ ]] || {
  printf 'MANIFEST_ERROR invalid expected run identity\n' >&2
  exit 64
}
(( expected_count > 0 && expected_count <= 9223372036854775807 - expected_start )) || {
  printf 'MANIFEST_ERROR expected range exclusive end exceeds 2^63-1\n' >&2
  exit 64
}

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
certified_results="$(mktemp)"
snapshot=""
sorted_output=""
trap 'rm -f "$sorted" "$normalized" "$records" "$certified_outputs" "$certified_results" "${snapshot:-}" "${sorted_output:-}"' EXIT INT TERM
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
: >"$certified_results"
while IFS= read -r metadata; do
  cat "$metadata"
done <"$sorted" | sort -t $'\t' -k1,1n >"$records"

while IFS=$'\t' read -r chunk_start chunk_count_value chunk_end seed bits gpu \
  binary_sha output_sha matches status output_name capacity extra; do
  [[ -z "${extra:-}" && "$status" == complete ]] || {
    printf 'MANIFEST_ERROR malformed metadata at start=%s\n' "${chunk_start:-unknown}" >&2
    exit 75
  }
  if ! is_i63 "$chunk_start" || ! is_i63 "$chunk_count_value" || \
     ! is_i63 "$chunk_end" || ! is_i63 "$seed" || ! is_i63 "$gpu" || \
     ! is_i63 "$matches" || ! is_canonical_uint "$bits" || \
     ! is_canonical_uint "$capacity" || \
     ! decimal_le "$capacity" "4294967295" || \
     [[ ! "$binary_sha" =~ ^[0-9a-f]{64}$ ]] || \
     [[ ! "$output_sha" =~ ^[0-9a-f]{64}$ ]]; then
    printf 'MANIFEST_ERROR invalid numeric or hash field at start=%s\n' "${chunk_start:-unknown}" >&2
    exit 75
  fi
  (( chunk_count_value > 0 && capacity > 0 && \
     chunk_count_value <= 9223372036854775807 - chunk_start )) || {
    printf 'MANIFEST_ERROR invalid chunk bounds at start=%s\n' "$chunk_start" >&2
    exit 75
  }
  [[ "$chunk_start" == "$cursor" ]] || {
    printf 'MANIFEST_ERROR gap_or_overlap expected_start=%s actual_start=%s\n' \
      "$cursor" "$chunk_start" >&2
    exit 75
  }
  (( chunk_end == chunk_start + chunk_count_value )) || {
    printf 'MANIFEST_ERROR invalid chunk bounds at start=%s\n' "$chunk_start" >&2
    exit 75
  }
  [[ "$seed" == "$expected_seed" && "$bits" == "$expected_bits" && \
     "$binary_sha" == "$expected_binary_sha" && "$capacity" == "$expected_capacity" ]] || {
    printf 'MANIFEST_ERROR run identity mismatch at start=%s\n' "$chunk_start" >&2
    exit 75
  }
  [[ "$output_name" == "${chunk_start}-${chunk_count_value}.out" ]] || {
    printf 'MANIFEST_ERROR unexpected output name: %s\n' "$output_name" >&2
    exit 75
  }
  output="$chunks_dir/$output_name"
  snapshot="$(mktemp)"
  [[ -f "$output" ]] && cp "$output" "$snapshot" || {
    printf 'MANIFEST_ERROR output missing or unreadable: %s\n' "$output" >&2
    exit 75
  }
  [[ "$(sha256_file "$snapshot")" == "$output_sha" ]] || {
    printf 'MANIFEST_ERROR output hash mismatch: %s\n' "$output" >&2
    exit 75
  }
  set +e
  actual_matches="$(awk -v start="$chunk_start" -v end="$chunk_end" '
    function canonical(value) { return value ~ /^(0|[1-9][0-9]*)$/ }
    function less(left, right) {
      if (length(left) != length(right)) return length(left) < length(right)
      return ("x" left) < ("x" right)
    }
    !/^MATCH value=[0-9]+$/ { exit 75 }
    {
      value = substr($0, 13)
      if (!canonical(value) || less(value, start) || !less(value, end)) exit 75
      count++
    }
    END { if (!failed) print count + 0 }
  ' "$snapshot")"
  result_rc="$?"
  set -e
  if [[ "$result_rc" -ne 0 ]]; then
    printf 'MANIFEST_ERROR invalid or out-of-range result line: %s\n' "$output" >&2
    exit 75
  fi
  [[ "$actual_matches" == "$matches" ]] || {
    printf 'MANIFEST_ERROR match count mismatch: %s\n' "$output" >&2
    exit 75
  }
  sorted_output="$(mktemp)"
  sort -t= -k2,2n -u "$snapshot" >"$sorted_output"
  if ! cmp -s "$snapshot" "$sorted_output"; then
    printf 'MANIFEST_ERROR results are not sorted and unique: %s\n' "$output" >&2
    exit 75
  fi
  cat "$snapshot" >>"$certified_results"
  rm -f "$snapshot" "$sorted_output"
  snapshot=""
  sorted_output=""
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$chunk_start" "$chunk_count_value" "$chunk_end" "$seed" "$bits" "$gpu" \
    "$binary_sha" "$output_sha" "$matches" "$status" "$output_name" "$capacity" >>"$normalized"
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
  printf 'start\tcount\tend\tseed\tzero_bits\tgpu\tbinary_sha256\toutput_sha256\tmatches\tstatus\toutput\tmatch_capacity\n'
  cat "$normalized"
} >"$run_dir/manifest.tsv"

if [[ "$emit_results" -eq 1 ]]; then
  printf 'MANIFEST_OK start=%s count=%s chunks=%s matches=%s binary_sha256=%s match_capacity=%s\n' \
    "$expected_start" "$expected_count" "$chunk_count" "$total_matches" \
    "$expected_binary_sha" "$expected_capacity" >&2
  sort -t= -k2,2n -u "$certified_results"
else
  printf 'MANIFEST_OK start=%s count=%s chunks=%s matches=%s binary_sha256=%s match_capacity=%s\n' \
    "$expected_start" "$expected_count" "$chunk_count" "$total_matches" \
    "$expected_binary_sha" "$expected_capacity"
fi
