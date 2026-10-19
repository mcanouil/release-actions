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
EXISTING="${EXISTING:-fail}"
REPOSITORY="${GITHUB_REPOSITORY:-}"

require_tools gh perl
[[ "${VERSION}" =~ ${VERSION_REGEX} ]] || die "version is '${VERSION}'. Pass the version output of the bump action."
[[ -n "${REPOSITORY}" ]] || die "GITHUB_REPOSITORY is not set."
require_tag_prefix "${TAG_PREFIX}"
[[ -n "${TARGET}" ]] || die "target is empty. Pass the commit to tag."
RELEASE_DATE="$(release_date "${RELEASE_DATE:-}")"
require_bool draft "${DRAFT}"
require_bool prerelease "${PRERELEASE}"
require_bool rolling "${ROLLING}"
case "${EXISTING}" in
fail | keep) ;;
*) die "existing is '${EXISTING}'. Use fail, keep." ;;
esac
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
if [[ "${ROLLING}" == "true" && ! "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9]+)?$ ]]; then
  die "rolling needs a release version such as 1.2.3 or 2026.10.15-2; got '${VERSION}'. Release it without rolling."
fi
if [[ "${ROLLING}" == "true" && "${DRAFT}" == "true" ]]; then
  die "rolling and draft are both true. A draft has no tag yet, so move the rolling tags when the draft is published."
fi
if [[ "${ROLLING}" == "true" && ! "${TARGET}" =~ ^[0-9a-f]{40}$ ]]; then
  die "rolling needs target to be a full commit SHA; got '${TARGET}'."
fi

tag="${TAG_PREFIX}${VERSION}"
# A further CalVer release of a day, such as 2026.10.16-2, counts itself in
# the title; the first release of the day has no count.
count=""
if [[ "${VERSION}" =~ ^[0-9]{4}\.[0-9]{2}\.[0-9]{2}-([0-9]+)$ ]]; then
  count=" (${BASH_REMATCH[1]})"
fi
title="$(printf '%s' "${TITLE}" | FILL_tag="${tag}" FILL_version="${VERSION}" FILL_date="${RELEASE_DATE}" \
  FILL_count="${count}" fill_template tag,version,date,count "title '${TITLE}'" count)"

# With existing: keep, a published release of the tag on the target is the
# result of an earlier run, so nothing changes.
kept=0
if [[ "${EXISTING}" == "keep" ]]; then
  if output="$(gh release view "${tag}" --repo "${REPOSITORY}" --json isDraft --jq .isDraft 2>&1)"; then
    [[ "${output}" != "true" ]] ||
      die "release ${tag} is a draft. Publish or delete it, then run again."
    tag_commit="$(gh api "repos/${REPOSITORY}/commits/refs/tags/${tag}" --jq .sha 2>&1)" ||
      if [[ "${tag_commit}" == *"HTTP 404"* ]]; then
        die "release ${tag} exists, but tag ${tag} does not. Delete the release, then run again."
      else
        die "could not read the tag ${tag}: ${tag_commit}. Check that the token can read ${REPOSITORY}."
      fi
    target_commit="$(gh api "repos/${REPOSITORY}/commits/${TARGET}" --jq .sha 2>&1)" ||
      die "could not resolve target '${TARGET}': ${target_commit}. Pass a commit of ${REPOSITORY}."
    [[ "${tag_commit}" == "${target_commit}" ]] ||
      die "tag ${tag} is on ${tag_commit}, but target is ${target_commit}. Delete the release and the tag, or pass the commit that the tag is on."
    printf '%s: release %s already exists on %s. Nothing changed.\n' "${SCRIPT_NAME}" "${tag}" "${target_commit}" >&2
    kept=1
    ASSETS=""
  elif [[ "${output}" != *"release not found"* ]]; then
    die "could not check for the release ${tag}: ${output}. Check that the token can read ${REPOSITORY}."
  fi
fi

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

if [[ ${kept} -eq 0 ]]; then
  refuse_existing_release "${REPOSITORY}" "${tag}"
fi

rolling_tags=()
if [[ ${kept} -eq 0 ]]; then
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

  if [[ "${ROLLING}" == "true" ]]; then
    for ref in "${TAG_PREFIX}$(version_major "${VERSION}")" "${TAG_PREFIX}$(version_minor "${VERSION}")"; do
      # A backport must not move the rolling tag back from a higher release.
      released="$(gh api --paginate "repos/${REPOSITORY}/git/matching-refs/tags/${ref}." --jq '.[].ref')" ||
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
