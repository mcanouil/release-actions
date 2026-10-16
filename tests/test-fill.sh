#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091 # tests/lib.sh is linted as a file of its own.
source "${ROOT}/tests/lib.sh"

script="${ROOT}/lib/fill.pl"

export FILL_version=1.5.0 FILL_tag=v1.5.0 FILL_date=2026-10-15 FILL_repository=o/r
names=version,tag,date,repository

# shellcheck disable=SC2016 # The dollar signs are template text, not expansions.
text='Get {version} ({tag}) on {date} from {repository}. VERSION=${VERSION} ${version} {Version} { x }'
# shellcheck disable=SC2016
expected='Get 1.5.0 (v1.5.0) on 2026-10-15 from o/r. VERSION=${VERSION} ${version} {Version} { x }'
assert_eq "${expected}" "$(printf '%s' "${text}" | perl "${script}" "${names}")" "fills and keeps shell text"

status=0
err="$(printf '{nmae} and {other} and {version}' | perl "${script}" "${names}" 2>&1 >/dev/null)" || status=$?
assert_status 2 "${status}" "unknown placeholder"
assert_eq "{nmae}, {other}" "${err}" "unknown placeholders listed"

status=0
err="$(printf 'at {tag}' | FILL_tag='' perl "${script}" "${names}" 2>&1 >/dev/null)" || status=$?
assert_status 3 "${status}" "empty value"
assert_eq "{tag}" "${err}" "empty placeholder listed"

assert_eq "" "$(perl "${script}" "${names}" </dev/null)" "empty input"
assert_eq "no placeholders" "$(printf 'no placeholders' | perl "${script}" "${names}")" "plain text"

assert_eq "2026-10-15" "$(printf '{date}{count}' | FILL_count='' perl "${script}" "${names},count" count)" "optional placeholder may be empty"
status=0
err="$(printf '{tag}{count}' | FILL_tag='' FILL_count='' perl "${script}" "${names},count" count 2>&1 >/dev/null)" || status=$?
assert_status 3 "${status}" "optional names do not cover other empty values"
assert_eq "{tag}" "${err}" "only the required empty placeholder listed"
