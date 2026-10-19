# shellcheck shell=bash
# Helpers shared by the scripts of the bump, notes and release actions.
# Compatible with bash 3.2, which macOS runners use for `shell: bash`.

die() {
  if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
    printf '::error::%s\n' "$*" >&2
  else
    printf '%s: %s\n' "${SCRIPT_NAME:-release-actions}" "$*" >&2
  fi
  exit 1
}

warn() {
  if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
    printf '::warning::%s\n' "$*" >&2
  else
    printf '%s: %s\n' "${SCRIPT_NAME:-release-actions}" "$*" >&2
  fi
}

require_tools() {
  local tool
  for tool in "$@"; do
    if ! command -v "${tool}" >/dev/null 2>&1; then
      die "${tool} is not on PATH. Install it on the runner before this step."
    fi
  done
}

output_file() {
  printf '%s\n' "${GITHUB_OUTPUT:-/dev/stdout}"
}

set_output() {
  printf '%s=%s\n' "$1" "$2" >>"$(output_file)"
}

set_multiline_output() {
  local delimiter="RELEASE_ACTIONS_${RANDOM}${RANDOM}"
  {
    printf '%s<<%s\n' "$1" "${delimiter}"
    printf '%s\n' "$2"
    printf '%s\n' "${delimiter}"
  } >>"$(output_file)"
}

temp_dir() {
  printf '%s\n' "${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
}

# Heading of a released changelog section. bump writes it and notes reads it.
# shellcheck disable=SC2034 # Read by the scripts that source this file.
DEFAULT_CHANGELOG_HEADING='## {version} ({date})'

# Stops unless VALUE is true or false. NAME is the input name for the message.
require_bool() {
  case "$2" in
  true | false) ;;
  *) die "$1 is '$2'. Use true or false." ;;
  esac
}

# Stops unless PREFIX, the tag-prefix input, holds only characters that are
# safe in a tag, a branch name and a glob.
require_tag_prefix() {
  [[ "$1" =~ ^[A-Za-z0-9._-]*$ ]] || die "tag-prefix is '$1'. Use letters, digits, dots, hyphens or underscores."
}

# Prints VALUE, or today in UTC when VALUE is empty, after a YYYY-MM-DD check.
release_date() {
  local value="${1:-$(date -u +%Y-%m-%d)}"
  [[ "${value}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "date is '${value}'. Use YYYY-MM-DD."
  DATE_VALUE="${value}" perl -MTime::Local=timegm -e '
    my ($y, $m, $d) = split /-/, $ENV{DATE_VALUE};
    exit(eval { timegm(0, 0, 0, $d, $m - 1, $y); 1 } ? 0 : 1);
  ' || die "date is '${value}', which is not a calendar date. Use a real day in YYYY-MM-DD."
  printf '%s\n' "${value}"
}

# Fills the {name} placeholders of standard input from the FILL_name variables
# with lib/fill.pl. NAMES is the comma-separated list of allowed names, WHAT
# names the template in the error messages, and OPTIONAL lists the names that
# can be empty. Needs LIB.
fill_template() {
  local names="$1" what="$2" optional="${3:-}" file errors status=0 text allowed
  file="$(temp_dir)/fill-$$.err"
  text="$(perl "${LIB}/fill.pl" "${names}" "${optional}" 2>"${file}")" || status=$?
  errors="$(cat "${file}" 2>/dev/null || true)"
  rm -f "${file}"
  allowed="$(perl -e 'print join ", ", map { "{$_}" } split /,/, $ARGV[0]' -- "${names}")"
  case "${status}" in
  0) printf '%s\n' "${text}" ;;
  2) die "${what} has unknown placeholders: ${errors}. Use ${allowed}." ;;
  3) die "${what} uses ${errors}, but it has no value. Set the matching input." ;;
  *) die "could not fill ${what}." ;;
  esac
}

# Stops when the tag TAG, or a release named TAG, already exists in
# REPOSITORY, and on any answer other than "not found". GitHub answers "not
# found" for a draft release when the token cannot write to REPOSITORY.
# Needs gh.
refuse_existing_release() {
  local repository="$1" tag="$2" output
  if output="$(gh api "repos/${repository}/git/ref/tags/${tag}" --silent 2>&1)"; then
    die "tag ${tag} already exists. Bump to a new version, or delete the tag if a failed run left it."
  fi
  if [[ "${output}" != *"HTTP 404"* ]]; then
    die "could not check for the tag ${tag}: ${output}. Check that the token can read ${repository}."
  fi
  if output="$(gh release view "${tag}" --repo "${repository}" 2>&1 >/dev/null)"; then
    die "a release named ${tag} already exists, perhaps as a draft. Delete or publish it, then run again."
  fi
  if [[ "${output}" != *"release not found"* ]]; then
    die "could not check for the release ${tag}: ${output}. Check that the token can read ${repository}."
  fi
}
