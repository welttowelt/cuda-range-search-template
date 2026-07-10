#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

usage() {
  printf 'usage: %s START COUNT [CHUNK] [GPU_COUNT|auto] [SEED] [ZERO_BITS]\n' "$0" >&2
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
search_bin="${SEARCH_BIN:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/build/range-search}"

for value in "$start" "$count" "$chunk" "$seed"; do
  is_i63 "$value" || {
    printf 'INPUT_ERROR: values must be unsigned integers in 0..2^63-1\n' >&2
    exit 64
  }
done
is_uint "$zero_bits" || {
  printf 'INPUT_ERROR: ZERO_BITS must be an integer\n' >&2
  exit 64
}
(( count > 0 && chunk > 0 && zero_bits >= 1 && zero_bits <= 63 )) || {
  printf 'INPUT_ERROR: COUNT and CHUNK must be positive; ZERO_BITS must be 1..63\n' >&2
  exit 64
}
(( count - 1 <= 9223372036854775807 - start )) || {
  printf 'INPUT_ERROR: range exceeds 2^63-1\n' >&2
  exit 64
}
[[ -x "$search_bin" ]] || {
  printf 'INPUT_ERROR: search executable is missing or not executable: %s\n' "$search_bin" >&2
  exit 66
}

if [[ "$gpu_count" == auto ]]; then
  command -v nvidia-smi >/dev/null 2>&1 || {
    printf 'GPU_ERROR: nvidia-smi is required when GPU_COUNT=auto\n' >&2
    exit 69
  }
  gpu_count="$(nvidia-smi --query-gpu=index --format=csv,noheader 2>/dev/null | wc -l | tr -d '[:space:]')"
fi
is_uint "$gpu_count" && (( gpu_count >= 1 )) || {
  printf 'INPUT_ERROR: GPU_COUNT must be a positive integer or auto\n' >&2
  exit 64
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM
per_device=$(( (count + gpu_count - 1) / gpu_count ))
pids=""
workers=0

for ((gpu = 0; gpu < gpu_count; gpu++)); do
  device_start=$(( start + gpu * per_device ))
  end=$(( start + count ))
  if (( device_start >= end )); then
    continue
  fi
  device_count="$per_device"
  if (( device_start + device_count > end )); then
    device_count=$(( end - device_start ))
  fi
  out="$tmp/gpu-${gpu}.out"
  err="$tmp/gpu-${gpu}.err"
  (
    : >"$out"
    : >"$err"
    offset=0
    while (( offset < device_count )); do
      current_count="$chunk"
      if (( offset + current_count > device_count )); then
        current_count=$(( device_count - offset ))
      fi
      current_start=$(( device_start + offset ))
      set +e
      CUDA_VISIBLE_DEVICES="$gpu" "$search_bin" \
        "$current_start" "$current_count" "$seed" "$zero_bits" \
        >>"$out" 2>>"$err"
      rc="$?"
      set -e
      if (( rc != 0 )); then
        printf 'WORKER_ERROR gpu=%s start=%s count=%s rc=%s\n' \
          "$gpu" "$current_start" "$current_count" "$rc" >>"$err"
        exit 70
      fi
      offset=$(( offset + current_count ))
    done
  ) &
  pids="$pids $!"
  workers=$(( workers + 1 ))
done

status=0
for pid in $pids; do
  if ! wait "$pid"; then
    status=70
  fi
done

if (( status != 0 )); then
  printf 'SEARCH_FAILED: at least one GPU worker failed; results suppressed\n' >&2
  for err in "$tmp"/*.err; do
    [[ -s "$err" ]] && cat "$err" >&2
  done
  exit "$status"
fi

cat "$tmp"/*.out 2>/dev/null | sort -u
printf 'COVERAGE_OK start=%s count=%s workers=%s chunk=%s\n' \
  "$start" "$count" "$workers" "$chunk" >&2
