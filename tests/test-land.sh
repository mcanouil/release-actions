#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091 # tests/lib.sh is linted as a file of its own.
source "${ROOT}/tests/lib.sh"

script="${ROOT}/land/land.sh"
export GITHUB_REPOSITORY=o/r GH_LOG="${SCRATCH}/gh.log" GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="${SCRATCH}/gitconfig" GH_ORIGIN="${SCRATCH}/origin.git"
: >"${GIT_CONFIG_GLOBAL}"
install_fake_gh
printf '{"repository":{"default_branch":"main"}}\n' >"${SCRATCH}/event.json"

# Commits the staged changes of SCRATCH/seed as another contributor, with the
# git commit arguments, and pushes them to main of the bare origin.
seed_commit() {
  git -C "${SCRATCH}/seed" -c user.name=seed -c user.email=seed@example.com -c commit.gpgSign=false \
    commit -q "$@"
  git -C "${SCRATCH}/seed" push -q "${GH_ORIGIN}" main
}

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
  seed_commit -m init
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
  ERR="$(env GITHUB_OUTPUT="${OUT}" GITHUB_EVENT_PATH="${SCRATCH}/event.json" GITHUB_REF_NAME=main MODE=push FILES=CITATION.cff \
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
seed_commit --allow-empty -m moved
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
  git -C "${GH_ORIGIN}" rev-parse "refs/heads/${GH_HEAD_BRANCH:-release/v1.5.0}"
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
run_pr GH_STALE_PR='3 https://github.com/o/r/pull/3'
assert_status 0 "${STATUS}" "open pull request: ${ERR}"
assert_contains "${LOG}" "pr edit 3 --repo o/r --title ci: release v1.5.0 --body Automated release of v1.5.0." "open pull request updated"
assert_contains "${LOG}" "pr merge https://github.com/o/r/pull/3 " "open pull request merged"
if [[ "${LOG}" == *"pr close"* || "${LOG}" == *"pr create"* ]]; then
  printf '  open pull request: closed or created [%s]\n' "${LOG}" >&2
  exit 1
fi
assert_eq "ci: release v1.5.0" "$(git -C "${GH_ORIGIN}" log -1 --format=%s release/v1.5.0)" "open pull request branch replaced"

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
assert_contains "${ERR}" "another branch rule" "blocked with no checks names other rules"

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

fixture
printf 'seed\n' >"${SCRATCH}/seed/extra.txt"
git -C "${SCRATCH}/seed" add extra.txt
seed_commit -m extra
printf 'merged\n' >"${SCRATCH}/seed/extra.txt"
seed_commit -am merged
merged="$(git -C "${GH_ORIGIN}" rev-parse main)"
git fetch -q origin
git reset -q --hard origin/main~1
printf 'version: 1.5.0\n' >CITATION.cff
printf 'local\n' >extra.txt
pr_script 'MERGEABLE|CLEAN' "MERGED|${merged}|CLEAN||0"
run_pr
refuses "create the release by hand" "checkout of the merge commit refused"

# shellcheck disable=SC2016 # The literal $HOME proves land uses the message verbatim.
message='chore: refresh "goldens" for $HOME

Second paragraph.'
fixture
run_land VERSION= MESSAGE="${message}"
assert_status 0 "${STATUS}" "custom push message: ${ERR}"
assert_eq "${message}" "$(git -C "${GH_ORIGIN}" log -1 --format=%B main | sed '$d')" "custom push message verbatim"

fixture
export GH_HEAD_BRANCH=ci/update-thumbs
pr_script 'MERGEABLE|CLEAN' 'MERGED|{branch-sha}|CLEAN||0'
run_pr VERSION= MESSAGE='ci: update thumbs' PR_BRANCH=ci/update-thumbs BODY='New thumbs.'
assert_status 0 "${STATUS}" "custom pull request: ${ERR}"
assert_contains "${LOG}" "--head ci/update-thumbs --title ci: update thumbs --body New thumbs." "custom pull request call"
assert_eq "ci: update thumbs" "$(git -C "${GH_ORIGIN}" log -1 --format=%s ci/update-thumbs)" "custom pull request commit"
assert_detached_at "$(branch_sha)" "custom pull request"

fixture
pr_script 'MERGEABLE|CLEAN' 'MERGED|{branch-sha}|CLEAN||0'
run_pr VERSION= MESSAGE='ci: update thumbs' PR_BRANCH=ci/update-thumbs
assert_status 0 "${STATUS}" "body defaults to message: ${ERR}"
assert_contains "${LOG}" "--title ci: update thumbs --body ci: update thumbs" "body defaults to message"
unset GH_HEAD_BRANCH

fixture
run_land VERSION=
refuses_landing "message" "no version and no message"
run_pr VERSION= MESSAGE='ci: x'
refuses_landing "branch" "pull request with no branch"
run_pr MESSAGE='ci: x' PR_BRANCH=main
refuses_landing "branch" "pull request branch is the base"

fixture
pr_script 'MERGEABLE|CLEAN'
run_pr MERGE=none
assert_status 0 "${STATUS}" "merge none: ${ERR}"
if [[ "${LOG}" == *"pr merge"* || "${LOG}" == *"pr view"* ]]; then
  printf '  merge none: merged or polled [%s]\n' "${LOG}" >&2
  exit 1
fi
assert_eq "https://github.com/o/r/pull/7" "$(output_value pull-request "${OUT}")" "merge none url"
assert_eq "true" "$(output_value changed "${OUT}")" "merge none changed"
assert_eq "" "$(output_value sha "${OUT}")" "merge none sha"

fixture
pr_script 'MERGEABLE|CLEAN' 'MERGED|{branch-sha}|CLEAN||0'
run_pr MERGE_METHOD=merge
assert_status 0 "${STATUS}" "merge method: ${ERR}"
assert_contains "${LOG}" "--repo o/r --merge --delete-branch" "merge method call"

fixture
pr_script 'MERGEABLE|BLOCKED'
run_pr WAIT=false
assert_status 0 "${STATUS}" "no wait: ${ERR}"
assert_contains "${LOG}" "--auto" "no wait auto-merge"
assert_eq "1" "$(grep -c '^pr view' "${GH_LOG}")" "no wait polls once, for mergeability"
assert_eq "" "$(output_value sha "${OUT}")" "no wait sha"
assert_eq "true" "$(output_value changed "${OUT}")" "no wait changed"

fixture
pr_script 'MERGEABLE|BLOCKED'
run_pr WAIT=false GH_MERGE_FAILS=1
refuses "gh pr merge failed" "no wait merge refused"

fixture
git checkout -q -- CITATION.cff
for mode in push pull-request; do
  for version in 1.5.0 ''; do
    run_land MODE="${mode}" VERSION="${version}" MESSAGE='ci: x' PR_BRANCH=ci/x ALLOW_UNCHANGED=true
    assert_status 0 "${STATUS}" "unchanged ${mode} '${version}': ${ERR}"
    assert_eq "false" "$(output_value changed "${OUT}")" "unchanged ${mode} '${version}' changed"
    assert_eq "" "$(output_value sha "${OUT}")" "unchanged ${mode} '${version}' sha"
    assert_eq "" "$(cat "${GH_LOG}")" "unchanged ${mode} '${version}' calls no gh"
    assert_eq "$(origin_main)" "$(git rev-parse HEAD)" "unchanged ${mode} '${version}' adds no commit"
  done
done

fixture
run_land
assert_eq "true" "$(output_value changed "${OUT}")" "push changed"

fixture
run_pr MERGE=later
refuses_landing "merge" "unknown merge"
run_pr MERGE_METHOD=rebase
refuses_landing "merge-method" "unknown merge method"
run_pr WAIT=maybe
refuses_landing "wait" "bad wait"
run_land ALLOW_UNCHANGED=yes
refuses_landing "allow-unchanged" "bad allow-unchanged"

fixture
git push -q origin HEAD:refs/heads/release/v1.5.0
run_pr GH_STALE_PR='3 https://github.com/o/r/pull/3' MERGE=none
assert_status 0 "${STATUS}" "open pull request, merge none: ${ERR}"
assert_contains "${LOG}" "pr edit 3" "open pull request, merge none, updated"
assert_eq "https://github.com/o/r/pull/3" "$(output_value pull-request "${OUT}")" "open pull request url"
if [[ "${LOG}" == *"pr merge"* ]]; then
  printf '  open pull request, merge none: merged\n' >&2
  exit 1
fi

fixture
mkdir -p "${SCRATCH}/seed/goldens"
printf 'a\n' >"${SCRATCH}/seed/goldens/a.png"
printf 'b\n' >"${SCRATCH}/seed/goldens/b.png"
printf 'c\n' >"${SCRATCH}/seed/c.txt"
git -C "${SCRATCH}/seed" add goldens c.txt
seed_commit -m goldens
git pull -q --ff-only origin main
rm goldens/a.png c.txt
printf 'b2\n' >goldens/b.png
run_land VERSION= MESSAGE='test: refresh goldens' FILES="goldens
c.txt"
assert_status 0 "${STATUS}" "directory and deletions: ${ERR}"
assert_eq "D	c.txt
D	goldens/a.png
M	goldens/b.png" "$(git -C "${GH_ORIGIN}" diff --name-status main~1 main | LC_ALL=C sort)" "directory and deletions landed"

fixture
git checkout -q -b proposed
git commit -q -am "ci: release v1.5.0, from an earlier run"
git push -q origin HEAD:refs/heads/release/v1.5.0
proposed="$(git rev-parse HEAD)"
git checkout -q main
git branch -q -D proposed
printf 'version: 1.5.0\n' >CITATION.cff
run_pr GH_STALE_PR='3 https://github.com/o/r/pull/3' MERGE=none
assert_status 0 "${STATUS}" "open pull request with the same content: ${ERR}"
assert_eq "${proposed}" "$(branch_sha)" "same content leaves the pull request branch alone"

fixture
printf 'staged\n' >extra.txt
git add extra.txt
run_land
assert_status 0 "${STATUS}" "unrelated staged file: ${ERR}"
assert_eq "CITATION.cff" "$(git -C "${GH_ORIGIN}" diff --name-only main~1 main)" "only the listed files land"

fixture
git checkout -q -- CITATION.cff
printf 'staged\n' >extra.txt
git add extra.txt
run_land
refuses_landing "no change" "unchanged files with an unrelated staged file"

fixture
run_pr LAND_BLOCKED_AFTER=abc
refuses_landing "blocked-after" "bad blocked-after"

fixture
git checkout -q -b human
printf 'work in progress\n' >notes.txt
git add notes.txt
git commit -q -m "wip: human work"
git push -q origin HEAD:refs/heads/release/v1.5.0
human="$(git rev-parse HEAD)"
git checkout -q main
git branch -q -D human
printf 'version: 1.5.0\n' >CITATION.cff
run_pr
refuses_landing "release/v1.5.0" "branch that land did not create"
assert_eq "${human}" "$(branch_sha)" "branch that land did not create is kept"

fixture
printf 'gen/\n' >.gitignore
git add .gitignore
git commit -q -m ignore
git push -q origin main
mkdir -p gen
printf 'out\n' >gen/out.txt
run_land FILES=gen/out.txt
refuses_landing "could not stage" "ignored path"

# A release lands only on the default branch; other changes land anywhere.
fixture
run_land GITHUB_REF_NAME=feature
refuses_landing "a release lands on main, and this run is on feature" "release off the default branch"
run_land GITHUB_EVENT_PATH= GITHUB_REF_NAME=feature
refuses_landing "a release lands on main, and this run is on feature" "default branch from the API"
run_land GITHUB_REF_NAME=feature VERSION= MESSAGE='ci: refresh goldens'
assert_status 0 "${STATUS}" "change off the default branch: ${ERR}"
assert_eq "ci: refresh goldens" "$(git -C "${GH_ORIGIN}" log -1 --format=%s feature)" "change pushed to feature"

# Without jq, the default branch comes from the API.
fixture
run_land PATH="$(path_without jq)"
assert_status 0 "${STATUS}" "release without jq: ${ERR}"
assert_contains "$(cat "${GH_LOG}")" "api repos/o/r --jq .default_branch" "API fallback without jq"

# A run on a tag, such as a release event, lands a change on the base branch.
fixture
run_land GITHUB_REF_NAME=2026.10.17 VERSION= MESSAGE='ci: update docs' BASE=main
assert_status 0 "${STATUS}" "push to base: ${ERR}"
assert_eq "ci: update docs" "$(git -C "${GH_ORIGIN}" log -1 --format=%s main)" "push to base"
if git -C "${GH_ORIGIN}" rev-parse -q --verify refs/heads/2026.10.17 >/dev/null; then
  printf '  push to base: pushed to the ref of the run\n' >&2
  exit 1
fi

fixture
export GH_HEAD_BRANCH=ci/docs
pr_script 'MERGEABLE|CLEAN' 'MERGED|{branch-sha}|CLEAN||0'
run_pr GITHUB_REF_NAME=2026.10.17 VERSION= MESSAGE='ci: update docs' PR_BRANCH=ci/docs BASE=main
assert_status 0 "${STATUS}" "pull request to base: ${ERR}"
assert_contains "${LOG}" "pr create --repo o/r --base main --head ci/docs" "pull request to base"
unset GH_HEAD_BRANCH

fixture
run_pr VERSION= MESSAGE='ci: update docs' PR_BRANCH=docs BASE=docs
refuses_landing "the branch the pull request merges into" "head branch equal to base"

fixture
run_land BASE=main
refuses_landing "base" "release with a base"

fixture
run_land VERSION= MESSAGE='ci: update docs' BASE=mian
refuses_landing "base is mian, which origin does not have" "missing base"
if git -C "${GH_ORIGIN}" rev-parse -q --verify refs/heads/mian >/dev/null; then
  printf '  missing base: created the branch\n' >&2
  exit 1
fi

fixture
seed_commit --allow-empty -m moved
run_pr VERSION= MESSAGE='ci: update docs' PR_BRANCH=ci/docs BASE=main
refuses "does not build on main" "HEAD behind base"
