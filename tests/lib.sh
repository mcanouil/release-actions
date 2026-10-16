#!/usr/bin/env bash
# Assertions shared by the tests/test-*.sh files.
set -euo pipefail

SCRATCH="$(mktemp -d)"
trap 'rm -rf "${SCRATCH}"' EXIT
export SCRATCH

assert_eq() {
  if [[ "$1" != "$2" ]]; then
    printf '  %s: expected [%s], got [%s]\n' "$3" "$1" "$2" >&2
    exit 1
  fi
}

assert_contains() {
  if [[ "$1" != *"$2"* ]]; then
    printf '  %s: [%s] does not contain [%s]\n' "$3" "$1" "$2" >&2
    exit 1
  fi
}

assert_status() {
  if [[ "$1" -ne "$2" ]]; then
    printf '  %s: expected exit %s, got %s\n' "$3" "$1" "$2" >&2
    exit 1
  fi
}

# Prints the value of a NAME=VALUE line in a GITHUB_OUTPUT file.
output_value() {
  sed -n "s/^$1=//p" "$2"
}

# Prints the value of a NAME<<DELIMITER block in a GITHUB_OUTPUT file.
multiline_output() {
  awk -v name="$1" '
    !inside && index($0, name "<<") == 1 { delimiter = substr($0, length(name) + 3); inside = 1; next }
    inside && $0 == delimiter { exit }
    inside
  ' "$2"
}

# Checks that the last run (STATUS, ERR) failed with a message that contains
# NEEDLE. LABEL names the case.
refuses() {
  assert_status 1 "${STATUS}" "$2 fails"
  assert_contains "${ERR}" "$1" "$2 message"
}

# Puts a fake gh first on PATH, for repository o/r. The tags in GH_TAGS (one
# per line) exist, GH_RELEASE_EXISTS adds a release, GH_DOWN fails every call
# as a token or network error would, GH_RELEASE_DOWN fails only the release
# lookup, and GH_LOG, when set, records each call.
install_fake_gh() {
  mkdir -p "${SCRATCH}/bin"
  export PATH="${SCRATCH}/bin:${PATH}"
  cat >"${SCRATCH}/bin/gh" <<'EOF'
#!/usr/bin/env bash
if [[ -n "${GH_LOG:-}" ]]; then
  printf '%s\n' "$*" >>"${GH_LOG}"
fi
if [[ -n "${GH_DOWN:-}" ]]; then
  echo "HTTP 401: Bad credentials" >&2
  exit 1
fi
case "$*" in
"api repos/o/r/git/ref/tags/"*)
  args="$*"
  tag="${args#api repos/o/r/git/ref/tags/}"
  tag="${tag%% *}"
  grep -qxF "${tag}" "${GH_TAGS}" && exit 0
  echo "gh: Not Found (HTTP 404)" >&2
  exit 1
  ;;
"api repos/o/r/git/matching-refs/tags/"*)
  args="$*"
  prefix="${args#api repos/o/r/git/matching-refs/tags/}"
  prefix="${prefix%% *}"
  { grep "^${prefix}" "${GH_TAGS}" || true; } | sed "s|^|refs/tags/|"
  ;;
"release view"*"--json"*)
  printf 'https://github.com/o/r/releases/tag/v1.5.0\t42\n'
  ;;
"release view"*)
  if [[ -n "${GH_RELEASE_DOWN:-}" ]]; then
    echo "HTTP 502: Bad Gateway" >&2
    exit 1
  fi
  [[ -n "${GH_RELEASE_EXISTS:-}" ]] && exit 0
  echo "release not found" >&2
  exit 1
  ;;
*) exit 0 ;;
esac
EOF
  chmod +x "${SCRATCH}/bin/gh"
}
