#!/usr/bin/env bash
# Composes a release body: an optional header template, the changelog section
# under a heading, and the notes that GitHub generates. The inputs of
# notes/action.yml arrive as environment variables.
set -euo pipefail

# shellcheck disable=SC2034 # Read by die in lib/common.sh.
SCRIPT_NAME=notes
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
# shellcheck disable=SC1091 # lib/common.sh is linted as a file of its own.
source "${LIB}/common.sh"

NOTES_FILE="${NOTES_FILE:-}"
VERSION="${VERSION:-}"
CHANGELOG="${CHANGELOG:-CHANGELOG.md}"
CHANGELOG_HEADING="${CHANGELOG_HEADING:-${DEFAULT_CHANGELOG_HEADING}}"
HEADER="${HEADER:-}"
SECTION_HEADING="${SECTION_HEADING-## Changelog}"
GENERATE_NOTES="${GENERATE_NOTES:-false}"
TAG="${TAG:-}"
TARGET="${TARGET:-${GITHUB_SHA:-}}"
PREVIOUS_TAG="${PREVIOUS_TAG:-}"
REPOSITORY="${GITHUB_REPOSITORY:-}"
MAX_LENGTH=125000

require_tools perl
require_bool generate-notes "${GENERATE_NOTES}"
RELEASE_DATE="$(release_date "${RELEASE_DATE:-}")"
[[ -n "${NOTES_FILE}" || -n "${VERSION}" ]] || die "set notes-file, or version to read the section from ${CHANGELOG}."

# Section.
if [[ -n "${NOTES_FILE}" ]]; then
  [[ -f "${NOTES_FILE}" ]] || die "notes-file ${NOTES_FILE} does not exist. Pass the notes-file output of the bump action."
  section="$(cat "${NOTES_FILE}")"
else
  [[ -f "${CHANGELOG}" ]] || die "${CHANGELOG} does not exist."
  status=0
  section="$(perl "${LIB}/section.pl" version "${CHANGELOG}" "${CHANGELOG_HEADING}" "${VERSION}")" || status=$?
  case "${status}" in
  0) ;;
  2) die "${CHANGELOG} has no heading for ${VERSION} in the form '${CHANGELOG_HEADING}'." ;;
  3) die "${CHANGELOG} has more than one heading for ${VERSION}." ;;
  *) die "could not read ${CHANGELOG}." ;;
  esac
fi

# Header.
header=""
if [[ -n "${HEADER}" ]]; then
  [[ -f "${HEADER}" ]] || die "header ${HEADER} does not exist."
  # shellcheck disable=SC2094 # The second argument only names the file in messages.
  header="$(FILL_version="${VERSION}" FILL_tag="${TAG}" FILL_date="${RELEASE_DATE}" FILL_repository="${REPOSITORY}" \
    fill_template version,tag,date,repository "${HEADER}" <"${HEADER}")"
fi

# Generated notes.
generated=""
if [[ "${GENERATE_NOTES}" == "true" ]]; then
  require_tools gh
  [[ -n "${TAG}" ]] || die "generate-notes needs tag, the tag of the release."
  [[ -n "${TARGET}" ]] || die "generate-notes needs target, the commit of the release."
  [[ -n "${REPOSITORY}" ]] || die "GITHUB_REPOSITORY is not set."
  if [[ -z "${PREVIOUS_TAG}" ]]; then
    PREVIOUS_TAG="$(gh api "repos/${REPOSITORY}/releases/latest" --jq .tag_name 2>/dev/null || true)"
  fi
  args=(api --method POST "repos/${REPOSITORY}/releases/generate-notes" -f "tag_name=${TAG}" -f "target_commitish=${TARGET}")
  if [[ -n "${PREVIOUS_TAG}" ]]; then
    args+=(-f "previous_tag_name=${PREVIOUS_TAG}")
  fi
  generated="$(gh "${args[@]}" --jq .body)" ||
    die "GitHub could not generate notes for ${TAG} at ${TARGET}. Check that the token can read ${REPOSITORY}."
fi

# Body.
body="$(temp_dir)/release-body.md"
: >"${body}"
append() {
  if [[ -s "${body}" ]]; then
    printf '\n' >>"${body}"
  fi
  printf '%s\n' "$1" >>"${body}"
}
if [[ -n "${header//[[:space:]]/}" ]]; then
  append "${header}"
fi
if [[ -n "${section//[[:space:]]/}" ]]; then
  if [[ -n "${SECTION_HEADING}" ]]; then
    append "${SECTION_HEADING}"$'\n\n'"${section}"
  else
    append "${section}"
  fi
fi
if [[ -n "${generated//[[:space:]]/}" ]]; then
  append "${generated}"
fi

length="$(wc -m <"${body}" | tr -d ' ')"
if [[ "${length}" -gt ${MAX_LENGTH} ]]; then
  die "the release body is ${length} characters, and GitHub allows ${MAX_LENGTH}. Shorten the section or the header, or turn off generate-notes."
fi
set_output body-file "${body}"
