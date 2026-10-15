#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091 # tests/lib.sh is linted as a file of its own.
source "${ROOT}/tests/lib.sh"

script="${ROOT}/notes/notes.sh"
export RUNNER_TEMP="${SCRATCH}/tmp" GITHUB_REPOSITORY=o/r GH_LOG="${SCRATCH}/gh.log"
mkdir -p "${RUNNER_TEMP}" "${SCRATCH}/bin"
export PATH="${SCRATCH}/bin:${PATH}"

cat >"${SCRATCH}/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${GH_LOG}"
case "$*" in
"api repos/o/r/releases/latest"*)
  [[ -n "${GH_LATEST:-}" ]] || exit 1
  printf '%s\n' "${GH_LATEST}"
  ;;
"api --method POST repos/o/r/releases/generate-notes"*)
  [[ -z "${GH_FAIL:-}" ]] || exit 1
  printf '## Generated\n\n* feat: thing by @someone\n'
  ;;
*) exit 0 ;;
esac
EOF
chmod +x "${SCRATCH}/bin/gh"

notes="${SCRATCH}/notes.md"
printf -- '- feat: Next thing. (#7)\n' >"${notes}"
cd "${SCRATCH}"
cat >CHANGELOG.md <<'EOF'
# Changelog

## Unreleased

## 1.4.2 (2026-01-02)

- fix: Old thing.

## [1.0.0] - 2025-12-01

- feat: Initial release.
EOF

# Runs notes.sh with the VAR=value arguments. Sets STATUS, ERR and BODY.
run_notes() {
  local out="${SCRATCH}/out"
  : >"${out}"
  : >"${GH_LOG}"
  STATUS=0
  ERR="$(env GITHUB_OUTPUT="${out}" RELEASE_DATE=2026-10-15 "$@" "${script}" 2>&1 >/dev/null)" || STATUS=$?
  BODY=""
  if [[ ${STATUS} -eq 0 ]]; then
    BODY="$(cat "$(output_value body-file "${out}")")"
  fi
}

run_notes NOTES_FILE="${notes}"
assert_status 0 "${STATUS}" "notes-file: ${ERR}"
assert_eq $'## Changelog\n\n- feat: Next thing. (#7)' "${BODY}" "default section heading"

run_notes NOTES_FILE="${notes}" SECTION_HEADING=
assert_eq "- feat: Next thing. (#7)" "${BODY}" "no section heading"

cat >"${SCRATCH}/header.md" <<'EOF'
## Install

```bash
quarto add {repository}@{tag}
VERSION=${VERSION}
```

Released {version} on {date}.
EOF
run_notes NOTES_FILE="${notes}" VERSION=1.5.0 TAG=v1.5.0 HEADER="${SCRATCH}/header.md" SECTION_HEADING='## Changes'
assert_status 0 "${STATUS}" "header: ${ERR}"
# shellcheck disable=SC2016 # The dollar sign is template text.
assert_eq $'## Install\n\n```bash\nquarto add o/r@v1.5.0\nVERSION=${VERSION}\n```\n\nReleased 1.5.0 on 2026-10-15.\n\n## Changes\n\n- feat: Next thing. (#7)' \
  "${BODY}" "header filled"

printf 'Get {verison}.\n' >"${SCRATCH}/typo.md"
run_notes NOTES_FILE="${notes}" VERSION=1.5.0 HEADER="${SCRATCH}/typo.md"
refuses "unknown placeholders: {verison}" "unknown placeholder"

printf 'Tag {tag}.\n' >"${SCRATCH}/tag.md"
run_notes NOTES_FILE="${notes}" VERSION=1.5.0 HEADER="${SCRATCH}/tag.md"
refuses "uses {tag}, but it has no value" "placeholder without value"

run_notes NOTES_FILE="${notes}" HEADER="${SCRATCH}/absent.md"
refuses "header ${SCRATCH}/absent.md does not exist" "missing header"

: >"${SCRATCH}/empty.md"
printf 'Header only.\n' >"${SCRATCH}/plain.md"
run_notes NOTES_FILE="${SCRATCH}/empty.md" HEADER="${SCRATCH}/plain.md"
assert_eq "Header only." "${BODY}" "empty section drops its heading"

run_notes VERSION=1.4.2
assert_eq $'## Changelog\n\n- fix: Old thing.' "${BODY}" "extract by version"

run_notes VERSION=1.0.0 CHANGELOG_HEADING='## [{version}] - {date}'
assert_eq $'## Changelog\n\n- feat: Initial release.' "${BODY}" "extract with bracket heading"

run_notes VERSION=9.9.9
refuses "has no heading for 9.9.9" "version not in changelog"

run_notes
refuses "set notes-file, or version" "neither input"

run_notes NOTES_FILE="${SCRATCH}/absent-notes.md"
refuses "does not exist" "missing notes file"

run_notes NOTES_FILE="${notes}" RELEASE_DATE=2026/10/15
refuses "Use YYYY-MM-DD" "bad date"

# Generated notes.
run_notes NOTES_FILE="${notes}" GENERATE_NOTES=true TAG=v1.5.0 TARGET=abc123 GH_LATEST=v1.4.2
assert_status 0 "${STATUS}" "generated: ${ERR}"
assert_eq $'## Changelog\n\n- feat: Next thing. (#7)\n\n## Generated\n\n* feat: thing by @someone' "${BODY}" "generated appended"
assert_contains "$(cat "${GH_LOG}")" "-f tag_name=v1.5.0 -f target_commitish=abc123 -f previous_tag_name=v1.4.2" "generate-notes call"

run_notes NOTES_FILE="${notes}" GENERATE_NOTES=true TAG=v1.5.0 TARGET=abc123 PREVIOUS_TAG=v1.0.0
assert_contains "$(cat "${GH_LOG}")" "previous_tag_name=v1.0.0" "explicit previous tag"
if grep -q 'releases/latest' "${GH_LOG}"; then
  printf '  explicit previous tag still asked for the latest release\n' >&2
  exit 1
fi

run_notes NOTES_FILE="${notes}" GENERATE_NOTES=true TAG=v1.5.0 TARGET=abc123
assert_status 0 "${STATUS}" "first release: ${ERR}"
if grep -q 'previous_tag_name' "${GH_LOG}"; then
  printf '  no previous release, yet previous_tag_name was sent\n' >&2
  exit 1
fi

run_notes NOTES_FILE="${notes}" GENERATE_NOTES=true TAG=v1.5.0 TARGET=abc123 GH_FAIL=1
refuses "GitHub could not generate notes for v1.5.0" "API failure"

run_notes NOTES_FILE="${notes}" GENERATE_NOTES=true
refuses "generate-notes needs tag" "generated without tag"

run_notes NOTES_FILE="${notes}" GENERATE_NOTES=maybe
refuses "generate-notes is 'maybe'" "bad boolean"

# Size limit.
head -c 125001 /dev/zero | tr '\0' a >"${SCRATCH}/big.md"
run_notes NOTES_FILE="${SCRATCH}/big.md" SECTION_HEADING=
refuses "the release body is 125002 characters" "size limit"

# Each call writes its own body file.
out="${SCRATCH}/out"
: >"${out}"
GITHUB_OUTPUT="${out}" RELEASE_DATE=2026-10-15 NOTES_FILE="${notes}" "${script}"
first="$(output_value body-file "${out}")"
: >"${out}"
GITHUB_OUTPUT="${out}" RELEASE_DATE=2026-10-15 VERSION=1.4.2 "${script}"
second="$(output_value body-file "${out}")"
if [[ "${first}" == "${second}" ]]; then
  printf '  two notes calls share the body file %s\n' "${first}" >&2
  exit 1
fi
assert_eq $'## Changelog\n\n- feat: Next thing. (#7)' "$(cat "${first}")" "first body kept"

# The limit counts characters, not bytes, whatever the locale.
perl -e 'binmode STDOUT, ":utf8"; print "\x{e9}" x 62501' >"${SCRATCH}/accents.md"
out="${SCRATCH}/out"
: >"${out}"
status=0
LC_ALL=C GITHUB_OUTPUT="${out}" RELEASE_DATE=2026-10-15 NOTES_FILE="${SCRATCH}/accents.md" SECTION_HEADING='' "${script}" 2>/dev/null || status=$?
assert_status 0 "${status}" "multi-byte body under the limit"
