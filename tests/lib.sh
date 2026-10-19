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

# Puts a fake gh first on PATH, for repository o/r, whose default branch is
# GH_DEFAULT_BRANCH (default main). The tags in GH_TAGS (one
# per line) exist, GH_RELEASE_EXISTS adds a release, GH_DOWN fails every call
# as a token or network error would, GH_RELEASE_DOWN fails only the release
# lookup, GH_RELEASE_DRAFT=true makes that release a draft, GH_TAG_COMMIT is the
# commit that every existing tag points at, GH_RESOLVE_FROM resolves to
# GH_RESOLVE_TO as a commit (any other ref resolves to itself), and GH_LOG, when set, records each call. Every App bot has the user
# id 123, and every token belongs to octo, with the user id 456.
# For pull requests: GH_STALE_PR is the open pull request of the head branch,
# as "<number> <url>",
# GH_LABELS a file of label names, GH_MERGE_FAILS fails gh pr merge, and each
# gh pr view prints the next line of the file GH_PR_SCRIPT, repeating the last
# one. A line "!fail" fails that call, and {branch-sha} stands for the commit
# of GH_HEAD_BRANCH (default release/v1.5.0) in the bare repository
# GH_ORIGIN.
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
"api repos/o/r/git/matching-refs/tags/"* | "api --paginate repos/o/r/git/matching-refs/tags/"*)
  args="$*"
  args="${args/--paginate /}"
  prefix="${args#api repos/o/r/git/matching-refs/tags/}"
  prefix="${prefix%% *}"
  # The API sorts the refs by name and serves 30 per page.
  pages=(head -n 30)
  [[ "$*" != *--paginate* ]] || pages=(cat)
  { grep "^${prefix}" "${GH_TAGS}" || true; } | LC_ALL=C sort | "${pages[@]}" | sed "s|^|refs/tags/|"
  ;;
"api repos/o/r --jq .default_branch"*)
  echo "${GH_DEFAULT_BRANCH:-main}"
  ;;
"api /users/"*)
  echo 123
  ;;
"api /user "*)
  echo "octo 456"
  ;;
"api repos/o/r/commits/refs/tags/"*)
  args="$*"
  tag="${args#api repos/o/r/commits/refs/tags/}"
  tag="${tag%% *}"
  if ! grep -qxF "${tag}" "${GH_TAGS}"; then
    echo "gh: No commit found for SHA: refs/tags/${tag} (HTTP 422)" >&2
    exit 1
  fi
  echo "${GH_TAG_COMMIT}"
  ;;
"api repos/o/r/commits/"*)
  args="$*"
  ref="${args#api repos/o/r/commits/}"
  ref="${ref%% *}"
  if [[ -n "${GH_RESOLVE_FROM:-}" && "${ref}" == "${GH_RESOLVE_FROM}" ]]; then
    echo "${GH_RESOLVE_TO}"
  else
    echo "${ref}"
  fi
  ;;
"release view"*"isDraft"*)
  if [[ -n "${GH_RELEASE_EXISTS:-}" ]]; then
    echo "${GH_RELEASE_DRAFT:-false}"
    exit 0
  fi
  echo "release not found" >&2
  exit 1
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
"pr list"*)
  [[ -z "${GH_STALE_PR:-}" ]] || echo "${GH_STALE_PR}"
  ;;
"pr create"* | "pr edit"*)
  if [[ -n "${GH_BAD_LABEL:-}" && "$*" == *"label ${GH_BAD_LABEL}"* ]]; then
    echo "could not add label: '${GH_BAD_LABEL}' not found" >&2
    exit 1
  fi
  case "$1 $2" in
  "pr create")
    echo "Creating pull request"
    echo "https://github.com/o/r/pull/7"
    ;;
  esac
  ;;
"pr view"*)
  pos=$(($(cat "${GH_PR_SCRIPT}.pos" 2>/dev/null || echo 0) + 1))
  total=$(wc -l <"${GH_PR_SCRIPT}")
  [[ ${pos} -le ${total} ]] || pos=${total}
  echo "${pos}" >"${GH_PR_SCRIPT}.pos"
  line="$(sed -n "${pos}p" "${GH_PR_SCRIPT}")"
  [[ "${line}" != "!fail" ]] || exit 1
  if [[ "${line}" == *"{branch-sha}"* ]]; then
    sha="$(git --git-dir="${GH_ORIGIN}" rev-parse "refs/heads/${GH_HEAD_BRANCH:-release/v1.5.0}")"
    line="${line/\{branch-sha\}/${sha}}"
  fi
  echo "${line}"
  ;;
"pr merge"*)
  if [[ -n "${GH_MERGE_FAILS:-}" ]]; then
    echo "Auto-merge is not allowed for this repository" >&2
    exit 1
  fi
  ;;
"label list"*)
  [[ -z "${GH_LABELS:-}" ]] || cat "${GH_LABELS}"
  ;;
*) exit 0 ;;
esac
EOF
  chmod +x "${SCRATCH}/bin/gh"
}

# Puts a fake npm and a fake cargo first on PATH. Each call records its
# arguments in PM_LOG as "<tool> <arguments>". PM_FAIL makes the call fail,
# or only the calls with --offline when it is "offline". PM_TOUCH names a file
# that the call rewrites, as a lock refresh does.
install_fake_pm() {
  local tool
  mkdir -p "${SCRATCH}/bin"
  export PATH="${SCRATCH}/bin:${PATH}"
  for tool in npm cargo; do
    cat >"${SCRATCH}/bin/${tool}" <<'EOF'
#!/usr/bin/env bash
printf '%s %s\n' "$(basename "$0")" "$*" >>"${PM_LOG}"
if [[ "${PM_FAIL:-}" == "all" || ("${PM_FAIL:-}" == "offline" && "$*" == *--offline*) ]]; then
  echo "$(basename "$0"): no network" >&2
  exit 1
fi
[[ -z "${PM_TOUCH:-}" ]] || printf 'refreshed %s\n' "${VERSION:-}" >"${PM_TOUCH}"
EOF
    chmod +x "${SCRATCH}/bin/${tool}"
  done
}

# Prints a PATH value with the commands that the scripts use, except TOOL, to
# test the message for a missing tool.
path_without() {
  local dir="${SCRATCH}/no-$1" name found
  if [[ ! -d "${dir}" ]]; then
    mkdir -p "${dir}"
    for name in awk bash basename cat cksum comm cut date dirname env find gh git grep head jq ln \
      mkdir mktemp mv perl rm sed sort tail tr uname wc yq; do
      [[ "${name}" != "$1" ]] || continue
      found="$(command -v "${name}")" || continue
      ln -s "${found}" "${dir}/${name}"
    done
  fi
  printf '%s\n' "${dir}"
}
