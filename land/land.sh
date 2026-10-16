#!/usr/bin/env bash
# Commits the files of a version bump and lands the commit on the branch of the
# run, with a push or with a pull request, then checks out the landed commit.
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
BRANCH="${GITHUB_REF_NAME:-}"
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
[[ "${VERSION}" =~ ${VERSION_REGEX} ]] || die "version is '${VERSION}'. Pass the version output of the bump action."
[[ "${TAG_PREFIX}" =~ ^[A-Za-z0-9._-]*$ ]] || die "tag-prefix is '${TAG_PREFIX}'. Use letters, digits, dots, hyphens or underscores."
[[ -n "${BRANCH}" ]] || die "GITHUB_REF_NAME is not set. Run land in a workflow on a branch."
[[ "${MERGE_TIMEOUT}" =~ ^[1-9][0-9]*$ ]] || die "merge-timeout is '${MERGE_TIMEOUT}'. Use a number of seconds above 0."
if [[ "${MODE}" == "pull-request" ]]; then
  require_tools gh
  [[ -n "${REPOSITORY}" ]] || die "GITHUB_REPOSITORY is not set."
fi

files=()
while IFS= read -r file; do
  if [[ -n "${file}" ]]; then
    [[ -e "${file}" ]] || die "files lists ${file}, which does not exist. Pass the files output of the bump action."
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

tag="${TAG_PREFIX}${VERSION}"
git add -- "${files[@]}"
if git diff --cached --quiet; then
  die "no change in ${files[*]} against HEAD. The bump may already be on ${BRANCH}: check it before you dispatch the workflow again."
fi

land_push() {
  git commit -q -m "ci: release ${tag} [skip ci]"
  git push -q origin "HEAD:refs/heads/${BRANCH}" ||
    die "the token could not push to ${BRANCH}. If ${BRANCH} moved, dispatch the workflow again. Otherwise add the App to the bypass list of the branch ruleset, or use mode: pull-request."
  git rev-parse HEAD
}

# Says what to do when the bump is on the branch but the run cannot go on.
die_landed() {
  die "$1 ${BRANCH} holds the bump of ${tag} with no release: create the release by hand on the landed commit, or revert it with a pull request and dispatch the workflow again."
}

# Opens the pull request of the bump and prints its URL. A pull request left
# open by an earlier run would make gh pr create fail, so it is closed first.
open_pull_request() {
  local head="$1" stale labels=()
  if git ls-remote --exit-code --heads origin "${head}" >/dev/null 2>&1; then
    stale="$(gh pr list --repo "${REPOSITORY}" --head "${head}" --state open --json number --jq '.[0].number // empty')" ||
      die "could not list the pull requests of ${head}. Check that the token can read ${REPOSITORY}."
    if [[ -n "${stale}" ]]; then
      warn "closing the pull request #${stale} that an earlier run left open."
      gh pr close "${stale}" --repo "${REPOSITORY}" >&2
    fi
  fi
  git checkout -q -B "${head}"
  git commit -q -m "ci: release ${tag}"
  git push -q --force origin "HEAD:refs/heads/${head}" ||
    die "the token could not push ${head}. Check that it has contents: write on ${REPOSITORY}."
  if gh label list --repo "${REPOSITORY}" --limit 1000 --json name --jq '.[].name' | grep -qxF "${LABEL}"; then
    labels=(--label "${LABEL}")
  fi
  # gh prints the pull request URL as the last line of its output.
  gh pr create --repo "${REPOSITORY}" --base "${BRANCH}" --head "${head}" \
    --title "ci: release ${tag}" --body "Automated release of ${tag}." \
    ${labels[@]+"${labels[@]}"} | tail -n 1
}

land_pull_request() {
  local deadline=$((SECONDS + MERGE_TIMEOUT)) blocked_after=$((SECONDS + BLOCKED_AFTER))
  local url info mergeable="UNKNOWN" state="" sha="" merge_state="UNKNOWN" review="" checks=""
  local merge_error="" merge_failed_at=""
  local merge_args=(--repo "${REPOSITORY}" --squash --delete-branch)

  url="$(open_pull_request "release/${tag}")"
  [[ -n "${url}" ]] || die "gh pr create printed no URL for release/${tag}."

  # The merge state decides between a direct merge and auto-merge, so it has
  # to be known too.
  while [[ "${mergeable}" == "UNKNOWN" || ("${mergeable}" == "MERGEABLE" && "${merge_state}" == "UNKNOWN") ]]; do
    if info="$(gh pr view "${url}" --repo "${REPOSITORY}" --json mergeable,mergeStateStatus \
      --jq '"\(.mergeable)|\(.mergeStateStatus)"')"; then
      mergeable="${info%%|*}"
      merge_state="${info#*|}"
    fi
    if [[ "${mergeable}" == "UNKNOWN" || "${merge_state}" == "UNKNOWN" ]]; then
      [[ ${SECONDS} -lt ${deadline} ]] || die "GitHub did not say whether ${url} can merge within ${MERGE_TIMEOUT}s. Raise merge-timeout, or merge it by hand and create the release."
      sleep "${POLL_INTERVAL}"
    fi
  done
  [[ "${mergeable}" == "MERGEABLE" ]] ||
    die "${url} is ${mergeable}, so the bump cannot be merged. Close it, bring ${BRANCH} back to a state the bump applies to, and dispatch the workflow again."

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
    warn "gh pr merge failed; checking whether ${url} merged. ${merge_error}"
  fi

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
      die "${url} is blocked and no check runs against it. The branch requires status checks, and a push by the default token starts none: use an App token, or a token from the token input."
    fi
    if [[ ${SECONDS} -ge ${deadline} ]]; then
      if [[ "${state}" == "MERGED" ]]; then
        die_landed "${url} merged but reported no merge commit."
      fi
      die "${url} did not merge within ${MERGE_TIMEOUT}s. Raise merge-timeout if the checks of ${BRANCH} take longer, or merge it by hand and create the release."
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

git checkout -q --detach "${sha}" || die_landed "could not check out ${sha}."
set_output sha "${sha}"
