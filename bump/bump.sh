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

BUMP="${BUMP:-}"
TARGETS="${TARGETS:-}"
VERSION_SOURCE="${VERSION_SOURCE:-target}"
TAG_PREFIX="${TAG_PREFIX:-}"
CHANGELOG="${CHANGELOG-CHANGELOG.md}"
CHANGELOG_HEADING="${CHANGELOG_HEADING:-}"
if [[ -z "${CHANGELOG_HEADING}" ]]; then
  CHANGELOG_HEADING='## {version} ({date})'
fi
ALLOW_EMPTY="${ALLOW_EMPTY:-false}"
RELEASE_DATE="${RELEASE_DATE:-}"
if [[ -z "${RELEASE_DATE}" ]]; then
  RELEASE_DATE="$(date -u +%Y-%m-%d)"
fi
placeholder_regex='\{(version|date|major)\}'

[[ -n "${BUMP}" ]] || die "bump is empty. Use patch, minor, major, calver, or a version such as 1.2.3."
[[ "${RELEASE_DATE}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "date is '${RELEASE_DATE}'. Use YYYY-MM-DD."
case "${ALLOW_EMPTY}" in
true | false) ;;
*) die "allow-empty is '${ALLOW_EMPTY}'. Use true or false." ;;
esac
[[ "${CHANGELOG_HEADING}" == *"{version}"* ]] || die "changelog-heading '${CHANGELOG_HEADING}' has no {version} placeholder."
require_tools perl yq

# Targets, as four lists with one entry per target.
t_file=()
t_pattern=()
t_source=()
t_required=()
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
  if yq -r '.[] | ((.file == "") or (.pattern == ""))' <<<"${TARGETS}" | grep -qx true; then
    die "every entry of targets needs file and pattern, as non-empty strings."
  fi
  # One field per line: @tsv would quote patterns that hold double quotes.
  while IFS= read -r file && IFS= read -r pattern && IFS= read -r source && IFS= read -r required; do
    t_file+=("${file}")
    t_pattern+=("${pattern}")
    t_source+=("${source}")
    t_required+=("${required}")
  done < <(yq -r '.[] | [.file, .pattern, (.source | tostring), (.required | tostring)] | .[]' <<<"${TARGETS}")
fi
n=${#t_file[@]}

source_index=-1
for ((i = 0; i < n; i++)); do
  if [[ ! "${t_pattern[i]}" =~ ${placeholder_regex} ]]; then
    die "target ${t_file[i]}: the pattern '${t_pattern[i]}' has no {version}, {date} or {major} placeholder."
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

# Every (file, pattern) pair to rewrite.
e_file=()
e_pattern=()
for ((i = 0; i < n; i++)); do
  matched_files=0
  while IFS= read -r path; do
    [[ -n "${path}" ]] || continue
    matched_files=$((matched_files + 1))
    count="$(perl "${LIB}/target.pl" find "${t_pattern[i]}" "${path}" | wc -l | tr -d ' ')"
    if [[ "${count}" -eq 0 ]]; then
      if [[ "${t_required[i]}" == "false" ]]; then
        continue
      fi
      die "${path}: no match for the pattern '${t_pattern[i]}'. Fix the pattern, or set required: false on this target."
    fi
    e_file+=("${path}")
    e_pattern+=("${t_pattern[i]}")
  done < <(compgen -G "${t_file[i]}" || true)
  if [[ ${matched_files} -eq 0 && "${t_required[i]}" != "false" ]]; then
    die "no file matches '${t_file[i]}'. Fix the path, or set required: false on this target."
  fi
done

# Current version.
case "${VERSION_SOURCE}" in
target)
  if [[ ${source_index} -lt 0 ]]; then
    for ((i = 0; i < n; i++)); do
      if [[ "${t_pattern[i]}" == *"{version}"* ]]; then
        source_index=${i}
        break
      fi
    done
  fi
  if [[ ${source_index} -lt 0 ]]; then
    die "no target has a {version} pattern to read the current version from. Add one, or set version-source: tag."
  fi
  source_files="$(compgen -G "${t_file[source_index]}" || true)"
  [[ -n "${source_files}" ]] || die "no file matches '${t_file[source_index]}', the source of the current version."
  if [[ "$(wc -l <<<"${source_files}" | tr -d ' ')" -ne 1 ]]; then
    die "'${t_file[source_index]}' matches several files. The source target must name one file."
  fi
  versions="$(perl "${LIB}/target.pl" find "${t_pattern[source_index]}" "${source_files}")"
  count="$(grep -c . <<<"${versions}" || true)"
  if [[ "${count}" -ne 1 ]]; then
    die "${source_files}: the source pattern '${t_pattern[source_index]}' matches ${count} times. It must match once; anchor it with ^ and \$."
  fi
  current="${versions}"
  ;;
tag)
  require_tools git
  current="$(git tag --list | PREFIX="${TAG_PREFIX}" perl -ne '
    chomp;
    next unless s/\A\Q$ENV{PREFIX}\E(?=[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9]+)?\z)//;
    push @versions, $_;
    END {
      my @sorted = sort {
        my @x = split /[.-]/, $a;
        my @y = split /[.-]/, $b;
        $x[3] //= 1;
        $y[3] //= 1;
        $x[0] <=> $y[0] || $x[1] <=> $y[1] || $x[2] <=> $y[2] || $x[3] <=> $y[3]
      } @versions;
      print $sorted[-1] if @sorted;
    }')"
  current="${current:-0.0.0}"
  ;;
*)
  die "version-source is '${VERSION_SOURCE}'. Use target or tag."
  ;;
esac

version="$(next_version "${current}" "${BUMP}" "${RELEASE_DATE}")"
core="${version%%-*}"
major="${core%%.*}"
minor="${core%.*}"

# Changelog.
notes_file="$(temp_dir)/release-notes-${version}.md"
: >"${notes_file}"
heading="${CHANGELOG_HEADING//"{version}"/${version}}"
heading="${heading//"{date}"/${RELEASE_DATE}}"
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
  if [[ -z "$(tr -d '[:space:]' <"${notes_file}")" && "${ALLOW_EMPTY}" != "true" ]]; then
    die "the Unreleased section of ${CHANGELOG} is empty. Add entries under it, or set allow-empty: true."
  fi
  if tr -d '\r' <"${CHANGELOG}" | grep -qxF "${heading}"; then
    die "${CHANGELOG} already has the heading '${heading}'. Was this version released already?"
  fi
fi

# Writes.
changed=()
export VERSION="${version}" DATE="${RELEASE_DATE}" MAJOR="${major}"
for ((i = 0; i < ${#e_file[@]}; i++)); do
  perl "${LIB}/target.pl" replace "${e_pattern[i]}" "${e_file[i]}" >/dev/null
  changed+=("${e_file[i]}")
done
if [[ -n "${CHANGELOG}" ]]; then
  HEADING="${heading}" perl -i -pe '
    if (!$done && /\A## (Unreleased|\[Unreleased\])[ \t]*\r?$/) {
      $_ = "## $1\n\n$ENV{HEADING}\n";
      $done = 1;
    }' "${CHANGELOG}"
  changed+=("${CHANGELOG}")
fi
files="$(printf '%s\n' ${changed[@]+"${changed[@]}"} | LC_ALL=C sort -u | sed '/^$/d')"

set_output version "${version}"
set_output previous "${current}"
set_output major "${major}"
set_output minor "${minor}"
set_output date "${RELEASE_DATE}"
set_output notes-file "${notes_file}"
set_multiline_output files "${files}"
printf 'Bumped %s to %s.\n' "${current}" "${version}" >&2
