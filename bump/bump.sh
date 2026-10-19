#!/usr/bin/env bash
# Writes the next version to the target files and rolls the changelog. The
# inputs of bump/action.yml arrive as environment variables. Every check runs
# before the first write, so a failure leaves the working tree as it was.
set -euo pipefail

# shellcheck disable=SC2034 # Read by die in lib/common.sh.
SCRIPT_NAME=bump
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
# shellcheck disable=SC1091 # lib/common.sh is linted as a file of its own.
source "${LIB}/common.sh"
# shellcheck disable=SC1091 # lib/version.sh is linted as a file of its own.
source "${LIB}/version.sh"
# shellcheck disable=SC1091 # lib/ecosystems.sh is linted as a file of its own.
source "${LIB}/ecosystems.sh"

BUMP="${BUMP:-}"
ECOSYSTEMS="${ECOSYSTEMS:-}"
TARGETS="${TARGETS:-}"
VERSION_SOURCE="${VERSION_SOURCE:-target}"
TAG_PREFIX="${TAG_PREFIX:-}"
CHANGELOG="${CHANGELOG-CHANGELOG.md}"
CHANGELOG_HEADING="${CHANGELOG_HEADING:-${DEFAULT_CHANGELOG_HEADING}}"
ALLOW_EMPTY="${ALLOW_EMPTY:-false}"
AFTER_BUMP="${AFTER_BUMP:-}"
REPOSITORY="${GITHUB_REPOSITORY:-}"
placeholder_regex='\{(version|date|major)\}'

[[ -n "${BUMP}" ]] || die "bump is empty. Use patch, minor, major, calver, or a version such as 1.2.3."
require_tools perl yq gh
RELEASE_DATE="$(release_date "${RELEASE_DATE:-}")"
# Said when the files already hold a version that a failed run bumped.
unreleased_hint="Create release {version} on the commit that bumped it, or revert that commit with a pull request, then dispatch again."
require_bool allow-empty "${ALLOW_EMPTY}"
[[ "${CHANGELOG_HEADING}" == *"{version}"* ]] || die "changelog-heading '${CHANGELOG_HEADING}' has no {version} placeholder."
[[ -n "${REPOSITORY}" ]] || die "GITHUB_REPOSITORY is not set."
require_tag_prefix "${TAG_PREFIX}"

# Targets, as four lists with one entry per target: the targets of the
# presets in ecosystems first, then the caller's targets.
t_file=()
t_pattern=()
t_source=()
t_required=()
t_section=()
# The preset that a target comes from, empty for the caller's targets.
t_preset=()
current_preset=""

# Adds the entries of the YAML target list ITEMS to the four lists.
add_targets() {
  local file pattern source required section
  # One field per line: @tsv would quote patterns that hold double quotes.
  while IFS= read -r file && IFS= read -r pattern && IFS= read -r source && IFS= read -r required && IFS= read -r section; do
    if [[ -z "${file}" || -z "${pattern}" ]]; then
      die "every entry of targets needs file and pattern, as non-empty strings."
    fi
    t_file+=("${file}")
    t_pattern+=("${pattern}")
    t_source+=("${source}")
    t_required+=("${required}")
    t_section+=("${section}")
    t_preset+=("${current_preset}")
  done < <(yq -r '.[] | [.file, .pattern, (.source | tostring), (.required | tostring), (.section // "")] | .[]' <<<"$1")
}

ecosystems=()
names="$(ecosystem_names "${ECOSYSTEMS}")"
while IFS= read -r name; do
  [[ -z "${name}" ]] || ecosystems+=("${name}")
done <<<"${names}"
# Index of the version target of the preset that holds the current version.
preset_source_index=-1
if [[ ${#ecosystems[@]} -gt 0 ]]; then
  source_preset="$(ecosystem_source "${ecosystems[@]}")"
  for name in "${ecosystems[@]}"; do
    if [[ ${preset_source_index} -lt 0 && "${name}" == "${source_preset}" ]]; then
      preset_source_index=${#t_file[@]}
    fi
    items="$(ecosystem_targets "${name}")"
    current_preset="${name}"
    add_targets "${items}"
    current_preset=""
  done
fi
preset_count=${#t_file[@]}

# The commands of the presets, one per line, run before after-bump.
preset_commands=""
if [[ ${#ecosystems[@]} -gt 0 ]]; then
  preset_commands="$(ecosystem_commands "${ecosystems[@]}")"
fi
if [[ -n "${AFTER_BUMP}" || -n "${preset_commands}" ]]; then
  require_tools git
  while IFS=' ' read -r tool _; do
    [[ -z "${tool}" ]] || require_tools "${tool}"
  done <<<"${preset_commands}"
  git rev-parse --verify -q HEAD >/dev/null 2>&1 ||
    die "after-bump needs a git checkout with a commit, to list the files that it changes, and so do the commands of the ecosystems presets. Run bump after actions/checkout."
fi

if [[ -n "${TARGETS//[[:space:]]/}" ]]; then
  if [[ "$(yq -r 'tag' <<<"${TARGETS}" 2>/dev/null || true)" != "!!seq" ]]; then
    die "targets is not a YAML list. Write one '- file: ...' entry per target."
  fi
  # yq reads a "!!null" literal as a tag, and select drops entries with
  # missing keys, so each entry prints its tags and bash compares them.
  if yq -r '.[] | tag' <<<"${TARGETS}" | grep -qvx '!!map'; then
    die "every entry of targets must be a mapping with file and pattern."
  fi
  unknown="$(yq -r '.[] | keys | .[]' <<<"${TARGETS}" | grep -vxE 'file|pattern|source|required' | sed -n 1p || true)"
  [[ -z "${unknown}" ]] || die "targets has the unknown key '${unknown}'. Use file, pattern, source and required."
  while IFS=$'\t' read -r file_tag pattern_tag source_tag required_tag; do
    if [[ "${file_tag}" != "!!str" || "${pattern_tag}" != "!!str" ]]; then
      die "every entry of targets needs file and pattern, as non-empty strings."
    fi
    if [[ ! "${source_tag}" =~ ^!!(null|bool)$ ]]; then
      die "source must be true or false in every entry of targets."
    fi
    if [[ ! "${required_tag}" =~ ^!!(null|bool)$ ]]; then
      die "required must be true or false in every entry of targets."
    fi
  done < <(yq -r '.[] | [(.file | tag), (.pattern | tag), (.source | tag), (.required | tag)] | @tsv' <<<"${TARGETS}")
  add_targets "${TARGETS}"
fi
n=${#t_file[@]}

source_index=-1
first_version_index=-1
for ((i = 0; i < n; i++)); do
  if [[ ! "${t_pattern[i]}" =~ ${placeholder_regex} ]]; then
    die "target ${t_file[i]}: the pattern '${t_pattern[i]}' has no {version}, {date} or {major} placeholder."
  fi
  if [[ ${first_version_index} -lt 0 && "${t_pattern[i]}" == *"{version}"* ]]; then
    first_version_index=${i}
  fi
  if [[ "${t_source[i]}" == "true" ]]; then
    if [[ ${source_index} -ge 0 ]]; then
      die "targets ${t_file[source_index]} and ${t_file[i]} both set source: true. Keep it on one."
    fi
    if [[ "${t_pattern[i]}" != *"{version}"* ]]; then
      die "target ${t_file[i]} sets source: true, but its pattern has no {version}."
    fi
    source_index=${i}
  fi
done
# A caller target with source: true overrides the presets.
if [[ ${source_index} -lt 0 ]]; then
  source_index=${preset_source_index}
fi

# Every (file, pattern) pair to rewrite, with the index of its target.
e_file=()
e_pattern=()
e_target=()
e_section=()

# Prints PATTERN as the line it expects, without its anchors, such as
# "version: X.Y.Z" for "^version: {version}$".
expected_line() {
  local line="${1#^}"
  line="${line%$}"
  line="${line//\{version\}/X.Y.Z}"
  line="${line//\{date\}/YYYY-MM-DD}"
  printf '%s\n' "${line//\{major\}/X}"
}

for ((i = 0; i < n; i++)); do
  matched_files=0
  while IFS= read -r path; do
    [[ -n "${path}" ]] || continue
    matched_files=$((matched_files + 1))
    count="$(perl "${LIB}/target.pl" find "${t_pattern[i]}" "${path}" "${t_section[i]}" | wc -l | tr -d ' ')"
    if [[ "${count}" -eq 0 ]]; then
      if [[ "${t_required[i]}" == "false" ]]; then
        continue
      fi
      if [[ -n "${t_preset[i]}" ]]; then
        die "${path}: the ${t_preset[i]} preset found no line that matches '${t_pattern[i]}'${t_section[i]:+ under ${t_section[i]}}. Add a line such as '$(expected_line "${t_pattern[i]}")' to the file."
      fi
      die "${path}: no line matches '${t_pattern[i]}'. Add a line such as '$(expected_line "${t_pattern[i]}")', or set required: false on this target if the file can lack it."
    fi
    e_file+=("${path}")
    e_pattern+=("${t_pattern[i]}")
    e_target+=("${i}")
    e_section+=("${t_section[i]}")
  done < <(compgen -G "${t_file[i]}" || true)
  if [[ ${matched_files} -eq 0 && "${t_required[i]}" != "false" ]]; then
    die "no file matches '${t_file[i]}'. Fix the path, or set required: false on this target."
  fi
done

# A file and pattern written twice, such as by a caller target that a preset
# writes too. The paths are compared after glob expansion, so a literal path
# and a glob that matches it count as the same file.
if [[ ${#ecosystems[@]} -gt 0 ]]; then
  for ((i = 0; i < ${#e_file[@]}; i++)); do
    for ((j = i + 1; j < ${#e_file[@]}; j++)); do
      if [[ "${e_file[i]}" == "${e_file[j]}" && "${e_pattern[i]}" == "${e_pattern[j]}" ]]; then
        if [[ ${e_target[i]} -lt ${preset_count} && ${e_target[j]} -ge ${preset_count} ]]; then
          die "the target ${e_file[i]} with the pattern '${e_pattern[i]}' is listed twice. Remove it from targets, since a preset in ecosystems already writes it."
        fi
        die "the target ${e_file[i]} with the pattern '${e_pattern[i]}' is listed twice. Keep one."
      fi
    done
  done
fi

# Current version.
case "${VERSION_SOURCE}" in
target)
  if [[ ${source_index} -lt 0 ]]; then
    source_index=${first_version_index}
  fi
  if [[ ${source_index} -lt 0 ]]; then
    die "no target has a {version} pattern to read the current version from. Add one, or set version-source: tag."
  fi
  source_files="$(compgen -G "${t_file[source_index]}" || true)"
  [[ -n "${source_files}" ]] || die "no file matches '${t_file[source_index]}', the source of the current version."
  if [[ "$(wc -l <<<"${source_files}" | tr -d ' ')" -ne 1 ]]; then
    die "'${t_file[source_index]}' matches several files. The source target must name one file."
  fi
  versions="$(perl "${LIB}/target.pl" find "${t_pattern[source_index]}" "${source_files}" "${t_section[source_index]}")"
  count="$(grep -c . <<<"${versions}" || true)"
  if [[ "${count}" -ne 1 ]]; then
    die "${source_files}: the source pattern '${t_pattern[source_index]}' matches ${count} times. It must match once; anchor it with ^ and \$."
  fi
  current="${versions}"
  ;;
tag)
  require_tools git
  current="$(latest_tag "${TAG_PREFIX}")"
  ;;
*)
  die "version-source is '${VERSION_SOURCE}'. Use target or tag."
  ;;
esac

version="$(next_version "${current}" "${BUMP}" "${RELEASE_DATE}")"
major="$(version_major "${version}")"
minor="$(version_minor "${version}")"

# Changelog.
notes_file="$(temp_dir)/release-notes-${version}.md"
: >"${notes_file}"
heading="$(printf '%s' "${CHANGELOG_HEADING}" | FILL_version="${version}" FILL_date="${RELEASE_DATE}" fill_template version,date changelog-heading)"
if [[ -n "${CHANGELOG}" ]]; then
  if [[ ! -f "${CHANGELOG}" ]]; then
    die "${CHANGELOG} does not exist. Create it with a '## Unreleased' heading, or set changelog to an empty string."
  fi
  status=0
  perl "${LIB}/section.pl" unreleased "${CHANGELOG}" >"${notes_file}" || status=$?
  case "${status}" in
  0) ;;
  2) die "${CHANGELOG} has no '## Unreleased' or '## [Unreleased]' heading. Add one above the last release." ;;
  3) die "${CHANGELOG} has more than one Unreleased heading. Keep one." ;;
  *) die "could not read ${CHANGELOG}." ;;
  esac
  status=0
  perl "${LIB}/section.pl" version "${CHANGELOG}" "${CHANGELOG_HEADING}" "${version}" >/dev/null || status=$?
  case "${status}" in
  2) ;;
  0 | 3) die "${CHANGELOG} already has the heading '${heading}'. If release ${TAG_PREFIX}${version} does not exist, a run bumped it and failed. ${unreleased_hint/\{version\}/${TAG_PREFIX}${version}}" ;;
  *) die "could not read ${CHANGELOG}." ;;
  esac
  if [[ -z "$(tr -d '[:space:]' <"${notes_file}")" && "${ALLOW_EMPTY}" != "true" ]]; then
    die "the Unreleased section of ${CHANGELOG} is empty. Add entries under it, or set allow-empty: true."
  fi
fi

# The release step checks this too, but only after the bump has landed.
refuse_existing_release "${REPOSITORY}" "${TAG_PREFIX}${version}"

# Files that hold a version above the latest release hold a bump that a failed
# run landed; bumping again would skip that version. The tags come from the API,
# since a checkout holds none by default.
if [[ "${VERSION_SOURCE}" == "target" ]]; then
  refs="$(gh api --paginate "repos/${REPOSITORY}/git/matching-refs/tags/${TAG_PREFIX}" --jq '.[].ref' 2>&1)" ||
    die "could not list the tags of ${REPOSITORY}: ${refs}. Check that the token can read ${REPOSITORY}."
  released="$(printf '%s\n' "${refs//refs\/tags\//}" | highest_version "${TAG_PREFIX}")"
  if [[ -n "${released}" && "${released}" != "${current}" &&
    "$(printf '%s\n%s\n' "${released}" "${current}" | highest_version "")" == "${current}" ]]; then
    die "${source_files} holds ${current}, which has no release. ${unreleased_hint/\{version\}/${TAG_PREFIX}${current}}"
  fi
fi

# Writes.
export VERSION="${version}" DATE="${RELEASE_DATE}" MAJOR="${major}"
for ((i = 0; i < ${#e_file[@]}; i++)); do
  perl "${LIB}/target.pl" replace "${e_pattern[i]}" "${e_file[i]}" "${e_section[i]}" >/dev/null
done
if [[ -n "${CHANGELOG}" ]]; then
  HEADING="${heading}" perl "${LIB}/section.pl" roll "${CHANGELOG}"
fi
# Prints each path that differs from HEAD, staged or not, with the hash of its
# content, or "-" for a deleted path.
tree_state() {
  local path
  { git -c core.quotePath=false diff --name-only HEAD &&
    git -c core.quotePath=false ls-files --others --exclude-standard; } | LC_ALL=C sort -u |
    while IFS= read -r path; do
      if [[ -e "${path}" ]]; then
        printf '%s %s\n' "${path}" "$(git hash-object -- "${path}")"
      else
        printf '%s -\n' "${path}"
      fi
    done | LC_ALL=C sort
}

# Only what after-bump changes joins files: earlier steps of the job can leave
# other changes in the tree.
changed=""
if [[ -n "${AFTER_BUMP}" || -n "${preset_commands}" ]]; then
  before="$(tree_state)" || die "could not read the state of the tree before after-bump."
  while IFS= read -r command; do
    [[ -n "${command}" ]] || continue
    bash -euo pipefail -c "${command}" ||
      die "the command of an ecosystems preset failed: ${command}. The version is written but nothing is committed; fix the command and dispatch again."
  done <<<"${preset_commands}"
  if [[ -n "${AFTER_BUMP}" ]]; then
    bash -euo pipefail -c "${AFTER_BUMP}" ||
      die "after-bump failed: ${AFTER_BUMP}. The version is written but nothing is committed; fix the command and dispatch again."
  fi
  after="$(tree_state)" || die "could not list the files that after-bump changed."
  changed="$(LC_ALL=C comm -13 <(printf '%s\n' "${before}") <(printf '%s\n' "${after}") | sed 's/ [^ ]*$//')"
fi
files="$(printf '%s\n' ${e_file[@]+"${e_file[@]}"} ${CHANGELOG:+"${CHANGELOG}"} "${changed}" | LC_ALL=C sort -u | sed '/^$/d')"

set_output version "${version}"
set_output previous "${current}"
set_output major "${major}"
set_output minor "${minor}"
set_output date "${RELEASE_DATE}"
set_output notes-file "${notes_file}"
set_multiline_output files "${files}"
printf 'Bumped %s to %s.\n' "${current}" "${version}" >&2
