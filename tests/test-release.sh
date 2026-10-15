#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091 # tests/lib.sh is linted as a file of its own.
source "${ROOT}/tests/lib.sh"

script="${ROOT}/release/release.sh"
sha=0123456789abcdef0123456789abcdef01234567
export RUNNER_TEMP="${SCRATCH}/tmp" GITHUB_REPOSITORY=o/r GH_LOG="${SCRATCH}/gh.log" GH_TAGS="${SCRATCH}/tags"
mkdir -p "${RUNNER_TEMP}" "${SCRATCH}/bin" "${SCRATCH}/work/dist"
export PATH="${SCRATCH}/bin:${PATH}"

cat >"${SCRATCH}/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${GH_LOG}"
case "$*" in
"api repos/o/r/git/ref/tags/"*)
  args="$*"
  tag="${args#api repos/o/r/git/ref/tags/}"
  tag="${tag%% *}"
  grep -qxF "${tag}" "${GH_TAGS}"
  ;;
"api repos/o/r/git/matching-refs/tags/"*)
  args="$*"
  prefix="${args#api repos/o/r/git/matching-refs/tags/}"
  prefix="${prefix%% *}"
  { grep "^${prefix}" "${GH_TAGS}" || true; } | sed "s|^|refs/tags/|"
  ;;
"release view"*"--json"*)
  printf 'https://github.com/o/r/releases/tag/v1.5.0\t42\n'
  ;;
"release view"*)
  [[ -n "${GH_RELEASE_EXISTS:-}" ]]
  ;;
*) exit 0 ;;
esac
EOF
chmod +x "${SCRATCH}/bin/gh"

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
