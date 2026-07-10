#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

usage() {
  printf 'usage: %s START COUNT [CHUNK] [GPU_COUNT|auto] [SEED] [ZERO_BITS]\n' "$0" >&2
  printf 'environment: MATCH_CAPACITY=positive-u32 (default 4096)\n' >&2
}

is_uint() {
  [[ "${1:-}" =~ ^[0-9]+$ ]]
}

normalize_uint() {
  local value="$1"
  value="${value#"${value%%[!0]*}"}"
  printf '%s\n' "${value:-0}"
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
    if (( 10#$left_digit < 10#$right_digit )); then
      return 0
    fi
    if (( 10#$left_digit > 10#$right_digit )); then
      return 1
    fi
  done
  return 0
}

is_i63() {
  local value
  is_uint "${1:-}" || return 1
  value="$(normalize_uint "$1")"
  if [[ "${#value}" -lt 19 ]]; then
    return 0
  fi
  [[ "${#value}" -eq 19 ]] && decimal_le "$value" "9223372036854775807"
}

[[ $# -ge 2 && $# -le 6 ]] || {
  usage
  exit 64
}

start="$(normalize_uint "$1")"
count="$(normalize_uint "$2")"
chunk="$(normalize_uint "${3:-500000}")"
gpu_count="${4:-auto}"
seed="$(normalize_uint "${5:-0}")"
zero_bits="$(normalize_uint "${6:-20}")"
match_capacity="$(normalize_uint "${MATCH_CAPACITY:-4096}")"
search_bin="${SEARCH_BIN:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/build/range-search}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
verifier="$root/scripts/verify-manifest.sh"
resume="${SEARCH_RESUME:-0}"

for value in "$start" "$count" "$chunk" "$seed"; do
  is_i63 "$value" || {
    printf 'INPUT_ERROR: values must be unsigned integers in 0..2^63-1\n' >&2
    exit 64
  }
done
is_uint "$zero_bits" && is_uint "$match_capacity" || {
  printf 'INPUT_ERROR: ZERO_BITS and MATCH_CAPACITY must be integers\n' >&2
  exit 64
}
(( count > 0 && chunk > 0 && zero_bits >= 1 && zero_bits <= 63 && match_capacity > 0 )) \
  && decimal_le "$match_capacity" "4294967295" || {
  printf 'INPUT_ERROR: COUNT, CHUNK, and MATCH_CAPACITY must be positive; ZERO_BITS must be 1..63; MATCH_CAPACITY must fit u32\n' >&2
  exit 64
}
(( count <= 9223372036854775807 - start )) || {
  printf 'INPUT_ERROR: range exclusive end exceeds 2^63-1\n' >&2
  exit 64
}
[[ -x "$search_bin" ]] || {
  printf 'INPUT_ERROR: search executable is missing or not executable: %s\n' "$search_bin" >&2
  exit 66
}
[[ "$resume" == 0 || "$resume" == 1 ]] || {
  printf 'INPUT_ERROR: SEARCH_RESUME must be 0 or 1\n' >&2
  exit 64
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

if [[ "$gpu_count" == auto ]]; then
  command -v nvidia-smi >/dev/null 2>&1 || {
    printf 'GPU_ERROR: nvidia-smi is required when GPU_COUNT=auto\n' >&2
    exit 69
  }
  gpu_count="$(nvidia-smi --query-gpu=index --format=csv,noheader 2>/dev/null | wc -l | tr -d '[:space:]')"
else
  gpu_count="$(normalize_uint "$gpu_count")"
fi
is_uint "$gpu_count" && (( gpu_count >= 1 )) || {
  printf 'INPUT_ERROR: GPU_COUNT must be a positive integer or auto\n' >&2
  exit 64
}

ephemeral=0
if [[ -n "${SEARCH_RUN_DIR:-}" ]]; then
  run_dir="$SEARCH_RUN_DIR"
  mkdir -p "$run_dir"
else
  run_dir="$(mktemp -d)"
  ephemeral=1
fi
chunks_dir="$run_dir/chunks"
mkdir -p "$chunks_dir"
if [[ "$resume" == 0 ]]; then
  for existing_metadata in "$chunks_dir"/*.tsv; do
    [[ -e "$existing_metadata" ]] || continue
    printf 'INPUT_ERROR: run directory already has chunks; use SEARCH_RESUME=1 or a new directory\n' >&2
    exit 64
  done
fi
if ! mkdir "$run_dir/.lock" 2>/dev/null; then
  printf 'INPUT_ERROR: run directory is already locked: %s\n' "$run_dir" >&2
  printf 'RECOVERY: after confirming no search process owns it, remove %s/.lock and retry\n' "$run_dir" >&2
  exit 73
fi
cleanup() {
  rmdir "$run_dir/.lock" 2>/dev/null || true
  rm -f "${binary_snapshot:-}" "${merged_results:-}"
  if [[ "$ephemeral" == 1 ]]; then
    rm -rf "$run_dir"
  fi
}
trap cleanup EXIT INT TERM

binary_snapshot="$(mktemp "${TMPDIR:-/tmp}/cuda-range-search-bin.XXXXXX")"
cp "$search_bin" "$binary_snapshot"
chmod u+x "$binary_snapshot"
binary_sha="$(sha256_file "$binary_snapshot")"
per_device=$(( count / gpu_count ))
if (( count % gpu_count != 0 )); then
  per_device=$(( per_device + 1 ))
fi
pids=""
workers=0

chunk_complete() {
  local metadata="$1" expected_chunk_start="$2" expected_chunk_count="$3"
  local chunk_start chunk_count_value chunk_end meta_seed meta_bits gpu meta_binary_sha
  local output_sha matches status output_name meta_capacity extra output
  [[ -f "$metadata" ]] || return 1
  IFS=$'\t' read -r chunk_start chunk_count_value chunk_end meta_seed meta_bits gpu \
    meta_binary_sha output_sha matches status output_name meta_capacity extra <"$metadata"
  [[ -z "${extra:-}" && "$chunk_start" == "$expected_chunk_start" && \
     "$chunk_count_value" == "$expected_chunk_count" && \
     "$chunk_end" == "$((expected_chunk_start + expected_chunk_count))" && \
     "$meta_seed" == "$seed" && "$meta_bits" == "$zero_bits" && \
     "$meta_binary_sha" == "$binary_sha" && "$status" == complete && \
     "$output_name" == "${expected_chunk_start}-${expected_chunk_count}.out" && \
     "$meta_capacity" == "$match_capacity" ]] || return 1
  output="$chunks_dir/$output_name"
  [[ -f "$output" && "$(sha256_file "$output")" == "$output_sha" ]]
}

device_offset=0
for ((gpu = 0; gpu < gpu_count; gpu++)); do
  (( device_offset < count )) || break
  device_start=$(( start + device_offset ))
  device_count="$per_device"
  remaining_device=$(( count - device_offset ))
  if (( device_count > remaining_device )); then
    device_count="$remaining_device"
  fi
  err="$run_dir/gpu-${gpu}.err"
  (
    : >"$err"
    offset=0
    while (( offset < device_count )); do
      remaining_chunk=$(( device_count - offset ))
      current_count="$chunk"
      if (( current_count > remaining_chunk )); then
        current_count="$remaining_chunk"
      fi
      current_start=$(( device_start + offset ))
      output_name="${current_start}-${current_count}.out"
      out="$chunks_dir/$output_name"
      metadata="$chunks_dir/${current_start}-${current_count}.tsv"
      if [[ "$resume" == 1 ]] && chunk_complete "$metadata" "$current_start" "$current_count"; then
        printf 'RESUME_OK gpu=%s start=%s count=%s\n' \
          "$gpu" "$current_start" "$current_count" >>"$err"
        offset=$(( offset + current_count ))
        continue
      fi
      rm -f "$metadata" "$out.part" "$metadata.part"
      set +e
      CUDA_VISIBLE_DEVICES="$gpu" "$binary_snapshot" \
        "$current_start" "$current_count" "$seed" "$zero_bits" "$match_capacity" \
        >"$out.part" 2>>"$err"
      rc="$?"
      set -e
      if (( rc != 0 )); then
        printf 'WORKER_ERROR gpu=%s start=%s count=%s rc=%s\n' \
          "$gpu" "$current_start" "$current_count" "$rc" >>"$err"
        exit 70
      fi
      sort -t= -k2,2n -u "$out.part" >"$out"
      rm -f "$out.part"
      output_sha="$(sha256_file "$out")"
      matches="$(grep -c '^MATCH value=' "$out" 2>/dev/null || true)"
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\tcomplete\t%s\t%s\n' \
        "$current_start" "$current_count" "$((current_start + current_count))" \
        "$seed" "$zero_bits" "$gpu" "$binary_sha" "$output_sha" "$matches" \
        "$output_name" "$match_capacity" >"$metadata.part"
      mv "$metadata.part" "$metadata"
      offset=$(( offset + current_count ))
    done
  ) &
  pids="$pids $!"
  workers=$(( workers + 1 ))
  device_offset=$(( device_offset + device_count ))
done

status=0
for pid in $pids; do
  if ! wait "$pid"; then
    status=70
  fi
done

if (( status != 0 )); then
  printf 'SEARCH_FAILED: at least one GPU worker failed; results suppressed\n' >&2
  for err in "$run_dir"/*.err; do
    [[ -s "$err" ]] && cat "$err" >&2
  done
  exit "$status"
fi

merged_results="$(mktemp "${TMPDIR:-/tmp}/cuda-range-search-results.XXXXXX")"
set +e
"$verifier" --emit "$run_dir" "$start" "$count" "$seed" "$zero_bits" \
  "$binary_sha" "$match_capacity" >"$merged_results"
verify_rc="$?"
set -e
if (( verify_rc != 0 )); then
  printf 'SEARCH_FAILED: manifest verification failed; results suppressed\n' >&2
  exit "$verify_rc"
fi
cat "$merged_results"
printf 'COVERAGE_OK start=%s count=%s workers=%s chunk=%s run_dir=%s\n' \
  "$start" "$count" "$workers" "$chunk" "$run_dir" >&2
