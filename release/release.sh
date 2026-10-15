#!/usr/bin/env bash
# Creates the GitHub release of a version and, on request, moves the rolling
# major and minor tags. The inputs of release/action.yml arrive as environment
# variables.
set -euo pipefail

# shellcheck disable=SC2034 # Read by die in lib/common.sh.
SCRIPT_NAME=release
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
# shellcheck disable=SC1091 # lib/common.sh is linted as a file of its own.
source "${LIB}/common.sh"
# shellcheck disable=SC1091 # lib/version.sh is linted as a file of its own.
source "${LIB}/version.sh"

VERSION="${VERSION:-}"
TAG_PREFIX="${TAG_PREFIX:-}"
BODY_FILE="${BODY_FILE:-}"
TITLE="${TITLE:-}"
if [[ -z "${TITLE}" ]]; then
  TITLE='{tag}'
fi
TARGET="${TARGET:-${GITHUB_SHA:-}}"
ASSETS="${ASSETS:-}"
DRAFT="${DRAFT:-false}"
PRERELEASE="${PRERELEASE:-false}"
LATEST="${LATEST:-auto}"
ROLLING="${ROLLING:-false}"
REPOSITORY="${GITHUB_REPOSITORY:-}"

require_tools gh perl
[[ "${VERSION}" =~ ${VERSION_REGEX} ]] || die "version is '${VERSION}'. Pass the version output of the bump action."
[[ -n "${REPOSITORY}" ]] || die "GITHUB_REPOSITORY is not set."
[[ "${TAG_PREFIX}" =~ ^[A-Za-z0-9._-]*$ ]] || die "tag-prefix is '${TAG_PREFIX}'. Use letters, digits, dots, hyphens or underscores."
[[ -n "${TARGET}" ]] || die "target is empty. Pass the commit to tag."
RELEASE_DATE="$(release_date "${RELEASE_DATE:-}")"
require_bool draft "${DRAFT}"
require_bool prerelease "${PRERELEASE}"
require_bool rolling "${ROLLING}"
case "${LATEST}" in
auto | true | false) ;;
*) die "latest is '${LATEST}'. Use auto, true or false." ;;
esac
if [[ -z "${BODY_FILE}" || ! -f "${BODY_FILE}" ]]; then
  die "body-file '${BODY_FILE}' does not exist. Pass the body-file output of the notes action."
fi
if [[ "${ROLLING}" == "true" && "${PRERELEASE}" == "true" ]]; then
  die "rolling and prerelease are both true. Callers that pin the rolling tags would get the prerelease."
fi
if [[ "${ROLLING}" == "true" && "${DRAFT}" == "true" ]]; then
  die "rolling and draft are both true. A draft has no tag yet, so move the rolling tags when the draft is published."
fi
if [[ "${ROLLING}" == "true" && ! "${TARGET}" =~ ^[0-9a-f]{40}$ ]]; then
  die "rolling needs target to be a full commit SHA; got '${TARGET}'."
fi

tag="${TAG_PREFIX}${VERSION}"
title="$(printf '%s' "${TITLE}" | FILL_tag="${tag}" FILL_version="${VERSION}" FILL_date="${RELEASE_DATE}" \
  fill_template tag,version,date "title '${TITLE}'")"

asset_args=()
while IFS= read -r line; do
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  [[ -n "${line}" ]] || continue
  glob="${line%%#*}"
  glob="${glob%"${glob##*[![:space:]]}"}"
  label=""
  if [[ "${line}" == *"#"* ]]; then
    label="${line#*#}"
    label="#${label#"${label%%[![:space:]]*}"}"
  fi
  found=0
  while IFS= read -r path; do
    [[ -n "${path}" ]] || continue
    found=1
    asset_args+=("${path}${label}")
  done < <(compgen -G "${glob}" || true)
  if [[ ${found} -eq 0 ]]; then
    die "no file matches the asset '${glob}'. Build it before this step, or remove it from assets."
  fi
done <<<"${ASSETS}"

if gh api "repos/${REPOSITORY}/git/ref/tags/${tag}" --silent >/dev/null 2>&1; then
  die "tag ${tag} already exists. Bump to a new version, or delete the tag if a failed run left it."
fi
if gh release view "${tag}" --repo "${REPOSITORY}" >/dev/null 2>&1; then
  die "a release named ${tag} already exists, perhaps as a draft. Delete or publish it, then run again."
fi

args=(release create "${tag}" --repo "${REPOSITORY}" --target "${TARGET}" --title "${title}" --notes-file "${BODY_FILE}")
if [[ "${DRAFT}" == "true" ]]; then
  args+=(--draft)
fi
if [[ "${PRERELEASE}" == "true" ]]; then
  args+=(--prerelease)
fi
case "${LATEST}" in
true) args+=(--latest) ;;
false) args+=(--latest=false) ;;
esac
gh "${args[@]}" ${asset_args[@]+"${asset_args[@]}"} >/dev/null

rolling_tags=()
if [[ "${ROLLING}" == "true" ]]; then
  for ref in "${TAG_PREFIX}$(version_major "${VERSION}")" "${TAG_PREFIX}$(version_minor "${VERSION}")"; do
    # A backport must not move the rolling tag back from a higher release.
    released="$(gh api "repos/${REPOSITORY}/git/matching-refs/tags/${ref}." --jq '.[].ref')" ||
      die "could not list the tags under ${ref}. Check that the token can read ${REPOSITORY}."
    highest="$(printf '%s\n' "${released//refs\/tags\//}" | highest_version "${TAG_PREFIX}")"
    top="$(printf '%s\n%s\n' "${highest}" "${VERSION}" | highest_version "")"
    if [[ "${top}" != "${VERSION}" ]]; then
      warn "${ref} stays on ${TAG_PREFIX}${top}, which is higher than ${tag}."
      continue
    fi
    if gh api "repos/${REPOSITORY}/git/ref/tags/${ref}" --silent >/dev/null 2>&1; then
      gh api --method PATCH "repos/${REPOSITORY}/git/refs/tags/${ref}" -f "sha=${TARGET}" -F force=true --silent ||
        die "release ${tag} exists, but ${ref} did not move. Move it by hand: git tag -f ${ref} ${TARGET} && git push --force origin ${ref}."
    else
      gh api --method POST "repos/${REPOSITORY}/git/refs" -f "ref=refs/tags/${ref}" -f "sha=${TARGET}" --silent ||
        die "release ${tag} exists, but ${ref} was not created. Create it by hand: git tag ${ref} ${TARGET} && git push origin ${ref}."
    fi
    rolling_tags+=("${ref}")
  done
fi

info="$(gh release view "${tag}" --repo "${REPOSITORY}" --json url,databaseId --jq '[.url, .databaseId] | @tsv')"
url="${info%%$'\t'*}"
release_id="${info##*$'\t'}"

set_output tag "${tag}"
set_output url "${url}"
set_output release-id "${release_id}"
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    printf '## Release %s\n\n' "${tag}"
    printf -- '- URL: %s\n' "${url}"
    if [[ ${#rolling_tags[@]} -gt 0 ]]; then
      printf -- '- Rolling tags: %s\n' "${rolling_tags[*]}"
    fi
    if [[ ${#asset_args[@]} -gt 0 ]]; then
      printf -- '- Assets: %d\n' "${#asset_args[@]}"
    fi
  } >>"${GITHUB_STEP_SUMMARY}"
fi
