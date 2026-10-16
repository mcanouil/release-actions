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

require_tools git
case "${MODE}" in
push | pull-request) ;;
*) die "mode is '${MODE}'. Use push or pull-request." ;;
esac
[[ "${VERSION}" =~ ${VERSION_REGEX} ]] || die "version is '${VERSION}'. Pass the version output of the bump action."
[[ "${TAG_PREFIX}" =~ ^[A-Za-z0-9._-]*$ ]] || die "tag-prefix is '${TAG_PREFIX}'. Use letters, digits, dots, hyphens or underscores."
[[ -n "${BRANCH}" ]] || die "GITHUB_REF_NAME is not set. Run land in a workflow on a branch."

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

case "${MODE}" in
push) sha="$(land_push)" ;;
pull-request) die "mode pull-request is not implemented." ;;
esac

git checkout -q --detach "${sha}"
set_output sha "${sha}"
