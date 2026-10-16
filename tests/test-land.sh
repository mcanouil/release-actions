#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091 # tests/lib.sh is linted as a file of its own.
source "${ROOT}/tests/lib.sh"

script="${ROOT}/land/land.sh"
export GITHUB_REPOSITORY=o/r GH_LOG="${SCRATCH}/gh.log" GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="${SCRATCH}/gitconfig" GH_ORIGIN="${SCRATCH}/origin.git"
: >"${GIT_CONFIG_GLOBAL}"
install_fake_gh

# Writes a bare origin with one commit on main, clones it to SCRATCH/work with
# a test identity unless the first argument is "anonymous", moves into the
# clone, and changes CITATION.cff there.
fixture() {
  cd "${SCRATCH}"
  rm -rf origin.git seed work
  git init -q --bare -b main origin.git
  git init -q -b main seed
  printf 'version: 1.4.2\n' >seed/CITATION.cff
  git -C seed add CITATION.cff
  git -C seed -c user.name=seed -c user.email=seed@example.com -c commit.gpgSign=false commit -q -m init
  git -C seed push -q "${GH_ORIGIN}" main
  git clone -q "${GH_ORIGIN}" work
  cd work
  git config commit.gpgSign false
  if [[ "${1:-}" != "anonymous" ]]; then
    git config user.name test
    git config user.email test@example.com
  fi
  printf 'version: 1.5.0\n' >CITATION.cff
}

# Runs land.sh with the VAR=value arguments after the defaults of a push of
# v1.5.0. Sets STATUS, ERR and OUT.
run_land() {
  OUT="${SCRATCH}/out"
  : >"${OUT}"
  : >"${GH_LOG}"
  STATUS=0
  ERR="$(env GITHUB_OUTPUT="${OUT}" GITHUB_REF_NAME=main MODE=push FILES=CITATION.cff \
    VERSION=1.5.0 TAG_PREFIX=v GH_TOKEN=t "$@" "${script}" 2>&1 >/dev/null)" || STATUS=$?
}

origin_main() {
  git -C "${GH_ORIGIN}" rev-parse main
}

# Checks that the last run failed with NEEDLE and left no commit behind.
refuses_landing() {
  refuses "$1" "$2"
  assert_eq "$(git -C "${GH_ORIGIN}" rev-parse main)" "$(git rev-parse HEAD)" "$2 adds no commit"
}

fixture
run_land MODE=merge
refuses_landing "mode" "unknown mode"
run_land FILES=
refuses_landing "files" "empty files"
run_land FILES=missing.txt
refuses_landing "missing.txt" "missing file"
run_land VERSION=1.5
refuses_landing "version" "bad version"
run_land TAG_PREFIX='v/1'
refuses_landing "tag-prefix" "bad tag-prefix"
run_land TAG_PREFIX='v 1'
refuses_landing "tag-prefix" "tag-prefix with a space"
run_land GITHUB_REF_NAME=
refuses_landing "GITHUB_REF_NAME" "empty ref name"
git checkout -q --detach
run_land
refuses_landing "branch" "detached HEAD"
git checkout -q main
git checkout -q -- CITATION.cff
run_land
refuses_landing "no change" "unchanged files"
assert_contains "${ERR}" "already" "unchanged files hint"

fixture
run_land
assert_status 0 "${STATUS}" "push: ${ERR}"
assert_eq "ci: release v1.5.0 [skip ci]" "$(git -C "${GH_ORIGIN}" log -1 --format=%s main)" "push message"
assert_eq "$(origin_main)" "$(output_value sha "${OUT}")" "push sha"
assert_eq "$(origin_main)" "$(git rev-parse HEAD)" "push leaves HEAD at sha"
if git symbolic-ref -q HEAD >/dev/null; then
  printf '  push: HEAD is not detached\n' >&2
  exit 1
fi
assert_eq "test" "$(git -C "${GH_ORIGIN}" log -1 --format=%an main)" "push keeps the identity"

fixture anonymous
run_land
assert_status 0 "${STATUS}" "anonymous push: ${ERR}"
assert_eq "github-actions[bot]" "$(git -C "${GH_ORIGIN}" log -1 --format=%an main)" "anonymous author"
assert_eq "41898282+github-actions[bot]@users.noreply.github.com" \
  "$(git -C "${GH_ORIGIN}" log -1 --format=%ae main)" "anonymous email"

fixture
git -C "${SCRATCH}/seed" -c user.name=seed -c user.email=seed@example.com -c commit.gpgSign=false \
  commit -q --allow-empty -m moved
git -C "${SCRATCH}/seed" push -q "${GH_ORIGIN}" main
run_land
refuses "bypass list" "push refused"
assert_contains "${ERR}" "pull-request" "push refused hint"
