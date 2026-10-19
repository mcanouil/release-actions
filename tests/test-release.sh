#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091 # tests/lib.sh is linted as a file of its own.
source "${ROOT}/tests/lib.sh"

script="${ROOT}/release/release.sh"
sha=0123456789abcdef0123456789abcdef01234567
export RUNNER_TEMP="${SCRATCH}/tmp" GITHUB_REPOSITORY=o/r GH_LOG="${SCRATCH}/gh.log" GH_TAGS="${SCRATCH}/tags"
mkdir -p "${RUNNER_TEMP}" "${SCRATCH}/work/dist"
install_fake_gh

cd "${SCRATCH}/work"
body="${SCRATCH}/body.md"
printf '## Changelog\n\n- feat: X.\n' >"${body}"
touch dist/demo-1.5.0.tar.gz dist/demo-1.5.0.zip

# Runs release.sh with the VAR=value arguments, after the existing tags in
# TAGS (one per line). Sets STATUS, ERR, OUT and LOG.
run_release() {
  OUT="${SCRATCH}/out"
  : >"${OUT}"
  : >"${GH_LOG}"
  printf '%s' "${TAGS:-}" >"${GH_TAGS}"
  STATUS=0
  ERR="$(env GITHUB_OUTPUT="${OUT}" GITHUB_STEP_SUMMARY="${SCRATCH}/summary" RELEASE_DATE=2026-10-15 \
    VERSION=1.5.0 BODY_FILE="${body}" TARGET="${sha}" "$@" "${script}" 2>&1 >/dev/null)" || STATUS=$?
  LOG="$(cat "${GH_LOG}")"
}

refuses_release() {
  refuses "$1" "$2"
  if grep -q '^release create' "${GH_LOG}"; then
    printf '  %s: a release was created\n' "$2" >&2
    exit 1
  fi
}

run_release TAG_PREFIX=v
assert_status 0 "${STATUS}" "basic: ${ERR}"
assert_contains "${LOG}" "release create v1.5.0 --repo o/r --target ${sha} --title v1.5.0 --notes-file ${body}" "create call"
assert_eq "v1.5.0" "$(output_value tag "${OUT}")" "tag output"
assert_eq "https://github.com/o/r/releases/tag/v1.5.0" "$(output_value url "${OUT}")" "url output"
assert_eq "42" "$(output_value release-id "${OUT}")" "release-id output"
assert_contains "$(cat "${SCRATCH}/summary")" "## Release v1.5.0" "step summary"

run_release TITLE='Demo {version} ({date})'
assert_contains "${LOG}" "--title Demo 1.5.0 (2026-10-15) --notes-file" "title template"

run_release TITLE='Demo {verison}'
refuses_release "unknown placeholders: {verison}" "title typo"

run_release DRAFT=true PRERELEASE=true LATEST=false
assert_contains "${LOG}" "--draft --prerelease --latest=false" "flags"

run_release LATEST=true
assert_contains "${LOG}" "--notes-file ${body} --latest" "latest true"

run_release LATEST=sometimes
refuses_release "latest is 'sometimes'" "bad latest"

run_release DRAFT=yes
refuses_release "draft is 'yes'" "bad boolean"

run_release ASSETS=$'dist/*.tar.gz#Archive (tar.gz)\n\n  dist/*.zip  '
assert_status 0 "${STATUS}" "assets: ${ERR}"
assert_contains "${LOG}" "--notes-file ${body} dist/demo-1.5.0.tar.gz#Archive (tar.gz) dist/demo-1.5.0.zip" "asset arguments"

run_release ASSETS='dist/*.whl'
refuses_release "no file matches the asset 'dist/*.whl'" "missing asset"

run_release BODY_FILE="${SCRATCH}/absent.md"
refuses_release "body-file '${SCRATCH}/absent.md' does not exist" "missing body"

run_release VERSION=v1.5
refuses_release "version is 'v1.5'" "bad version"

TAGS=$'v1.5.0\n' run_release TAG_PREFIX=v
refuses_release "tag v1.5.0 already exists" "existing tag"

run_release TAG_PREFIX=v GH_RELEASE_EXISTS=1
refuses_release "a release named v1.5.0 already exists" "existing release"

run_release TAG_PREFIX=v EXISTING=sometimes
refuses_release "existing is 'sometimes'. Use fail, keep." "bad existing"

# existing: keep passes only for a published release whose tag is on the target.
TAGS=$'v1.5.0\n' run_release TAG_PREFIX=v EXISTING=keep GH_RELEASE_EXISTS=1 GH_TAG_COMMIT="${sha}" ROLLING=true
assert_status 0 "${STATUS}" "keep matching: ${ERR}"
if grep -Eq '^(release create|release upload|api --method)' "${GH_LOG}"; then
  printf '  keep matching: the release or a tag changed\n' >&2
  exit 1
fi
assert_contains "${ERR}" "release v1.5.0 already exists" "keep matching message"
assert_eq "v1.5.0" "$(output_value tag "${OUT}")" "keep tag output"
assert_eq "https://github.com/o/r/releases/tag/v1.5.0" "$(output_value url "${OUT}")" "keep url output"
assert_eq "42" "$(output_value release-id "${OUT}")" "keep release-id output"

TAGS=$'v1.5.0\n' run_release TAG_PREFIX=v EXISTING=keep GH_RELEASE_EXISTS=1 GH_TAG_COMMIT=def456 GH_RESOLVE_FROM=main GH_RESOLVE_TO=abc123 TARGET=main
refuses_release "tag v1.5.0 is on def456, but target is abc123" "keep other commit"

TAGS=$'v1.5.0\n' run_release TAG_PREFIX=v EXISTING=keep GH_RELEASE_EXISTS=1 GH_TAG_COMMIT="${sha}" GH_RESOLVE_FROM=0123456 GH_RESOLVE_TO="${sha}" TARGET=0123456
assert_status 0 "${STATUS}" "keep short sha: ${ERR}"

TAGS=$'v1.5.0\n' run_release TAG_PREFIX=v EXISTING=keep GH_RELEASE_EXISTS=1 GH_RELEASE_DRAFT=true GH_TAG_COMMIT="${sha}"
refuses_release "release v1.5.0 is a draft. Publish or delete it" "keep draft"

run_release TAG_PREFIX=v EXISTING=keep GH_RELEASE_EXISTS=1
refuses_release "release v1.5.0 exists, but tag v1.5.0 does not" "keep without tag"

run_release TAG_PREFIX=v EXISTING=keep
assert_status 0 "${STATUS}" "keep with nothing there creates: ${ERR}"
assert_contains "${LOG}" "release create v1.5.0" "keep with nothing there"

TAGS=$'v1.5.0\n' run_release TAG_PREFIX=v EXISTING=keep
refuses_release "tag v1.5.0 already exists" "keep with a tag and no release"

TAGS=$'v1.5.0\n' run_release TAG_PREFIX=v EXISTING=fail GH_RELEASE_EXISTS=1 GH_TAG_COMMIT="${sha}"
refuses_release "tag v1.5.0 already exists" "explicit fail"

run_release TAG_PREFIX=v GH_DOWN=1
refuses_release "could not check for the tag v1.5.0" "unreachable API"

run_release TAG_PREFIX=v GH_RELEASE_DOWN=1
refuses_release "could not check for the release v1.5.0" "unreachable releases API"

run_release ROLLING=true DRAFT=true
refuses_release "rolling and draft are both true" "rolling draft"

run_release ROLLING=true TARGET=main
refuses_release "rolling needs target to be a full commit SHA" "rolling without SHA"

# Rolling: v1 exists and moves, v1.5 is new.
TAGS=$'v1\n' run_release TAG_PREFIX=v ROLLING=true
assert_status 0 "${STATUS}" "rolling: ${ERR}"
assert_contains "${LOG}" "api --method PATCH repos/o/r/git/refs/tags/v1 -f sha=${sha} -F force=true --silent" "move v1"
assert_contains "${LOG}" "api --method POST repos/o/r/git/refs -f ref=refs/tags/v1.5 -f sha=${sha} --silent" "create v1.5"
assert_contains "$(cat "${SCRATCH}/summary")" "- Rolling tags: v1 v1.5" "rolling tags in the summary"

run_release ROLLING=true PRERELEASE=true
refuses_release "rolling and prerelease are both true" "rolling prerelease"

run_release ASSETS='dist/*.zip #Archive (zip)'
assert_status 0 "${STATUS}" "space before label: ${ERR}"
assert_contains "${LOG}" "--notes-file ${body} dist/demo-1.5.0.zip#Archive (zip)" "glob and label trimmed"

run_release TAG_PREFIX='v/'
refuses_release "tag-prefix is 'v/'" "bad tag prefix"

# Rolling never moves a tag back: v1 already serves 1.9.0.
TAGS=$'v1\nv1.9.0\nv1.5\n' run_release TAG_PREFIX=v ROLLING=true
assert_status 0 "${STATUS}" "backport: ${ERR}"
assert_contains "${ERR}" "v1 stays on v1.9.0" "backport warning"
if grep -q 'refs/tags/v1 ' "${GH_LOG}"; then
  printf '  backport moved v1\n' >&2
  exit 1
fi
assert_contains "${LOG}" "api --method PATCH repos/o/r/git/refs/tags/v1.5 -f sha=${sha} -F force=true --silent" "backport moves v1.5"

run_release VERSION=1.5.0-rc.1 ROLLING=true
refuses_release "rolling needs a release version" "rolling with a text suffix"

run_release VERSION=2026.10.16-2 RELEASE_DATE=2026-10-16 TITLE='{date}{count}'
assert_status 0 "${STATUS}" "count: ${ERR}"
assert_contains "${LOG}" "--title 2026-10-16 (2) --notes-file" "count on a second release of the day"
run_release VERSION=2026.10.16 RELEASE_DATE=2026-10-16 TITLE='{date}{count}'
assert_status 0 "${STATUS}" "count, first of the day: ${ERR}"
assert_contains "${LOG}" "--title 2026-10-16 --notes-file" "count on the first release of the day"
run_release TITLE='{tag}{count}'
assert_contains "${LOG}" "--title 1.5.0 --notes-file" "count on a semantic version"

# The tag lookup reads every page: v1.39.0 is not on the first page of 30.
TAGS="$(for minor in $(seq 0 39); do printf 'v1.%s.0\n' "${minor}"; done)" \
  run_release VERSION=1.38.1 TAG_PREFIX=v ROLLING=true
assert_status 0 "${STATUS}" "many tags: ${ERR}"
assert_contains "${ERR}" "v1 stays on v1.39.0" "many tags keep v1 on the highest release"
