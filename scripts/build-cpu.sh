#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CXX="${CXX:-c++}"

command -v "$CXX" >/dev/null 2>&1 || {
  printf 'ERROR: C++ compiler was not found: %s\n' "$CXX" >&2
  exit 69
}

mkdir -p "$ROOT/build"
"$CXX" -std=c++17 -O2 -Wall -Wextra -Wpedantic \
  "$ROOT/src/cpu_reference.cpp" -o "$ROOT/build/cpu-reference"
printf 'CPU_BUILD_OK output=%s\n' "$ROOT/build/cpu-reference"
