#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$ROOT/src/range_search.cu"
OUTPUT="$ROOT/build/range-search"

command -v nvcc >/dev/null 2>&1 || {
  printf 'ERROR: nvcc was not found on PATH\n' >&2
  exit 69
}
command -v nvidia-smi >/dev/null 2>&1 || {
  printf 'ERROR: nvidia-smi was not found on PATH\n' >&2
  exit 69
}

arch="$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | head -1 | tr -d '. \r')"
[[ "$arch" =~ ^[0-9]+$ ]] || {
  printf 'ERROR: could not detect an NVIDIA compute capability\n' >&2
  exit 69
}

mkdir -p "$ROOT/build"
log="$ROOT/build/nvcc.log"
: >"$log"

if nvcc -std=c++17 -O3 \
  -gencode "arch=compute_${arch},code=sm_${arch}" \
  -gencode "arch=compute_${arch},code=compute_${arch}" \
  "$SOURCE" -o "$OUTPUT" 2>"$log"; then
  printf 'BUILD_OK mode=native arch=sm_%s output=%s\n' "$arch" "$OUTPUT"
elif nvcc -std=c++17 -O3 \
  -gencode arch=compute_80,code=compute_80 \
  "$SOURCE" -o "$OUTPUT" 2>>"$log"; then
  printf 'BUILD_OK mode=ptx arch=compute_80 detected_gpu=sm_%s output=%s\n' \
    "$arch" "$OUTPUT"
else
  printf 'BUILD_ERROR: both native and PTX builds failed\n' >&2
  tail -40 "$log" >&2
  rm -f "$OUTPUT"
  exit 70
fi
