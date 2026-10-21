# shellcheck shell=bash
# Presets of the ecosystems input: named sets of targets for well-known
# manifests. Needs lib/common.sh. Compatible with bash 3.2.

ECOSYSTEM_LIST="citation, npm, cargo, typst, quarto-extension, r"

# Prints each name of the comma-separated LIST on a line of its own. Spaces,
# newlines and empty items are ignored. Stops on an unknown or repeated name.
ecosystem_names() {
  local list="${1//$'\n'/,}" item items seen=","
  IFS=',' read -r -a items <<<"${list}"
  for item in ${items[@]+"${items[@]}"}; do
    item="${item#"${item%%[![:space:]]*}"}"
    item="${item%"${item##*[![:space:]]}"}"
    [[ -n "${item}" ]] || continue
    case "${item}" in
    citation | npm | cargo | typst | quarto-extension | r) ;;
    *) die "unknown ecosystem '${item}'. Use ${ECOSYSTEM_LIST}." ;;
    esac
    [[ "${seen}" != *",${item},"* ]] || die "ecosystems lists ${item} twice. Keep one."
    seen="${seen}${item},"
    printf '%s\n' "${item}"
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

# Prints the quote character that opens the value of the first KEY line of
# FILE, or nothing when the value is plain or FILE is missing.
ecosystem_quote() {
  local value
  [[ -f "$2" ]] || return 0
  value="$(grep -m 1 "^$1:" "$2" || true)"
  value="${value#"$1":}"
  case "${value#"${value%%[![:space:]]*}"}" in
  \"*) printf '"' ;;
  \'*) printf "'" ;;
  esac
}

# Prints the pattern of the top-level "version" line of the package.json FILE,
# in the form the file uses: its indentation and a trailing comma or none. The
# top-level line is the "version" line with the shortest indentation, since a
# nested one sits deeper. A missing file gets two spaces and a comma, for the
# target checks to report. Stops when FILE has no top-level "version".
ecosystem_json_pattern() {
  local form="  |: |,"
  if [[ -f "$1" ]]; then
    [[ -n "$(yq -p json -r '.version // ""' "$1" 2>/dev/null || true)" ]] ||
      die "$1 has no top-level \"version\" key, which the npm preset writes. Add one, or remove npm from ecosystems."
    form="$(LC_ALL=C awk '
      match($0, /^[ \t]*"version"[ \t]*:[ \t]*"[^"]*"/) {
        indent = $0
        sub(/"version".*$/, "", indent)
        if (found && length(indent) >= best) next
        best = length(indent); found = 1
        key = $0
        sub(/^[ \t]*"version"/, "", key)
        sub(/"[^"]*".*$/, "", key)
        sep = key
        comma = ($0 ~ /"[ \t]*,[ \t\r]*$/) ? "," : ""
        line = indent "|" sep "|" comma
      }
      END { if (found) printf "%s", line }' "$1")"
    [[ -n "${form}" ]] ||
      die "$1 has \"version\" on a line with other keys, and the npm preset writes a \"version\" line of its own. Put one key on each line, as npm does, or list the target in targets instead of the npm preset."
  fi
  local indent="${form%%|*}" rest="${form#*|}"
  printf '^%s"version"%s"{version}"%s$' "${indent}" "${rest%%|*}" "${rest#*|}"
}

# Prints the pattern of the Version line of the DESCRIPTION file FILE, with
# the spaces or tabs that the file puts after "Version:". A missing file or
# line gets one space, for the target checks to report.
ecosystem_r_pattern() {
  local gap=" " line
  if [[ -f "$1" ]]; then
    line="$(grep -m 1 '^Version:[[:blank:]]' "$1" || true)"
    line="${line#Version:}"
    [[ -z "${line}" ]] || gap="${line%%[![:blank:]]*}"
  fi
  printf '^Version:%s{version}$' "${gap}"
}

# Prints the YAML target items of each preset in NAMES, in order. The first
# item of a preset that names a manifest is its version line.
ecosystem_targets() {
  local name quote manifests count pattern
  for name in "$@"; do
    case "${name}" in
    citation)
      quote="$(ecosystem_quote version CITATION.cff)"
      ecosystem_item CITATION.cff "^version: ${quote}{version}${quote}\$"
      quote="$(ecosystem_quote date-released CITATION.cff)"
      ecosystem_item CITATION.cff "^date-released: ${quote}{date}${quote}\$"
      ;;
    npm)
      pattern="$(ecosystem_json_pattern package.json)" || return 1
      ecosystem_item package.json "${pattern}"
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
      ecosystem_item DESCRIPTION "$(ecosystem_r_pattern DESCRIPTION)"
      # rig reads the version of a package from rproj.toml, when it has one.
      if [[ -f rproj.toml ]]; then
        ecosystem_item rproj.toml '^version = "{version}"$' '[project]'
      fi
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
        printf '%s\n' 'npm install --package-lock-only --ignore-scripts --no-audit --no-fund --offline || npm install --package-lock-only --ignore-scripts --no-audit --no-fund'
      fi
      ;;
    cargo)
      # A repository that tracks no Cargo.lock keeps none.
      if [[ -f Cargo.lock ]]; then
        printf '%s\n' 'cargo update --workspace --offline || cargo update --workspace'
      fi
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
