#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091 # tests/lib.sh is linted as a file of its own.
source "${ROOT}/tests/lib.sh"
# shellcheck disable=SC1091 # lib/common.sh is linted as a file of its own.
source "${ROOT}/lib/common.sh"

err="$( (GITHUB_ACTIONS=true die "it broke") 2>&1)" || true
assert_eq "::error::it broke" "${err}" "annotation in Actions"

err="$( (GITHUB_ACTIONS='' SCRIPT_NAME=demo die "it broke") 2>&1)" || true
assert_eq "demo: it broke" "${err}" "plain message outside Actions"

status=0
(die "x") 2>/dev/null || status=$?
assert_status 1 "${status}" "die exits 1"

err="$( (PATH=/nonexistent require_tools definitely-not-a-tool) 2>&1)" || true
assert_contains "${err}" "definitely-not-a-tool is not on PATH" "missing tool"

export GITHUB_OUTPUT="${SCRATCH}/out"
: >"${GITHUB_OUTPUT}"
set_output version 1.2.3
set_multiline_output files $'a.txt\nb.txt'
assert_eq "1.2.3" "$(output_value version "${GITHUB_OUTPUT}")" "single-line output"
assert_eq $'a.txt\nb.txt' "$(multiline_output files "${GITHUB_OUTPUT}")" "multi-line output"

assert_eq "/runner/tmp" "$(RUNNER_TEMP=/runner/tmp temp_dir)" "temp_dir prefers RUNNER_TEMP"

assert_eq "2028-02-29" "$(release_date 2028-02-29)" "leap day"
for bad in 2026-02-29 2026-02-30 2026-13-01 2026-04-31; do
  err="$( (release_date "${bad}") 2>&1)" || true
  assert_contains "${err}" "not a calendar date" "calendar check ${bad}"
done

# A temporary directory that cannot take the error file still names the template.
LIB="${ROOT}/lib"
err="$( (printf '{version}' | RUNNER_TEMP="${SCRATCH}/missing" FILL_version=1.0.0 fill_template version "the header") 2>&1)" || true
assert_contains "${err}" "could not fill the header" "fill without a temporary directory"
case "${err}" in
*"cat:"*)
  echo "  fill without a temporary directory: [${err}] shows a cat error" >&2
  exit 1
  ;;
esac
