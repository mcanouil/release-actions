#!/usr/bin/env bash
# Assertions shared by the tests/test-*.sh files.
set -euo pipefail

SCRATCH="$(mktemp -d)"
trap 'rm -rf "${SCRATCH}"' EXIT
export SCRATCH

assert_eq() {
  if [[ "$1" != "$2" ]]; then
    printf '  %s: expected [%s], got [%s]\n' "$3" "$1" "$2" >&2
    exit 1
  fi
}

assert_contains() {
  if [[ "$1" != *"$2"* ]]; then
    printf '  %s: [%s] does not contain [%s]\n' "$3" "$1" "$2" >&2
    exit 1
  fi
}

assert_status() {
  if [[ "$1" -ne "$2" ]]; then
    printf '  %s: expected exit %s, got %s\n' "$3" "$1" "$2" >&2
    exit 1
  fi
}

# Prints the value of a NAME=VALUE line in a GITHUB_OUTPUT file.
output_value() {
  sed -n "s/^$1=//p" "$2"
}

# Prints the value of a NAME<<DELIMITER block in a GITHUB_OUTPUT file.
multiline_output() {
  awk -v name="$1" '
    !inside && index($0, name "<<") == 1 { delimiter = substr($0, length(name) + 3); inside = 1; next }
    inside && $0 == delimiter { exit }
    inside
  ' "$2"
}
