#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091 # tests/lib.sh is linted as a file of its own.
source "${ROOT}/tests/lib.sh"
# shellcheck disable=SC1091 # lib/common.sh is linted as a file of its own.
source "${ROOT}/lib/common.sh"
# shellcheck disable=SC1091 # lib/version.sh is linted as a file of its own.
source "${ROOT}/lib/version.sh"

check() {
  assert_eq "$3" "$(next_version "$1" "$2" "${4:-2026-10-15}")" "$1 $2"
}

check 1.4.2 patch 1.4.3
check 1.4.2 minor 1.5.0
check 1.4.2 major 2.0.0
check 0.0.0 major 1.0.0
check 0.0.0 patch 0.0.1
check 1.4.2-rc.1 patch 1.4.3
check 2026.08.07 minor 2026.9.0
check 2026.08.09 patch 2026.8.10
check 2026.10.14 calver 2026.10.15
check 2026.10.15 calver 2026.10.15-2
check 2026.10.15-2 calver 2026.10.15-3
check 2026.10.15-9 calver 2026.10.15-10
check 1.4.2 calver 2026.10.15
check 1.0.0 calver 2026.08.07 2026-08-07
check 1.4.2 2.0.0 2.0.0
check 1.4.2 1.4.2-1 1.4.2-1

refuse() {
  local status=0 err
  err="$( (next_version "$1" "$2" 2026-10-15) 2>&1 >/dev/null)" || status=$?
  assert_status 1 "${status}" "$1 $2 fails"
  assert_contains "${err}" "$3" "$1 $2 message"
}

refuse 1.4.2 1.4.2 "already the current version"
refuse 1.4.2 bogus "Use patch, minor, major, calver"
refuse 1.4 patch "is not X.Y.Z"
refuse 2026.10.15-rc calver "suffix that is not a number"

assert_eq "1" "$(version_major 1.5.0)" "major of semver"
assert_eq "1.5" "$(version_minor 1.5.0)" "minor of semver"
assert_eq "2026" "$(version_major 2026.10.15-2)" "major of calver"
assert_eq "2026.10" "$(version_minor 2026.10.15-2)" "minor of calver"
