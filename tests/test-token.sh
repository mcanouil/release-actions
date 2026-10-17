#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091 # tests/lib.sh is linted as a file of its own.
source "${ROOT}/tests/lib.sh"

resolve="${ROOT}/token/resolve.sh"
identity="${ROOT}/token/identity.sh"
export GIT_CONFIG_GLOBAL="${SCRATCH}/gitconfig" GH_LOG="${SCRATCH}/gh.log"
install_fake_gh

# Runs SCRIPT with the VAR=value arguments. Sets STATUS, ERR and OUT.
run_script() {
  local script="$1"
  shift
  OUT="${SCRATCH}/out"
  : >"${OUT}"
  : >"${GH_LOG}"
  : >"${GIT_CONFIG_GLOBAL}"
  STATUS=0
  ERR="$(env GITHUB_OUTPUT="${OUT}" "$@" "${script}" 2>&1 >/dev/null)" || STATUS=$?
}

assert_identity() {
  assert_eq "$1" "$(git config --global user.name)" "$3 name"
  assert_eq "$2" "$(git config --global user.email)" "$3 email"
}

bot_name='github-actions[bot]'
bot_email='41898282+github-actions[bot]@users.noreply.github.com'

run_script "${resolve}" APP_ID=1 APP_KEY=key PROVIDED_TOKEN=pat
assert_status 0 "${STATUS}" "app: ${ERR}"
assert_eq app "$(output_value source "${OUT}")" "app source"

run_script "${resolve}" APP_ID=1 PROVIDED_TOKEN=pat
assert_status 0 "${STATUS}" "id without key, token: ${ERR}"
assert_eq token "$(output_value source "${OUT}")" "id without key, token source"
assert_contains "${ERR}" "app-key" "id without key warning"

run_script "${resolve}" APP_ID=1
assert_status 0 "${STATUS}" "id without key: ${ERR}"
assert_eq default "$(output_value source "${OUT}")" "id without key source"
assert_contains "${ERR}" "app-key" "id without key, no token warning"

run_script "${resolve}" APP_KEY=key PROVIDED_TOKEN=pat
assert_eq token "$(output_value source "${OUT}")" "key without id source"
assert_contains "${ERR}" "app-id" "key without id warning"

run_script "${resolve}" PROVIDED_TOKEN=pat
assert_eq token "$(output_value source "${OUT}")" "token source"

run_script "${resolve}"
assert_status 0 "${STATUS}" "default: ${ERR}"
assert_eq default "$(output_value source "${OUT}")" "default source"
assert_eq "" "${ERR}" "default is silent"

run_script "${identity}" SOURCE=app APP_SLUG=demo-app GH_TOKEN=t
assert_status 0 "${STATUS}" "app identity: ${ERR}"
assert_identity 'demo-app[bot]' '123+demo-app[bot]@users.noreply.github.com' "app identity"
assert_contains "$(cat "${GH_LOG}")" "api /users/demo-app%5Bbot%5D" "app lookup"
assert_eq "" "$(cat "${OUT}")" "identity writes no output"

run_script "${identity}" SOURCE=token GH_TOKEN=t
assert_status 0 "${STATUS}" "token identity: ${ERR}"
assert_identity octo '456+octo@users.noreply.github.com' "token identity"

run_script "${identity}" SOURCE=default GH_TOKEN=t
assert_status 0 "${STATUS}" "default identity: ${ERR}"
assert_identity "${bot_name}" "${bot_email}" "default identity"
assert_eq "" "$(cat "${GH_LOG}")" "default makes no gh call"

run_script "${identity}" SOURCE=app APP_SLUG=demo-app GH_TOKEN=t GH_DOWN=1
assert_status 0 "${STATUS}" "app lookup down: ${ERR}"
assert_identity "${bot_name}" "${bot_email}" "app lookup down"
assert_contains "${ERR}" "demo-app[bot]" "app lookup down warning"

run_script "${identity}" SOURCE=token GH_TOKEN=t GH_DOWN=1
assert_status 0 "${STATUS}" "token lookup down: ${ERR}"
assert_identity "${bot_name}" "${bot_email}" "token lookup down"
assert_contains "${ERR}" "owner of the token" "token lookup down warning"

run_script "${identity}" SOURCE=other GH_TOKEN=t
refuses "source" "unknown source"

# require-app.
run_script "${resolve}" REQUIRE_APP=true
refuses "require-app is true, but no App is set" "require-app with no App"
run_script "${resolve}" REQUIRE_APP=true APP_ID=1 PROVIDED_TOKEN=pat
refuses "require-app is true, but no App is set" "require-app with an id and no key"
run_script "${resolve}" REQUIRE_APP=true APP_ID=1 APP_KEY=key
assert_status 0 "${STATUS}" "require-app with an App: ${ERR}"
assert_eq app "$(output_value source "${OUT}")" "require-app source"
run_script "${resolve}" REQUIRE_APP=maybe APP_ID=1 APP_KEY=key
refuses "require-app is 'maybe'" "require-app not a boolean"
