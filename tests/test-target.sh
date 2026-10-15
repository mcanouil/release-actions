#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091 # tests/lib.sh is linted as a file of its own.
source "${ROOT}/tests/lib.sh"

script="${ROOT}/lib/target.pl"
file="${SCRATCH}/file.txt"

cat >"${file}" <<'EOF'
cff-version: 1.2.0
version: 1.4.2
date-released: "2026-01-02"
#import "@preview/demo:1.4.2": *
see @preview/demo:1.4.2 and mcanouil/demo@v1 or @v1.2
minato-2.0.0-x86_64.tar.gz
  "version": "1.4.2",
version = "1.4.2"
EOF

find_matches() {
  perl "${script}" find "$1" "${file}"
}

assert_eq "1.4.2" "$(find_matches '^version: {version}$')" "anchored line"
assert_eq $'1.2.0\n1.4.2' "$(find_matches 'version: {version}')" "unanchored also hits cff-version"
assert_eq $'1.4.2\n1.4.2' "$(find_matches '@preview/demo:{version}')" "every occurrence"
assert_eq 'date-released: "2026-01-02"' "$(find_matches '^date-released: "{date}"$')" "date placeholder prints the match"
assert_eq "2.0.0" "$(find_matches 'minato-{version}-x86_64')" "suffix keeps the literal dash"
assert_eq "@v1" "$(find_matches '@v{major}')" "major stops before a dot"
assert_eq "1.4.2" "$(find_matches '"version": "{version}"')" "JSON quotes are literal"
assert_eq "1.4.2" "$(find_matches '^version = "{version}"$')" "TOML equals sign is literal"
assert_eq "" "$(find_matches '^nothing: {version}$')" "no match prints nothing"
assert_eq "" "$(find_matches 'version: 1.4.{version}')" "dots are literal"

count="$(VERSION=1.5.0 DATE=2026-10-15 MAJOR=2 perl "${script}" replace '@preview/demo:{version}' "${file}")"
assert_eq 2 "${count}" "replace count"
assert_eq 2 "$(grep -c '@preview/demo:1.5.0' "${file}")" "both pins replaced"

VERSION=1.5.0 DATE=2026-10-15 MAJOR=2 perl "${script}" replace '^version: {version}$' "${file}" >/dev/null
assert_eq "cff-version: 1.2.0" "$(sed -n 1p "${file}")" "anchored replace leaves cff-version"
assert_eq "version: 1.5.0" "$(sed -n 2p "${file}")" "anchored replace"

VERSION=1.5.0 DATE=2026-10-15 MAJOR=2 perl "${script}" replace '^date-released: "{date}"$' "${file}" >/dev/null
assert_eq 'date-released: "2026-10-15"' "$(sed -n 3p "${file}")" "date replace"

VERSION=1.5.0 DATE=2026-10-15 MAJOR=2 perl "${script}" replace '@v{major}' "${file}" >/dev/null
assert_eq "see @preview/demo:1.5.0 and mcanouil/demo@v2 or @v1.2" "$(sed -n 5p "${file}")" "major replace"

VERSION=3.0.0 DATE=2026-10-15 MAJOR=3 perl "${script}" replace 'minato-{version}-x86_64' "${file}" >/dev/null
assert_eq "minato-3.0.0-x86_64.tar.gz" "$(sed -n 6p "${file}")" "replace keeps the literal dash"

before="$(cksum <"${file}")"
assert_eq 0 "$(VERSION=9.9.9 perl "${script}" replace '^nothing: {version}$' "${file}")" "zero matches"
assert_eq "${before}" "$(cksum <"${file}")" "zero matches leaves the file"

crlf="${SCRATCH}/crlf.txt"
printf 'version: 1.4.2\r\nname: x\r\n' >"${crlf}"
assert_eq "1.4.2" "$(perl "${script}" find '^version: {version}$' "${crlf}")" "anchored match before CRLF"
VERSION=1.5.0 perl "${script}" replace '^version: {version}$' "${crlf}" >/dev/null
assert_eq "$(printf 'version: 1.5.0\r\nname: x\r\n' | od -c)" "$(od -c <"${crlf}")" "CRLF kept"

status=0
err="$(env -u VERSION perl "${script}" replace '{version}' "${file}" 2>&1 >/dev/null)" || status=$?
assert_status 1 "${status}" "unset value"
assert_contains "${err}" "VERSION is not set" "unset value message"

status=0
err="$(perl "${script}" find '{version}' "${SCRATCH}/missing.txt" 2>&1 >/dev/null)" || status=$?
assert_status 1 "${status}" "missing file"
assert_contains "${err}" "cannot read" "missing file message"

status=0
perl "${script}" bogus '{version}' "${file}" 2>/dev/null || status=$?
assert_status 1 "${status}" "bad mode"
