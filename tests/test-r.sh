#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091 # tests/lib.sh is linted as a file of its own.
source "${ROOT}/tests/lib.sh"
# shellcheck disable=SC1091 # lib/common.sh is linted as a file of its own.
source "${ROOT}/lib/common.sh"
# shellcheck disable=SC1091 # lib/r.sh is linted as a file of its own.
source "${ROOT}/lib/r.sh"

# Runs a command in a subshell. Sets STATUS and ERR, which refuses reads.
run() {
  # shellcheck disable=SC2034 # Read by refuses in tests/lib.sh.
  STATUS=0
  # shellcheck disable=SC2034 # Read by refuses in tests/lib.sh.
  ERR="$("$@" 2>&1 >/dev/null)" || STATUS=$?
}

# Versions.
next() {
  assert_eq "$3" "$(r_next_version "$1" "$2")" "$1 with $2"
}
next 2.0.8.9000 patch 2.0.9
next 2.0.8.9000 minor 2.1.0
next 2.0.8.9000 major 3.0.0
next 2.0.9 dev 2.0.9.9000
next 2.0.9.9000 dev 2.0.9.9000
next 1.2 patch 1.2.1
next 1.2 dev 1.2.0.9000
next 2.0.7 minor 2.1.0
next 2.0.08 patch 2.0.9
next 1.2.3.0 patch 1.2.4
next 2.0.8.9000 2.1.0 2.1.0
next 2.0.8.9000 3.0 3.0
run r_next_version 2.0.8.9000 calver
refuses "calver" "calver"
run r_next_version 2.0.8 2.1.0.1
refuses "four parts" "explicit four-part version"
run r_next_version 2.0.8 2.1.0-1
refuses "Use patch, minor, major, dev" "explicit version with a suffix"
run r_next_version 2.0.x patch
refuses "'2.0.x' is not" "malformed current version"
run r_next_version 2.0.8 huge
refuses "Use patch, minor, major, dev" "unknown bump"
run r_next_version 2.0.8 2.0.8
refuses "already the current version" "explicit equal to current"

# NEWS.md sections and roll.
news="${SCRATCH}/NEWS.md"
cat >"${news}" <<'EOF'

# NACHO (development version)

## New features

- feat: Next thing. (#61)

```r
# not a heading
```

# NACHO 2.0.8

- fix: Old thing. (#60)
EOF
pending=$'## New features\n\n- feat: Next thing. (#61)\n\n```r\n# not a heading\n```'
assert_eq "${pending}" "$(r_news_section "${news}" NACHO "(development version)")" "development section"
assert_eq "- fix: Old thing. (#60)" "$(r_news_section "${news}" NACHO 2.0.8)" "last section"
run r_news_section "${news}" NACHO 9.9.9
assert_status 2 "${STATUS}" "missing section"
r_news_pending "${news}" NACHO || assert_status 0 1 "development heading after blank lines"

r_roll_news "${news}" NACHO 2.1.0
assert_eq "" "$(sed -n 1p "${news}")" "roll keeps the leading blank line"
assert_eq "# NACHO 2.1.0" "$(sed -n 2p "${news}")" "roll renames the heading"
assert_eq "${pending}" "$(r_news_section "${news}" NACHO 2.1.0)" "renamed section"
assert_eq 14 "$(wc -l <"${news}" | tr -d ' ')" "roll keeps the line count"
before="$(cksum <"${news}")"
run r_roll_news "${news}" NACHO 2.1.1
assert_status 2 "${STATUS}" "roll without a development heading"
assert_eq "${before}" "$(cksum <"${news}")" "failed roll leaves the file"

r_roll_news "${news}" NACHO dev
assert_eq "# NACHO (development version)" "$(sed -n 1p "${news}")" "dev adds the heading"
assert_eq "" "$(sed -n 2p "${news}")" "dev adds an empty line"
assert_eq "" "$(sed -n 3p "${news}")" "dev keeps the old leading line"
assert_eq "# NACHO 2.1.0" "$(sed -n 4p "${news}")" "dev keeps the release below"
before="$(cksum <"${news}")"
r_roll_news "${news}" NACHO dev
assert_eq "${before}" "$(cksum <"${news}")" "dev twice changes nothing"

printf '# NACHO (development version)\r\n\r\n- fix: X.\r\n' >"${news}"
r_roll_news "${news}" NACHO 2.0.9
assert_eq "$(printf '# NACHO 2.0.9\r\n\r\n- fix: X.\r\n' | od -c)" "$(od -c <"${news}")" "roll keeps CRLF"

: >"${news}"
r_roll_news "${news}" NACHO dev
assert_eq "$(printf '# NACHO (development version)\n\n' | od -c)" "$(od -c <"${news}")" "dev on an empty file"

printf 'Package: NACHO\nVersion: 2.0.8\n' >"${SCRATCH}/DESCRIPTION"
assert_eq "NACHO" "$(r_package "${SCRATCH}/DESCRIPTION")" "package name"
printf 'Version: 2.0.8\n' >"${SCRATCH}/DESCRIPTION"
run r_package "${SCRATCH}/DESCRIPTION"
refuses "has no Package: line" "no package name"

# bump with the r preset.
script="${ROOT}/bump/bump.sh"
reference="${ROOT}/tests/fixtures/bump-version.sh"
export RUNNER_TEMP="${SCRATCH}/tmp" GITHUB_REPOSITORY=o/r GH_TAGS="${SCRATCH}/tags"
mkdir -p "${RUNNER_TEMP}"
install_fake_gh

run_bump() {
  OUT="${SCRATCH}/out"
  : >"${OUT}"
  STATUS=0
  ERR="$(env GITHUB_OUTPUT="${OUT}" RELEASE_DATE=2026-10-15 TAG_PREFIX=v "$@" "${script}" 2>&1 >/dev/null)" || STATUS=$?
}

tree_sum() {
  find . -type f -exec cksum {} + | LC_ALL=C sort
}

# Writes a NACHO-shaped package at SCRATCH/DIR, at VERSION, and moves into it.
fixture() {
  local dir="${1:-pkg}" version="${2:-2.0.8.9000}"
  cd "${SCRATCH}"
  rm -rf "${dir}"
  mkdir -p "${dir}"
  cd "${dir}"
  cat >DESCRIPTION <<EOF
Package: NACHO
Type: Package
Title: NanoString Quality Control Dashboard
Version: ${version}
License: GPL-3
EOF
  cat >NEWS.md <<'EOF'

# NACHO (development version)

## New features

- feat: Next thing. (#61)

```r
# not a heading
```

# NACHO 2.0.8

- fix: Old thing. (#60)
EOF
  cat >CITATION.cff <<'EOF'
cff-version: 1.2.0
title: "NACHO"
version: "2.0.8"
date-released: "2026-09-30"
EOF
}

# Turns the fixture at SCRATCH/DIR into a released 2.1.0 package.
released_fixture() {
  fixture "${1:-pkg}" 2.1.0
  printf '# NACHO 2.1.0\n\n- feat: Next thing. (#61)\n\n# NACHO 2.0.8\n\n- fix: Old thing. (#60)\n' >NEWS.md
}

printf 'v2.0.8\n' >"${GH_TAGS}"

# Release from a development version.
fixture
run_bump BUMP=minor ECOSYSTEMS="r, citation"
assert_status 0 "${STATUS}" "minor with r: ${ERR}"
assert_eq "2.1.0" "$(output_value version "${OUT}")" "version"
assert_eq "2.0.8.9000" "$(output_value previous "${OUT}")" "previous"
assert_eq "2" "$(output_value major "${OUT}")" "major"
assert_eq "2.1" "$(output_value minor "${OUT}")" "minor"
assert_eq "Version: 2.1.0" "$(sed -n 4p DESCRIPTION)" "DESCRIPTION version"
assert_eq "License: GPL-3" "$(sed -n 5p DESCRIPTION)" "DESCRIPTION kept"
assert_eq "" "$(sed -n 1p NEWS.md)" "NEWS.md leading blank line kept"
assert_eq "# NACHO 2.1.0" "$(sed -n 2p NEWS.md)" "NEWS.md heading renamed"
assert_eq "## New features" "$(sed -n 4p NEWS.md)" "NEWS.md subsection kept"
assert_eq 'version: "2.1.0"' "$(sed -n 3p CITATION.cff)" "CITATION.cff version"
assert_eq 'date-released: "2026-10-15"' "$(sed -n 4p CITATION.cff)" "CITATION.cff date"
assert_eq "${pending}" "$(cat "$(output_value notes-file "${OUT}")")" "notes file"
assert_eq $'CITATION.cff\nDESCRIPTION\nNEWS.md' "$(multiline_output files "${OUT}")" "files"

fixture
run_bump BUMP=patch ECOSYSTEMS=r
assert_eq "2.0.9" "$(output_value version "${OUT}")" "patch with r"
assert_eq 'version: "2.0.8"' "$(sed -n 3p CITATION.cff)" "r alone leaves CITATION.cff"
fixture
run_bump BUMP=2.1.0 ECOSYSTEMS=r
assert_eq "2.1.0" "$(output_value version "${OUT}")" "explicit with r"

# The tag check: a four-part version needs no tag, a three-part one does.
fixture pkg 2.1.0.9000
run_bump BUMP=patch ECOSYSTEMS=r
assert_status 0 "${STATUS}" "four-part version without its tag: ${ERR}"
fixture pkg 2.1.0
before="$(tree_sum)"
run_bump BUMP=patch ECOSYSTEMS=r
refuses "DESCRIPTION holds 2.1.0, which has no release" "three-part version without its tag"
assert_contains "${ERR}" "Create release v2.1.0" "hint names the tag"
assert_eq "${before}" "$(tree_sum)" "tree unchanged after the tag check"

# dev after a release.
printf 'v2.0.8\nv2.1.0\n' >"${GH_TAGS}"
released_fixture
run_bump BUMP=dev ECOSYSTEMS=r
assert_status 0 "${STATUS}" "dev: ${ERR}"
assert_eq "2.1.0.9000" "$(output_value version "${OUT}")" "dev version"
assert_eq "2.1.0" "$(output_value previous "${OUT}")" "dev previous"
assert_eq "2.1" "$(output_value minor "${OUT}")" "dev minor"
assert_eq "Version: 2.1.0.9000" "$(sed -n 4p DESCRIPTION)" "dev DESCRIPTION"
assert_eq "# NACHO (development version)" "$(sed -n 1p NEWS.md)" "dev heading"
assert_eq "" "$(sed -n 2p NEWS.md)" "dev empty line"
assert_eq "# NACHO 2.1.0" "$(sed -n 3p NEWS.md)" "dev keeps the release"
assert_eq "" "$(cat "$(output_value notes-file "${OUT}")")" "dev notes file"
assert_eq $'DESCRIPTION\nNEWS.md' "$(multiline_output files "${OUT}")" "dev files"
before="$(tree_sum)"
: >"${GH_TAGS}"
run_bump BUMP=dev ECOSYSTEMS=r GH_DOWN=1
assert_status 0 "${STATUS}" "dev again: ${ERR}"
assert_eq "${before}" "$(tree_sum)" "dev again changes nothing"
assert_eq "2.1.0.9000" "$(output_value version "${OUT}")" "dev again version"
assert_eq "2.1.0.9000" "$(output_value previous "${OUT}")" "dev again previous"
assert_eq "" "$(multiline_output files "${OUT}")" "dev again files"
printf 'v2.0.8\n' >"${GH_TAGS}"
released_fixture
run_bump BUMP=dev ECOSYSTEMS=r
refuses "DESCRIPTION holds 2.1.0, which has no release" "dev before the release"

# Refusals, each before any write.
fixture
before="$(tree_sum)"
run_bump BUMP=dev ECOSYSTEMS=citation
refuses "bump is dev" "dev without r"
assert_contains "${ERR}" "Add r to ecosystems" "dev without r hint"
run_bump BUMP=calver ECOSYSTEMS="r, citation"
refuses "calver" "calver with r"
run_bump BUMP=2.1.0.1 ECOSYSTEMS="r, citation"
refuses "four parts" "explicit four-part version with r"
assert_eq "${before}" "$(tree_sum)" "tree unchanged after the version refusals"
sed -i.bak 's/^# NACHO (development version)$/# NACHO 2.1.0/' NEWS.md && rm NEWS.md.bak
before="$(tree_sum)"
run_bump BUMP=minor ECOSYSTEMS="r, citation"
refuses "NEWS.md does not start with the heading '# NACHO (development version)'" "no development heading"
assert_eq "${before}" "$(tree_sum)" "tree unchanged without a development heading"
fixture
printf '# NACHO (development version)\n\n# NACHO 2.0.8\n\n- fix: Old.\n' >NEWS.md
run_bump BUMP=minor ECOSYSTEMS=r
refuses "the development section of NEWS.md is empty" "empty development section"
run_bump BUMP=minor ECOSYSTEMS=r ALLOW_EMPTY=true
assert_status 0 "${STATUS}" "empty development section with allow-empty: ${ERR}"
fixture
printf '# NACHO (development version)\n\n- fix: X.\n\n# NACHO 2.1.0\n\n- fix: Y.\n' >NEWS.md
run_bump BUMP=minor ECOSYSTEMS=r
refuses "NEWS.md already has the heading '# NACHO 2.1.0'" "release heading already there"
fixture
rm NEWS.md
run_bump BUMP=minor ECOSYSTEMS=r
refuses "NEWS.md does not exist" "missing NEWS.md"
assert_contains "${ERR}" "# NACHO (development version)" "missing NEWS.md hint"
fixture
rm DESCRIPTION
run_bump BUMP=minor ECOSYSTEMS=r
refuses "no file matches 'DESCRIPTION'" "missing DESCRIPTION"

# The changelog input still picks the file, or turns the roll off.
fixture
mkdir inst
mv NEWS.md inst/NEWS.md
run_bump BUMP=minor ECOSYSTEMS=r CHANGELOG=inst/NEWS.md
assert_status 0 "${STATUS}" "changelog set with r: ${ERR}"
assert_eq "# NACHO 2.1.0" "$(sed -n 2p inst/NEWS.md)" "changelog set with r renames"
fixture
before="$(cksum <NEWS.md)"
run_bump BUMP=minor ECOSYSTEMS=r CHANGELOG=
assert_status 0 "${STATUS}" "changelog off with r: ${ERR}"
assert_eq "${before}" "$(cksum <NEWS.md)" "changelog off leaves NEWS.md"
assert_eq "DESCRIPTION" "$(multiline_output files "${OUT}")" "changelog off files"

# Cases of NACHO's bump-version.sh tests.
make_pkg() {
  cd "${SCRATCH}"
  rm -rf pkg
  mkdir -p pkg
  cd pkg
  printf 'Package: NACHO\nTitle: NanoString QC\nVersion: %s\nLicense: GPL-3\n' "$1" >DESCRIPTION
  printf '%b' "$2" >NEWS.md
}
printf 'v2.0.6\n' >"${GH_TAGS}"
make_pkg 2.0.6.9000 '# NACHO (development version)\n\n- fix: Something. (#60)\n\n# NACHO 2.0.6\n\n- fix: Older.\n'
run_bump BUMP=patch ECOSYSTEMS=r
assert_eq 2.0.7 "$(output_value version "${OUT}")" "bump patch from a development version"
assert_eq 2.0.6.9000 "$(output_value previous "${OUT}")" "bump reports the previous version"
assert_eq "Version: 2.0.7" "$(sed -n 3p DESCRIPTION)" "bump writes DESCRIPTION"
assert_eq "Title: NanoString QC" "$(sed -n 2p DESCRIPTION)" "bump keeps the other DESCRIPTION lines"
assert_eq 4 "$(wc -l <DESCRIPTION | tr -d ' ')" "bump keeps the DESCRIPTION line count"
assert_eq "# NACHO 2.0.7" "$(sed -n 1p NEWS.md)" "release renames the development heading"
assert_eq "- fix: Something. (#60)" "$(sed -n 3p NEWS.md)" "release keeps the NEWS body"
assert_eq 7 "$(wc -l <NEWS.md | tr -d ' ')" "release keeps the NEWS line count"

make_pkg 2.0.7.9000 '# NACHO (development version)\n'
run_bump BUMP=major ECOSYSTEMS=r ALLOW_EMPTY=true
assert_eq 3.0.0 "$(output_value version "${OUT}")" "bump major from a development version"

# NACHO adds a release heading when none is pending; the r preset refuses.
make_pkg 2.0.7 '# NACHO 2.0.7\n\n- fix: Older.\n'
run_bump BUMP=minor ECOSYSTEMS=r
refuses "does not start with the heading '# NACHO (development version)'" "release with no pending heading"

printf 'v2.0.7\n' >>"${GH_TAGS}"
make_pkg 2.0.7 '# NACHO 2.0.7\n\n- fix: Older.\n'
run_bump BUMP=dev ECOSYSTEMS=r
assert_eq 2.0.7.9000 "$(output_value version "${OUT}")" "dev bump appends 9000"
assert_eq "# NACHO (development version)" "$(sed -n 1p NEWS.md)" "dev bump adds the development heading"
assert_eq "" "$(sed -n 2p NEWS.md)" "dev bump leaves a blank line under it"
assert_eq "# NACHO 2.0.7" "$(sed -n 3p NEWS.md)" "dev bump keeps the release heading below"
before="$(tree_sum)"
run_bump BUMP=dev ECOSYSTEMS=r
assert_eq "${before}" "$(tree_sum)" "dev bump on a development version changes nothing"

# NACHO keeps a release heading written early; the r preset refuses.
make_pkg 2.0.6.9000 '# NACHO 2.0.7\n\n- fix: Written early.\n'
run_bump BUMP=patch ECOSYSTEMS=r
refuses "does not start with the heading '# NACHO (development version)'" "release heading written early"

printf 'v2.0.6\n' >"${GH_TAGS}"
make_pkg 2.0.6.9000 '\n# NACHO (development version)\n\n- fix: X.\n'
run_bump BUMP=patch ECOSYSTEMS=r
assert_eq "# NACHO 2.0.7" "$(sed -n 2p NEWS.md)" "release renames a heading after leading blank lines"

make_pkg 2.0.7 '# NACHO 2.0.7\n'
run_bump BUMP=huge ECOSYSTEMS=r
refuses "Use patch, minor, major, dev" "bump rejects an unknown level"
assert_eq "Version: 2.0.7" "$(sed -n 3p DESCRIPTION)" "a rejected bump leaves DESCRIPTION alone"
make_pkg 2.0.x '# NACHO 2.0.x\n'
run_bump BUMP=patch ECOSYSTEMS=r
refuses "found no line that matches '^Version: {version}\$'" "bump rejects a malformed version"
make_pkg 2.0.7 '# NACHO 2.0.7\n'
rm DESCRIPTION
run_bump BUMP=patch ECOSYSTEMS=r
assert_status 1 "${STATUS}" "bump fails without DESCRIPTION"

# The files equal those that NACHO's bump-version.sh writes.
for bump in patch minor dev; do
  printf 'v2.0.8\n' >"${GH_TAGS}"
  if [[ "${bump}" == "dev" ]]; then
    printf 'v2.1.0\n' >>"${GH_TAGS}"
    released_fixture expected
    released_fixture pkg
  else
    fixture expected
    fixture pkg
  fi
  "${reference}" "${bump}" "${SCRATCH}/expected" >/dev/null
  run_bump BUMP="${bump}" ECOSYSTEMS=r
  assert_status 0 "${STATUS}" "${bump} for equality: ${ERR}"
  for file in DESCRIPTION NEWS.md; do
    assert_eq "$(od -c <"${SCRATCH}/expected/${file}")" "$(od -c <"${file}")" "${file} after ${bump} equals bump-version.sh"
  done
done
