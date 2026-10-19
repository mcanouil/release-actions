#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091 # tests/lib.sh is linted as a file of its own.
source "${ROOT}/tests/lib.sh"
# shellcheck disable=SC1091 # lib/common.sh is linted as a file of its own.
source "${ROOT}/lib/common.sh"
# shellcheck disable=SC1091 # lib/ecosystems.sh is linted as a file of its own.
source "${ROOT}/lib/ecosystems.sh"

# Runs a command in a subshell. Sets STATUS and ERR, which refuses reads.
run() {
  # shellcheck disable=SC2034 # Read by refuses in tests/lib.sh.
  STATUS=0
  # shellcheck disable=SC2034 # Read by refuses in tests/lib.sh.
  ERR="$("$@" 2>&1 >/dev/null)" || STATUS=$?
}

# Names.
assert_eq $'cargo\ncitation' "$(ecosystem_names "cargo, , citation,")" "empty items ignored"
assert_eq $'typst\ncitation' "$(ecosystem_names $' typst ,\n citation\n')" "spaces and newlines ignored"
assert_eq "" "$(ecosystem_names "")" "empty list"
assert_eq "" "$(ecosystem_names " , ")" "only separators"
run ecosystem_names "typst, foo"
refuses "unknown ecosystem 'foo'" "unknown name"
assert_contains "${ERR}" "citation, npm, cargo, typst, quarto-extension, r" "unknown name lists the names"

# Source.
assert_eq "citation" "$(ecosystem_source citation)" "citation alone is the source"
assert_eq "typst" "$(ecosystem_source citation typst)" "a manifest preset wins over citation"
assert_eq "quarto-extension" "$(ecosystem_source quarto-extension typst)" "first manifest preset in list order"
assert_eq "r" "$(ecosystem_source r citation)" "r is a manifest preset"
assert_eq "" "$(ecosystem_source)" "no preset, no source"

# Commands: none for the target-only presets.
assert_eq "" "$(ecosystem_commands citation typst quarto-extension)" "no commands"
assert_eq 'cargo update --workspace --offline || cargo update --workspace' "$(ecosystem_commands cargo)" "cargo command"

# Targets.
cd "${SCRATCH}"
mkdir -p repo
cd repo

assert_eq $'- file: \'package.json\'\n  pattern: \'^  "version": "{version}",$\'' \
  "$(ecosystem_targets npm)" "npm target"
assert_eq $'- file: \'Cargo.toml\'\n  pattern: \'^version = "{version}"$\'\n  section: \'[package]\'' \
  "$(ecosystem_targets cargo)" "cargo target"
assert_eq "" "$(ecosystem_commands npm)" "npm without a lock file"
printf '{}\n' >package-lock.json
assert_eq 'npm install --package-lock-only --ignore-scripts --offline || npm install --package-lock-only --ignore-scripts' "$(ecosystem_commands npm)" "npm with a lock file"
rm package-lock.json
assert_eq $'- file: \'DESCRIPTION\'\n  pattern: \'^Version: {version}$\'' \
  "$(ecosystem_targets r)" "r target"
assert_eq "" "$(ecosystem_commands r)" "r has no command"

assert_eq $'- file: \'typst.toml\'\n  pattern: \'^version = "{version}"$\'' \
  "$(ecosystem_targets typst)" "typst target"

printf 'version: "1.4.2"\ndate-released: "2026-01-02"\n' >CITATION.cff
assert_eq $'- file: \'CITATION.cff\'\n  pattern: \'^version: "{version}"$\'\n- file: \'CITATION.cff\'\n  pattern: \'^date-released: "{date}"$\'' \
  "$(ecosystem_targets citation)" "quoted citation"
printf 'version: 1.4.2\ndate-released: 2026-01-02\n' >CITATION.cff
assert_eq $'- file: \'CITATION.cff\'\n  pattern: \'^version: {version}$\'\n- file: \'CITATION.cff\'\n  pattern: \'^date-released: {date}$\'' \
  "$(ecosystem_targets citation)" "unquoted citation"
printf "version: '1.4.2'\r\ndate-released: \"2026-01-02\"\r\n" >CITATION.cff
assert_eq $'- file: \'CITATION.cff\'\n  pattern: \'^version: \'\'{version}\'\'$\'\n- file: \'CITATION.cff\'\n  pattern: \'^date-released: "{date}"$\'' \
  "$(ecosystem_targets citation)" "single quotes, CRLF and mixed forms"
assert_eq "^version: '{version}'$" "$(ecosystem_targets citation | yq -r '.[0].pattern')" "single quotes survive YAML"
rm CITATION.cff
assert_eq $'- file: \'CITATION.cff\'\n  pattern: \'^version: {version}$\'\n- file: \'CITATION.cff\'\n  pattern: \'^date-released: {date}$\'' \
  "$(ecosystem_targets citation)" "missing CITATION.cff left to the target checks"

run ecosystem_targets quarto-extension
refuses "no file matches '_extensions/*/_extension.yml'" "no extension manifest"
mkdir -p _extensions/demo _extensions/acme/dep
printf 'version: 1.4.2\n' >_extensions/demo/_extension.yml
printf 'version: 9.9.9\n' >_extensions/acme/dep/_extension.yml
assert_eq $'- file: \'_extensions/*/_extension.yml\'\n  pattern: \'^version: {version}$\'' \
  "$(ecosystem_targets quarto-extension)" "vendored manifest ignored"
mkdir -p _extensions/other
printf 'version: 1.0.0\n' >_extensions/other/_extension.yml
run ecosystem_targets quarto-extension
refuses "_extensions/demo/_extension.yml and _extensions/other/_extension.yml" "two extension manifests"
assert_contains "${ERR}" "exactly one" "two extension manifests message"

printf '{\n\t"version": "1.0.0",\n\t"x": {\n\t\t"version": "2.0.0",\n\t}\n}\n' >package.json
assert_eq $'- file: \'package.json\'\n  pattern: \'^\t"version": "{version}",$\'' "$(ecosystem_targets npm)" "tab-indented npm target"
printf '{\n    "x": {\n        "version": "2.0.0",\n    },\n    "version": "1.0.0",\n}\n' >package.json
assert_eq $'- file: \'package.json\'\n  pattern: \'^    "version": "{version}",$\'' "$(ecosystem_targets npm)" "shallowest version line wins"
rm package.json

printf '{\n  "name": "demo",\n  "version": "1.0.0"\n}\n' >package.json
assert_eq $'- file: \'package.json\'\n  pattern: \'^  "version": "{version}"$\'' "$(ecosystem_targets npm)" "npm target with the version as the last key"
printf '{\n  "dependencies": {\n    "x": {\n      "version": "2.0.0"\n    }\n  }\n}\n' >package.json
run ecosystem_targets npm
refuses 'the npm preset' "npm without a top-level version"
assert_contains "${ERR}" "no top-level" "npm without a top-level version message"
rm package.json
