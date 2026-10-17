#!/usr/bin/env bash
# Commits files and lands the commit on the branch of the run, or on base, with
# a push or with a pull request, then checks out the landed commit. With a version, the
# message, the branch and the body of a release are the defaults.
# The inputs of land/action.yml arrive as environment variables.
set -euo pipefail

# shellcheck disable=SC2034 # Read by die in lib/common.sh.
SCRIPT_NAME=land
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
# shellcheck disable=SC1091 # lib/common.sh is linted as a file of its own.
source "${LIB}/common.sh"
# shellcheck disable=SC1091 # lib/version.sh is linted as a file of its own.
source "${LIB}/version.sh"

MODE="${MODE:-}"
FILES="${FILES:-}"
VERSION="${VERSION:-}"
TAG_PREFIX="${TAG_PREFIX:-}"
MESSAGE="${MESSAGE:-}"
PR_BRANCH="${PR_BRANCH:-}"
BODY="${BODY:-}"
MERGE="${MERGE:-auto}"
MERGE_METHOD="${MERGE_METHOD:-squash}"
WAIT="${WAIT:-true}"
ALLOW_UNCHANGED="${ALLOW_UNCHANGED:-false}"
BASE="${BASE:-}"
BRANCH="${BASE:-${GITHUB_REF_NAME:-}}"
REPOSITORY="${GITHUB_REPOSITORY:-}"
MERGE_TIMEOUT="${MERGE_TIMEOUT:-600}"
POLL_INTERVAL="${LAND_POLL_INTERVAL:-10}"
BLOCKED_AFTER="${LAND_BLOCKED_AFTER:-120}"
MERGE_GRACE="${LAND_MERGE_GRACE:-30}"
LABEL='Type: CI/CD :robot:'

require_tools git
case "${MODE}" in
push | pull-request) ;;
*) die "mode is '${MODE}'. Use push or pull-request." ;;
esac
if [[ -n "${VERSION}" ]]; then
  [[ "${VERSION}" =~ ${VERSION_REGEX} ]] || die "version is '${VERSION}'. Pass the version output of the bump action."
  [[ -z "${BASE}" ]] || die "base is ${BASE}, and a release lands on the branch of the run. Leave base empty."
elif [[ -z "${MESSAGE}" ]]; then
  die "message is empty and there is no version. Pass a commit message, or the version of a release."
fi
require_tag_prefix "${TAG_PREFIX}"
[[ -n "${BRANCH}" ]] || die "GITHUB_REF_NAME is not set. Run land in a workflow on a branch, or pass base."
[[ "${MERGE_TIMEOUT}" =~ ^[1-9][0-9]*$ ]] || die "merge-timeout is '${MERGE_TIMEOUT}'. Use a number of seconds above 0."
[[ "${BLOCKED_AFTER}" =~ ^[0-9]+$ ]] || die "blocked-after is '${BLOCKED_AFTER}'. Use a number of seconds."
case "${MERGE}" in
auto | none) ;;
*) die "merge is '${MERGE}'. Use auto or none." ;;
esac
case "${MERGE_METHOD}" in
squash | merge) ;;
*) die "merge-method is '${MERGE_METHOD}'. Use squash or merge." ;;
esac
require_bool wait "${WAIT}"
require_bool allow-unchanged "${ALLOW_UNCHANGED}"
if [[ "${MODE}" == "pull-request" ]]; then
  require_tools gh
  [[ -n "${REPOSITORY}" ]] || die "GITHUB_REPOSITORY is not set."
  if [[ -z "${PR_BRANCH}" && -z "${VERSION}" ]]; then
    die "branch is empty and there is no version. Pass the head branch of the pull request."
  fi
fi

tag="${TAG_PREFIX}${VERSION}"
if [[ -n "${VERSION}" ]]; then
  push_message="${MESSAGE:-ci: release ${tag} [skip ci]}"
  pr_message="${MESSAGE:-ci: release ${tag}}"
  PR_BRANCH="${PR_BRANCH:-release/${tag}}"
  BODY="${BODY:-Automated release of ${tag}.}"
  subject="the bump"
  by_hand="merge it by hand and create the release"
  landed="the bump of ${tag} with no release"
  recovery="create the release by hand on the landed commit, or revert it with a pull request and dispatch the workflow again"
else
  push_message="${MESSAGE}"
  pr_message="${MESSAGE}"
  BODY="${BODY:-${MESSAGE}}"
  subject="the change"
  by_hand="merge it by hand"
  landed="the change"
  recovery="check it before you dispatch the workflow again"
fi
# A release tags what it lands, so it lands on the default branch only. The
# event payload names that branch; the API answers when there is no payload or
# no jq.
if [[ -n "${VERSION}" ]]; then
  default_branch=""
  if [[ -n "${GITHUB_EVENT_PATH:-}" && -f "${GITHUB_EVENT_PATH}" ]] && command -v jq >/dev/null; then
    default_branch="$(jq -r '.repository.default_branch // empty' "${GITHUB_EVENT_PATH}")" ||
      die "could not read ${GITHUB_EVENT_PATH}, the event payload of the run."
  fi
  if [[ -z "${default_branch}" ]]; then
    require_tools gh
    [[ -n "${REPOSITORY}" ]] || die "GITHUB_REPOSITORY is not set."
    default_branch="$(gh api "repos/${REPOSITORY}" --jq .default_branch)" ||
      die "could not read the default branch of ${REPOSITORY}. Check that the token can read it."
  fi
  [[ -n "${default_branch}" ]] || die "GitHub named no default branch for ${REPOSITORY}."
  [[ "${default_branch}" == "${BRANCH}" ]] ||
    die "a release lands on ${default_branch}, and this run is on ${BRANCH}. Dispatch the workflow from ${default_branch}."
fi
if [[ "${MODE}" == "pull-request" && "${PR_BRANCH}" == "${BRANCH}" ]]; then
  die "branch is ${PR_BRANCH}, the branch the pull request merges into. Pass another head branch."
fi

files=()
while IFS= read -r file; do
  if [[ -n "${file}" ]]; then
    # A tracked file that the workflow deleted is a change to land.
    if [[ ! -e "${file}" && -z "$(git ls-files -- "${file}")" ]]; then
      die "files lists ${file}, which does not exist and is not tracked. Pass the files output of the bump action, or paths in the repository."
    fi
    files+=("${file}")
  fi
done <<<"${FILES}"
[[ ${#files[@]} -gt 0 ]] || die "files is empty. Pass the files output of the bump action."

git symbolic-ref -q HEAD >/dev/null ||
  die "HEAD is not on a branch. Check out ${BRANCH} before land."

if [[ -z "$(git config user.name || true)" || -z "$(git config user.email || true)" ]]; then
  git config user.name 'github-actions[bot]'
  git config user.email '41898282+github-actions[bot]@users.noreply.github.com'
fi

# Only the listed paths count and land, whatever an earlier step staged.
git add -A -- "${files[@]}" ||
  die "could not stage ${files[*]}. A path that .gitignore matches cannot land: list another path, or stop ignoring it."
if git diff --cached --quiet -- "${files[@]}"; then
  if [[ "${ALLOW_UNCHANGED}" == "true" ]]; then
    printf 'No change in %s: nothing to land.\n' "${files[*]}"
    set_output changed false
    set_output sha ""
    exit 0
  fi
  if [[ -n "${VERSION}" ]]; then
    die "no change in ${files[*]} against HEAD. The bump may already be on ${BRANCH}: check it before you dispatch the workflow again."
  fi
  die "no change in ${files[*]} against HEAD."
fi

land_push() {
  git commit -q -m "${push_message}" -- "${files[@]}" ||
    die "could not commit ${files[*]}. Check the git setup of the job, such as commit signing."
  git push -q origin "HEAD:refs/heads/${BRANCH}" ||
    die "the token could not push to ${BRANCH}. If ${BRANCH} moved, dispatch the workflow again. Otherwise add the App to the bypass list of the branch ruleset, or use mode: pull-request."
  git rev-parse HEAD
}

# Says what to do when the change is on the branch but the run cannot go on.
die_landed() {
  die "$1 ${BRANCH} holds ${landed}: ${recovery}."
}

# Pushes the head branch and prints the URL of its pull request. An open pull
# request on the branch, from an earlier run, is updated rather than replaced,
# so its review comments stay, and its branch is left alone when it already
# holds the same files, so its approvals and checks stay too.
open_pull_request() {
  local head="$1" open="" labels=()
  if git ls-remote --exit-code --heads origin "${head}" >/dev/null 2>&1; then
    open="$(gh pr list --repo "${REPOSITORY}" --head "${head}" --state open --json number,url \
      --jq '.[0] | select(.) | "\(.number) \(.url)"')" ||
      die "could not list the pull requests of ${head}. Check that the token can read ${REPOSITORY}."
    git fetch -q origin "${head}" || die "could not fetch ${head}."
    # The branch is force-pushed below, so it must hold nothing but an earlier
    # commit of land, or commits that are already on the base branch.
    if [[ -z "${open}" && "$(git log -1 --format=%s FETCH_HEAD)" != "${pr_message%%$'\n'*}" ]] &&
      ! git merge-base --is-ancestor FETCH_HEAD HEAD; then
      die "${head} already exists and holds commits that land did not make. Pass another branch, or delete ${head} if nobody needs it."
    fi
  fi
  if [[ -n "${open}" ]] && git diff --quiet FETCH_HEAD -- "${files[@]}"; then
    printf 'The pull request of %s already holds these files.\n' "${head}" >&2
  else
    git checkout -q -B "${head}"
    git commit -q -m "${pr_message}" -- "${files[@]}" ||
      die "could not commit ${files[*]}. Check the git setup of the job, such as commit signing."
    git push -q --force origin "HEAD:refs/heads/${head}" ||
      die "the token could not push ${head}. Check that it has contents: write on ${REPOSITORY}."
  fi
  if [[ -n "${open}" ]]; then
    gh pr edit "${open%% *}" --repo "${REPOSITORY}" --title "${pr_message}" --body "${BODY}" >&2 ||
      die "could not update the pull request #${open%% *} of ${head}."
    printf '%s\n' "${open#* }"
    return 0
  fi
  if gh label list --repo "${REPOSITORY}" --limit 1000 --json name --jq '.[].name' | grep -qxF "${LABEL}"; then
    labels=(--label "${LABEL}")
  fi
  # gh prints the pull request URL as the last line of its output.
  gh pr create --repo "${REPOSITORY}" --base "${BRANCH}" --head "${head}" \
    --title "${pr_message}" --body "${BODY}" \
    ${labels[@]+"${labels[@]}"} | tail -n 1
}

land_pull_request() {
  local deadline=$((SECONDS + MERGE_TIMEOUT)) blocked_after=$((SECONDS + BLOCKED_AFTER))
  local url info mergeable="UNKNOWN" state="" sha="" merge_state="UNKNOWN" review="" checks=""
  local merge_error="" merge_failed_at=""
  local merge_args=(--repo "${REPOSITORY}" "--${MERGE_METHOD}" --delete-branch)

  url="$(open_pull_request "${PR_BRANCH}")"
  [[ -n "${url}" ]] || die "gh pr create printed no URL for ${PR_BRANCH}."
  set_output pull-request "${url}"
  [[ "${MERGE}" == "auto" ]] || return 0

  # The merge state decides between a direct merge and auto-merge, so it has
  # to be known too.
  while [[ "${mergeable}" == "UNKNOWN" || ("${mergeable}" == "MERGEABLE" && "${merge_state}" == "UNKNOWN") ]]; do
    if info="$(gh pr view "${url}" --repo "${REPOSITORY}" --json mergeable,mergeStateStatus \
      --jq '"\(.mergeable)|\(.mergeStateStatus)"')"; then
      mergeable="${info%%|*}"
      merge_state="${info#*|}"
    fi
    if [[ "${mergeable}" == "UNKNOWN" || "${merge_state}" == "UNKNOWN" ]]; then
      [[ ${SECONDS} -lt ${deadline} ]] || die "GitHub did not say whether ${url} can merge within ${MERGE_TIMEOUT}s. Raise merge-timeout, or ${by_hand}."
      sleep "${POLL_INTERVAL}"
    fi
  done
  [[ "${mergeable}" == "MERGEABLE" ]] ||
    die "${url} is ${mergeable}, so ${subject} cannot be merged. Close it, bring ${BRANCH} back to a state ${subject} applies to, and dispatch the workflow again."

  # A pull request that nothing blocks merges at once; enabling auto-merge on
  # it would fail with "Pull request is in clean status".
  case "${merge_state}" in
  CLEAN | HAS_HOOKS | UNSTABLE) ;;
  *) merge_args+=(--auto) ;;
  esac
  # gh can fail after the merge has landed, so the state decides, for
  # MERGE_GRACE seconds.
  if ! merge_error="$(gh pr merge "${url}" "${merge_args[@]}" 2>&1)"; then
    merge_failed_at=${SECONDS}
    [[ "${WAIT}" == "true" ]] || die "gh pr merge failed for ${url}: ${merge_error}"
    warn "gh pr merge failed; checking whether ${url} merged. ${merge_error}"
  fi
  [[ "${WAIT}" == "true" ]] || return 0

  # Every field comes from one response, so they describe one instant.
  while :; do
    info="$(gh pr view "${url}" --repo "${REPOSITORY}" \
      --json state,mergeCommit,mergeStateStatus,reviewDecision,statusCheckRollup \
      --jq '[.state, (.mergeCommit.oid // ""), (.mergeStateStatus // ""), (.reviewDecision // ""), (.statusCheckRollup | length)] | map(tostring) | join("|")')" || info=""
    if [[ -n "${info}" ]]; then
      IFS='|' read -r state sha merge_state review checks <<<"${info}"
    fi
    case "${state}" in
    MERGED) [[ -z "${sha}" ]] || break ;;
    CLOSED) die "${url} was closed without merging. Dispatch the workflow again to open a new one." ;;
    esac
    if [[ -n "${merge_failed_at}" && ${SECONDS} -ge $((merge_failed_at + MERGE_GRACE)) && "${state}" != "MERGED" ]]; then
      die "gh pr merge failed and ${url} did not merge: ${merge_error} Correct the cause, close the pull request, and dispatch the workflow again."
    fi
    # A push by the default token triggers no workflow, so a branch that
    # requires checks waits for checks that never start.
    if [[ ${SECONDS} -ge ${blocked_after} && "${merge_state}" == "BLOCKED" && "${checks}" == "0" && "${review}" != "REVIEW_REQUIRED" ]]; then
      die "${url} is blocked and no check runs against it. Either the branch requires status checks and the push started none, as a push by the default token does: use an App token, or a token from the token input. Or another branch rule blocks the merge, such as signed commits, linear history or resolved conversations: merge it by hand."
    fi
    if [[ ${SECONDS} -ge ${deadline} ]]; then
      if [[ "${state}" == "MERGED" ]]; then
        die_landed "${url} merged but reported no merge commit."
      fi
      die "${url} did not merge within ${MERGE_TIMEOUT}s. Raise merge-timeout if the checks of ${BRANCH} take longer, or ${by_hand}."
    fi
    sleep "${POLL_INTERVAL}"
  done

  git fetch -q origin "${sha}" || die_landed "could not fetch the merge commit ${sha} of ${url}."
  printf '%s\n' "${sha}"
}

case "${MODE}" in
push) sha="$(land_push)" ;;
pull-request) sha="$(land_pull_request)" ;;
esac

if [[ -n "${sha}" ]]; then
  git checkout -q --detach "${sha}" || die_landed "could not check out ${sha}."
fi
set_output changed true
set_output sha "${sha}"
