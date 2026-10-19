# shellcheck shell=bash
# Presets of the ecosystems input: named sets of targets for well-known
# manifests. Needs lib/common.sh. Compatible with bash 3.2.

ECOSYSTEM_LIST="citation, npm, cargo, typst, quarto-extension, r"

# Prints each name of the comma-separated LIST on a line of its own. Spaces,
# newlines and empty items are ignored. Stops on an unknown name.
ecosystem_names() {
  local list="${1//$'\n'/,}" item items
  IFS=',' read -r -a items <<<"${list}"
  for item in ${items[@]+"${items[@]}"}; do
    item="${item#"${item%%[![:space:]]*}"}"
    item="${item%"${item##*[![:space:]]}"}"
    [[ -n "${item}" ]] || continue
    case "${item}" in
    citation | npm | cargo | typst | quarto-extension | r) printf '%s\n' "${item}" ;;
    *) die "unknown ecosystem '${item}'. Use ${ECOSYSTEM_LIST}." ;;
    esac
  done
}

# Prints one YAML target item for FILE and PATTERN, in single-quoted scalars.
# The optional SECTION limits the pattern to the lines under that header.
ecosystem_item() {
  local quote="'" double="''"
  printf -- "- file: '%s'\n  pattern: '%s'\n" "${1//${quote}/${double}}" "${2//${quote}/${double}}"
  if [[ -n "${3:-}" ]]; then
    printf "  section: '%s'\n" "${3//${quote}/${double}}"
  fi
}

# Prints the quote character around the value of the first KEY line of FILE,
# or nothing when the value is plain or FILE is missing.
ecosystem_quote() {
  local line
  [[ -f "$2" ]] || return 0
  line="$(grep -m 1 "^$1:" "$2" || true)"
  case "${line#"$1":}" in
  *\"*) printf '"' ;;
  *\'*) printf "'" ;;
  esac
}

# Prints the indentation of the top-level "version" key of the package.json
# FILE: the shortest indentation among its "version" lines, since a nested one
# sits deeper. Prints two spaces when FILE is missing or has none.
ecosystem_json_indent() {
  local indent=""
  if [[ -f "$1" ]]; then
    indent="$(LC_ALL=C awk '
      match($0, /^[ \t]+"version": "/) && (best == "" || RLENGTH < blen) {
        best = substr($0, 1, RLENGTH - 12); blen = RLENGTH; found = 1
      }
      END { if (found) print best }' "$1")"
  fi
  printf '%s' "${indent:-  }"
}

# Prints the YAML target items of each preset in NAMES, in order. The first
# item of a preset that names a manifest is its version line.
ecosystem_targets() {
  local name quote manifests count
  for name in "$@"; do
    case "${name}" in
    citation)
      quote="$(ecosystem_quote version CITATION.cff)"
      ecosystem_item CITATION.cff "^version: ${quote}{version}${quote}\$"
      quote="$(ecosystem_quote date-released CITATION.cff)"
      ecosystem_item CITATION.cff "^date-released: ${quote}{date}${quote}\$"
      ;;
    npm)
      ecosystem_item package.json "^$(ecosystem_json_indent package.json)\"version\": \"{version}\",\$"
      ;;
    cargo)
      ecosystem_item Cargo.toml '^version = "{version}"$' '[package]'
      ;;
    typst)
      ecosystem_item typst.toml '^version = "{version}"$'
      ;;
    quarto-extension)
      # One level deep only: vendored extensions sit at _extensions/<owner>/<name>/.
      manifests="$({ compgen -G '_extensions/*/_extension.yml' || true; } | LC_ALL=C sort)"
      count="$(grep -c . <<<"${manifests}" || true)"
      if [[ "${count}" -eq 0 ]]; then
        die "quarto-extension: no file matches '_extensions/*/_extension.yml'. Run bump at the root of the extension repository."
      fi
      if [[ "${count}" -gt 1 ]]; then
        die "quarto-extension needs exactly one '_extensions/*/_extension.yml', but found ${manifests//$'\n'/ and }. List the version targets in targets instead."
      fi
      ecosystem_item '_extensions/*/_extension.yml' '^version: {version}$'
      ;;
    r)
      ecosystem_item DESCRIPTION '^Version: {version}$'
      ;;
    *) die "unknown ecosystem '${name}'. Use ${ECOSYSTEM_LIST}." ;;
    esac
  done
}

# Prints the command that each preset in NAMES runs after the version is
# written, one per line. The target-only presets print nothing.
ecosystem_commands() {
  local name
  for name in "$@"; do
    case "${name}" in
    citation | typst | quarto-extension | r) ;;
    npm)
      # Refreshes the root entry of the lock file without a network call.
      if [[ -f package-lock.json ]]; then
        printf '%s\n' 'npm install --package-lock-only --ignore-scripts --offline || npm install --package-lock-only --ignore-scripts'
      fi
      ;;
    cargo)
      printf '%s\n' 'cargo update --workspace --offline || cargo update --workspace'
      ;;
    *) die "unknown ecosystem '${name}'. Use ${ECOSYSTEM_LIST}." ;;
    esac
  done
}

# Prints the preset in NAMES that holds the current version: the first one
# that names a manifest, else citation when it is listed. Prints nothing for
# an empty list.
ecosystem_source() {
  local name
  for name in "$@"; do
    case "${name}" in
    npm | cargo | typst | quarto-extension | r)
      printf '%s\n' "${name}"
      return 0
      ;;
    esac
  done
  for name in "$@"; do
    if [[ "${name}" == "citation" ]]; then
      printf '%s\n' "${name}"
      return 0
    fi
  done
}
