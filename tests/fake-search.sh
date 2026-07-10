#!/usr/bin/env bash
set -euo pipefail

start="${1:?START}"
count="${2:?COUNT}"

if [[ -n "${FAKE_FAIL_AT:-}" && "$start" == "$FAKE_FAIL_AT" ]]; then
  printf 'synthetic worker failure at start=%s\n' "$start" >&2
  exit 9
fi

for ((offset = 0; offset < count; offset++)); do
  value=$(( start + offset ))
  if (( value % 3 == 0 )); then
    printf 'MATCH value=%s\n' "$value"
  fi
done
printf 'COVERAGE start=%s count=%s\n' "$start" "$count" >&2
