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

# Writes the answers of the fake gh pr view, one per argument, in order.
pr_script() {
  export GH_PR_SCRIPT="${SCRATCH}/pr-script"
  printf '%s\n' "$@" >"${GH_PR_SCRIPT}"
  rm -f "${GH_PR_SCRIPT}.pos"
}

# Runs land.sh in pull-request mode with the VAR=value arguments. Sets STATUS,
# ERR, OUT and LOG.
run_pr() {
  run_land MODE=pull-request LAND_POLL_INTERVAL=0 "$@"
  LOG="$(cat "${GH_LOG}")"
}

branch_sha() {
  git -C "${GH_ORIGIN}" rev-parse refs/heads/release/v1.5.0
}

assert_detached_at() {
  assert_eq "$1" "$(output_value sha "${OUT}")" "$2 sha"
  assert_eq "$1" "$(git rev-parse HEAD)" "$2 HEAD"
}

fixture
pr_script 'MERGEABLE|CLEAN' 'MERGED|{branch-sha}|CLEAN||0'
run_pr
assert_status 0 "${STATUS}" "direct merge: ${ERR}"
assert_contains "${LOG}" "pr create --repo o/r --base main --head release/v1.5.0 --title ci: release v1.5.0 --body Automated release of v1.5.0." "pull request"
assert_contains "${LOG}" "pr merge https://github.com/o/r/pull/7 --repo o/r --squash --delete-branch" "direct merge call"
if [[ "${LOG}" == *"--auto"* || "${LOG}" == *"--label"* ]]; then
  printf '  direct merge: unexpected --auto or --label in [%s]\n' "${LOG}" >&2
  exit 1
fi
assert_eq "ci: release v1.5.0" "$(git -C "${GH_ORIGIN}" log -1 --format=%s release/v1.5.0)" "pull request commit"
assert_detached_at "$(branch_sha)" "direct merge"

fixture
pr_script 'MERGEABLE|BLOCKED' 'MERGED|{branch-sha}|CLEAN||1'
run_pr
assert_status 0 "${STATUS}" "auto-merge: ${ERR}"
assert_contains "${LOG}" "--squash --delete-branch --auto" "auto-merge call"

fixture
pr_script 'UNKNOWN|UNKNOWN' 'MERGEABLE|CLEAN' 'MERGED|{branch-sha}|CLEAN||0'
run_pr
assert_status 0 "${STATUS}" "unknown mergeability: ${ERR}"

fixture
pr_script 'CONFLICTING|DIRTY'
run_pr
refuses "cannot be merged" "conflicting"

fixture
printf 'bug\nType: CI/CD :robot:\n' >"${SCRATCH}/labels"
pr_script 'MERGEABLE|CLEAN' 'MERGED|{branch-sha}|CLEAN||0'
run_pr GH_LABELS="${SCRATCH}/labels"
assert_status 0 "${STATUS}" "label: ${ERR}"
assert_contains "${LOG}" "--label Type: CI/CD :robot:" "label"

fixture
git push -q origin HEAD:refs/heads/release/v1.5.0
pr_script 'MERGEABLE|CLEAN' 'MERGED|{branch-sha}|CLEAN||0'
run_pr GH_STALE_PR=3
assert_status 0 "${STATUS}" "stale pull request: ${ERR}"
assert_contains "${LOG}" "pr close 3 --repo o/r" "stale pull request closed"
assert_eq "ci: release v1.5.0" "$(git -C "${GH_ORIGIN}" log -1 --format=%s release/v1.5.0)" "stale branch replaced"

fixture
pr_script 'MERGEABLE|CLEAN' 'MERGED|{branch-sha}|CLEAN||0'
run_pr GH_MERGE_FAILS=1
assert_status 0 "${STATUS}" "merge failed but landed: ${ERR}"
assert_contains "${ERR}" "gh pr merge failed" "merge failed warning"

fixture
pr_script 'MERGEABLE|CLEAN' 'MERGED||CLEAN||0' '!fail' 'MERGED|{branch-sha}|CLEAN||0'
run_pr
assert_status 0 "${STATUS}" "late merge commit and transient error: ${ERR}"
assert_detached_at "$(branch_sha)" "late merge commit"

fixture
pr_script 'MERGEABLE|CLEAN' 'CLOSED||CLEAN||0'
run_pr
refuses "closed without merging" "closed"

fixture
pr_script 'MERGEABLE|BLOCKED' 'OPEN||BLOCKED||0'
run_pr LAND_BLOCKED_AFTER=0
refuses "App token" "blocked with no checks"

fixture
pr_script 'MERGEABLE|BLOCKED' 'OPEN||BLOCKED|REVIEW_REQUIRED|0'
run_pr LAND_BLOCKED_AFTER=0 MERGE_TIMEOUT=1
refuses "merge-timeout" "blocked by a review"
if [[ "${ERR}" == *"App token"* ]]; then
  printf '  blocked by a review: blamed the token\n' >&2
  exit 1
fi

fixture
pr_script 'MERGEABLE|BLOCKED' 'OPEN||BLOCKED||2'
run_pr MERGE_TIMEOUT=1
refuses "merge-timeout" "timeout"
assert_contains "${ERR}" "https://github.com/o/r/pull/7" "timeout names the pull request"

fixture
pr_script 'MERGEABLE|CLEAN' 'MERGED||CLEAN||0'
run_pr MERGE_TIMEOUT=1
refuses "create the release by hand" "merged with no merge commit"

fixture
for timeout in abc 0; do
  run_pr MERGE_TIMEOUT="${timeout}"
  refuses_landing "merge-timeout" "merge-timeout ${timeout}"
  assert_eq "" "${LOG}" "merge-timeout ${timeout} calls no gh"
done

fixture
pr_script 'MERGEABLE|UNKNOWN' 'MERGEABLE|CLEAN' 'MERGED|{branch-sha}|CLEAN||0'
run_pr
assert_status 0 "${STATUS}" "unknown merge state: ${ERR}"
if [[ "${LOG}" == *"--auto"* ]]; then
  printf '  unknown merge state: --auto on a clean pull request\n' >&2
  exit 1
fi

fixture
pr_script 'MERGEABLE|BLOCKED' 'OPEN||BLOCKED||1'
run_pr GH_MERGE_FAILS=1 LAND_MERGE_GRACE=0
refuses "gh pr merge failed" "merge refused"
assert_contains "${ERR}" "Auto-merge is not allowed" "merge refused keeps the gh error"
