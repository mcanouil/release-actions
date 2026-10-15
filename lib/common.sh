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

# Prints VALUE, or today in UTC when VALUE is empty, after a YYYY-MM-DD check.
release_date() {
  local value="${1:-$(date -u +%Y-%m-%d)}"
  [[ "${value}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "date is '${value}'. Use YYYY-MM-DD."
  printf '%s\n' "${value}"
}

# Fills the {name} placeholders of standard input from the FILL_name variables
# with lib/fill.pl. NAMES is the comma-separated list of allowed names, and
# WHAT names the template in the error messages. Needs LIB.
fill_template() {
  local names="$1" what="$2" errors status=0 text allowed
  errors="$(temp_dir)/fill-$$.err"
  text="$(perl "${LIB}/fill.pl" "${names}" 2>"${errors}")" || status=$?
  allowed="$(perl -e 'print join ", ", map { "{$_}" } split /,/, $ARGV[0]' -- "${names}")"
  case "${status}" in
  0) printf '%s\n' "${text}" ;;
  2) die "${what} has unknown placeholders: $(cat "${errors}"). Use ${allowed}." ;;
  3) die "${what} uses $(cat "${errors}"), but it has no value. Set the matching input." ;;
  *) die "could not fill ${what}." ;;
  esac
}
