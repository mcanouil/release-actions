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
