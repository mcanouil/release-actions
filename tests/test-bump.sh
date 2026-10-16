#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091 # tests/lib.sh is linted as a file of its own.
source "${ROOT}/tests/lib.sh"

script="${ROOT}/bump/bump.sh"
export RUNNER_TEMP="${SCRATCH}/tmp" GITHUB_REPOSITORY=o/r GH_TAGS="${SCRATCH}/tags"
mkdir -p "${RUNNER_TEMP}"
: >"${GH_TAGS}"
install_fake_gh

# Writes a fresh fixture repository at SCRATCH/repo and moves into it.
fixture() {
  cd "${SCRATCH}"
  rm -rf repo
  mkdir -p repo/_extensions/demo
  cd repo
  cat >CITATION.cff <<'EOF'
cff-version: 1.2.0
title: demo
version: 1.4.2
date-released: "2026-01-02"
EOF
  cat >typst.toml <<'EOF'
[package]
name = "demo"
version = "1.4.2"
EOF
  cat >README.md <<'EOF'
#import "@preview/demo:1.4.2": *
Use `@preview/demo:1.4.2`.
EOF
  cat >_extensions/demo/_extension.yml <<'EOF'
title: Demo
version: 1.4.2
EOF
  cat >CHANGELOG.md <<'EOF'
# Changelog

## Unreleased

- feat: Next thing. (#7)

## 1.4.2 (2026-01-02)

- fix: Old thing.
EOF
}

# Turns the fixture into a git repository with one empty commit.
git_fixture() {
  git init -q
  git config user.name test
  git config user.email test@example.com
  git config commit.gpgSign false
  git config tag.gpgSign false
  git commit -q --allow-empty -m init
}

# Runs bump.sh with the VAR=value arguments. Sets STATUS and ERR, and OUT to
# the path of the GITHUB_OUTPUT file.
run_bump() {
  OUT="${SCRATCH}/out"
  : >"${OUT}"
  STATUS=0
  ERR="$(env GITHUB_OUTPUT="${OUT}" RELEASE_DATE=2026-10-15 "$@" "${script}" 2>&1 >/dev/null)" || STATUS=$?
}

tree_sum() {
  find . -type f -not -path './.git/*' -exec cksum {} + | LC_ALL=C sort
}

TARGETS_ALL="$(
  cat <<'EOF'
- file: CITATION.cff
  pattern: '^version: {version}$'
- file: CITATION.cff
  pattern: '^date-released: "{date}"$'
- file: typst.toml
  pattern: '^version = "{version}"$'
  source: true
- file: README.md
  pattern: '@preview/demo:{version}'
- file: _extensions/*/_extension.yml
  pattern: '^version: {version}$'
EOF
)"

# Full minor bump.
fixture
run_bump BUMP=minor TARGETS="${TARGETS_ALL}"
assert_status 0 "${STATUS}" "minor bump: ${ERR}"
assert_eq "1.5.0" "$(output_value version "${OUT}")" "version"
assert_eq "1.4.2" "$(output_value previous "${OUT}")" "previous"
assert_eq "1" "$(output_value major "${OUT}")" "major"
assert_eq "1.5" "$(output_value minor "${OUT}")" "minor"
assert_eq "2026-10-15" "$(output_value date "${OUT}")" "date"
assert_eq "cff-version: 1.2.0" "$(sed -n 1p CITATION.cff)" "cff-version untouched"
assert_eq "version: 1.5.0" "$(sed -n 3p CITATION.cff)" "citation version"
assert_eq 'date-released: "2026-10-15"' "$(sed -n 4p CITATION.cff)" "citation date"
assert_eq 'version = "1.5.0"' "$(sed -n 3p typst.toml)" "typst.toml"
assert_eq 2 "$(grep -c '@preview/demo:1.5.0' README.md)" "both README pins"
assert_eq "version: 1.5.0" "$(sed -n 2p _extensions/demo/_extension.yml)" "glob target"
expected=$'# Changelog\n\n## Unreleased\n\n## 1.5.0 (2026-10-15)\n\n- feat: Next thing. (#7)\n\n## 1.4.2 (2026-01-02)\n\n- fix: Old thing.'
assert_eq "${expected}" "$(cat CHANGELOG.md)" "changelog roll"
assert_eq "- feat: Next thing. (#7)" "$(cat "$(output_value notes-file "${OUT}")")" "notes file"
assert_eq $'CHANGELOG.md\nCITATION.cff\nREADME.md\n_extensions/demo/_extension.yml\ntypst.toml' \
  "$(multiline_output files "${OUT}")" "files output"

# Other bumps.
fixture
run_bump BUMP=patch TARGETS="${TARGETS_ALL}"
assert_eq "1.4.3" "$(output_value version "${OUT}")" "patch"
fixture
run_bump BUMP=major TARGETS="${TARGETS_ALL}"
assert_eq "2.0.0" "$(output_value version "${OUT}")" "major bump"
assert_eq "2" "$(output_value major "${OUT}")" "major output"
fixture
run_bump BUMP=3.1.4 TARGETS="${TARGETS_ALL}"
assert_eq "3.1.4" "$(output_value version "${OUT}")" "explicit"
fixture
run_bump BUMP=1.4.2 TARGETS="${TARGETS_ALL}"
refuses "already the current version" "explicit equal to current"

# CalVer.
calver_targets="$(
  cat <<'EOF'
- file: CITATION.cff
  pattern: '^version: {version}$'
EOF
)"
fixture
sed -i.bak 's/^version: 1.4.2$/version: 2026.10.15/' CITATION.cff && rm CITATION.cff.bak
run_bump BUMP=calver TARGETS="${calver_targets}"
assert_eq "2026.10.15-2" "$(output_value version "${OUT}")" "calver same day"
assert_eq "version: 2026.10.15-2" "$(sed -n 3p CITATION.cff)" "calver written"
assert_eq "2026" "$(output_value major "${OUT}")" "calver major"

# Source selection: default is the first {version} target, after a {date} one.
default_source="$(
  cat <<'EOF'
- file: CITATION.cff
  pattern: '^date-released: "{date}"$'
- file: _extensions/*/_extension.yml
  pattern: '^version: {version}$'
- file: typst.toml
  pattern: '^version = "{version}"$'
EOF
)"
fixture
sed -i.bak 's/^version: 1.4.2$/version: 3.0.0/' _extensions/demo/_extension.yml && rm _extensions/demo/_extension.yml.bak
run_bump BUMP=patch TARGETS="${default_source}"
assert_eq "3.0.0" "$(output_value previous "${OUT}")" "first {version} target is the source"

fixture
sed -i.bak 's/^version: 1.4.2$/version: 3.0.0/' _extensions/demo/_extension.yml && rm _extensions/demo/_extension.yml.bak
run_bump BUMP=patch TARGETS="${default_source}
  source: true"
assert_eq "1.4.2" "$(output_value previous "${OUT}")" "source: true wins"

two_sources="$(
  cat <<'EOF'
- file: typst.toml
  pattern: '^version = "{version}"$'
  source: true
- file: CITATION.cff
  pattern: '^version: {version}$'
  source: true
EOF
)"
fixture
run_bump BUMP=patch TARGETS="${two_sources}"
refuses "both set source: true" "two sources"

fixture
run_bump BUMP=patch TARGETS="- file: CITATION.cff
  pattern: 'version: {version}'"
refuses "matches 2 times" "unanchored source hits cff-version"

fixture
run_bump BUMP=patch TARGETS="- file: CITATION.cff
  pattern: '^date-released: \"{date}\"\$'"
refuses "set version-source: tag" "no {version} target"

# Tag source.
fixture
git_fixture
for tag in v1.2.0 v1.10.0 v1.9.0 other 2.0.0; do git tag "${tag}"; done
run_bump BUMP=minor VERSION_SOURCE=tag TAG_PREFIX=v
assert_status 0 "${STATUS}" "tag source: ${ERR}"
assert_eq "1.10.0" "$(output_value previous "${OUT}")" "latest v tag, numeric order"
assert_eq "1.11.0" "$(output_value version "${OUT}")" "tag source bump"

fixture
git_fixture
for tag in 2026.10.14 2026.10.15 2026.10.15-2; do git tag "${tag}"; done
run_bump BUMP=calver VERSION_SOURCE=tag CHANGELOG=
assert_eq "2026.10.15-2" "$(output_value previous "${OUT}")" "calver tag order"
assert_eq "2026.10.15-3" "$(output_value version "${OUT}")" "calver from tags"

fixture
git init -q
run_bump BUMP=major VERSION_SOURCE=tag TAG_PREFIX=v
assert_eq "0.0.0" "$(output_value previous "${OUT}")" "no tags"
assert_eq "1.0.0" "$(output_value version "${OUT}")" "first release"

fixture
run_bump BUMP=patch VERSION_SOURCE=branch
refuses "Use target or tag" "bad version-source"

# Targets validation.
fixture
run_bump BUMP=patch TARGETS="${TARGETS_ALL}
- file: docs/*.qmd
  pattern: 'demo@{version}'"
refuses "no file matches 'docs/*.qmd'" "glob with no file"

fixture
run_bump BUMP=patch TARGETS="${TARGETS_ALL}
- file: docs/*.qmd
  pattern: 'demo@{version}'
  required: false
- file: typst.toml
  pattern: 'absent@{version}'
  required: false"
assert_status 0 "${STATUS}" "optional targets: ${ERR}"

fixture
run_bump BUMP=patch TARGETS="${TARGETS_ALL}
- file: typst.toml
  pattern: 'absent@{version}'"
refuses "typst.toml: no match for the pattern 'absent@{version}'" "required target with no match"

fixture
run_bump BUMP=patch TARGETS="- file: typst.toml
  pattern: '^version = \"{version}\"\$'
  sauce: true"
refuses "unknown key 'sauce'" "unknown key"

fixture
run_bump BUMP=patch TARGETS="- file: typst.toml"
refuses "needs file and pattern" "missing pattern"

fixture
run_bump BUMP=patch TARGETS="file: typst.toml"
refuses "targets is not a YAML list" "not a list"

fixture
run_bump BUMP=patch TARGETS="- file: typst.toml
  pattern: '^version = \"{version}\"\$'
  source: yes please"
refuses "source must be true or false" "source not a boolean"

fixture
run_bump BUMP=patch TARGETS="- file: typst.toml
  pattern: 'version'"
refuses "has no {version}, {date} or {major} placeholder" "pattern without placeholder"

# Changelog variants.
fixture
printf '# Changelog\n\n## [Unreleased]\n\n- fix: Bracket.\n\n## [1.4.2] - 2026-01-02\n' >CHANGELOG.md
run_bump BUMP=patch TARGETS="${TARGETS_ALL}" CHANGELOG_HEADING='## [{version}] - {date}'
assert_status 0 "${STATUS}" "bracket changelog: ${ERR}"
assert_eq $'# Changelog\n\n## [Unreleased]\n\n## [1.4.3] - 2026-10-15\n\n- fix: Bracket.\n\n## [1.4.2] - 2026-01-02' \
  "$(cat CHANGELOG.md)" "bracket roll"

fixture
printf '# Changelog\n\n## Unreleased\n\n## 1.4.2 (2026-01-02)\n' >CHANGELOG.md
run_bump BUMP=patch TARGETS="${TARGETS_ALL}"
refuses "Unreleased section of CHANGELOG.md is empty" "empty section"

fixture
printf '# Changelog\n\n## Unreleased\n\n## 1.4.2 (2026-01-02)\n' >CHANGELOG.md
run_bump BUMP=patch TARGETS="${TARGETS_ALL}" ALLOW_EMPTY=true
assert_status 0 "${STATUS}" "allow-empty: ${ERR}"
assert_eq "" "$(cat "$(output_value notes-file "${OUT}")")" "empty notes file"

fixture
printf '# Changelog\n\n## 1.4.2 (2026-01-02)\n' >CHANGELOG.md
run_bump BUMP=patch TARGETS="${TARGETS_ALL}"
refuses "has no '## Unreleased' or '## [Unreleased]' heading" "no Unreleased heading"

fixture
printf '## Unreleased\n\n- a\n\n## Unreleased\n\n- b\n' >CHANGELOG.md
run_bump BUMP=patch TARGETS="${TARGETS_ALL}"
refuses "more than one Unreleased heading" "two Unreleased headings"

fixture
printf '# Changelog\n\n## Unreleased\n\n- feat: X.\n\n## 1.4.3 (2026-10-15)\n' >CHANGELOG.md
run_bump BUMP=patch TARGETS="${TARGETS_ALL}"
refuses "already has the heading '## 1.4.3 (2026-10-15)'" "heading exists"

fixture
run_bump BUMP=patch TARGETS="${TARGETS_ALL}" CHANGELOG_HEADING='## Release'
refuses "has no {version} placeholder" "heading without version"

fixture
printf '## Unreleased  \r\n\r\n- feat: X.\r\n' >CHANGELOG.md
run_bump BUMP=patch TARGETS="${TARGETS_ALL}"
assert_status 0 "${STATUS}" "CRLF changelog: ${ERR}"
assert_contains "$(cat CHANGELOG.md)" $'## Unreleased\r\n\r\n## 1.4.3 (2026-10-15)\r\n' "CRLF roll keeps CRLF"

fixture
rm CHANGELOG.md
run_bump BUMP=patch TARGETS="${TARGETS_ALL}" CHANGELOG=
assert_status 0 "${STATUS}" "no changelog: ${ERR}"
assert_eq "" "$(cat "$(output_value notes-file "${OUT}")")" "no changelog, empty notes"

fixture
rm CHANGELOG.md
run_bump BUMP=patch TARGETS="${TARGETS_ALL}"
refuses "CHANGELOG.md does not exist" "missing changelog"

# Inputs.
fixture
run_bump BUMP=patch TARGETS="${TARGETS_ALL}" CHANGELOG_HEADING='## {version} ({daet})'
refuses "changelog-heading has unknown placeholders: {daet}" "heading typo"

fixture
run_bump BUMP= TARGETS="${TARGETS_ALL}"
refuses "bump is empty" "empty bump"

fixture
run_bump BUMP=patch TARGETS="${TARGETS_ALL}" RELEASE_DATE=2026/10/15
refuses "Use YYYY-MM-DD" "bad date"

# Nothing is written when a check fails.
fixture
before="$(tree_sum)"
run_bump BUMP=minor TARGETS="${TARGETS_ALL}
- file: missing.txt
  pattern: 'x{version}'"
assert_status 1 "${STATUS}" "late failure"
assert_eq "${before}" "$(tree_sum)" "tree unchanged after a failure"

# An existing tag or release stops the bump before any write.
fixture
before="$(tree_sum)"
printf 'v1.5.0\n' >"${GH_TAGS}"
run_bump BUMP=minor TARGETS="${TARGETS_ALL}" TAG_PREFIX=v
refuses "tag v1.5.0 already exists" "existing tag"
assert_eq "${before}" "$(tree_sum)" "tree unchanged after an existing tag"
run_bump BUMP=minor TARGETS="${TARGETS_ALL}"
assert_status 0 "${STATUS}" "the tag check uses tag-prefix: ${ERR}"
: >"${GH_TAGS}"
fixture
run_bump BUMP=minor TARGETS="${TARGETS_ALL}" GH_RELEASE_EXISTS=1
refuses "a release named 1.5.0 already exists" "existing release"
assert_eq "${before}" "$(tree_sum)" "tree unchanged after an existing release"
run_bump BUMP=minor TARGETS="${TARGETS_ALL}" GH_DOWN=1
refuses "could not check for the tag 1.5.0" "unreachable API"
assert_eq "${before}" "$(tree_sum)" "tree unchanged after an API error"
run_bump BUMP=minor TARGETS="${TARGETS_ALL}" GITHUB_REPOSITORY=
refuses "GITHUB_REPOSITORY is not set" "no repository"
run_bump BUMP=minor TARGETS="${TARGETS_ALL}" TAG_PREFIX=a/b
refuses "tag-prefix is 'a/b'" "bad tag-prefix"
