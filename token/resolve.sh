#!/usr/bin/env bash
# Picks the credentials of the token action: a GitHub App when both its id and
# key are set, then a token that the caller provides, then the default token.
# The inputs of token/action.yml arrive as environment variables.
set -euo pipefail

# shellcheck disable=SC2034 # Read by die in lib/common.sh.
SCRIPT_NAME=token
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
# shellcheck disable=SC1091 # lib/common.sh is linted as a file of its own.
source "${LIB}/common.sh"

APP_ID="${APP_ID:-}"
APP_KEY="${APP_KEY:-}"
PROVIDED_TOKEN="${PROVIDED_TOKEN:-}"
REQUIRE_APP="${REQUIRE_APP:-false}"
require_bool require-app "${REQUIRE_APP}"

if [[ -n "${APP_ID}" && -n "${APP_KEY}" ]]; then
  source=app
else
  if [[ -n "${APP_ID}" ]]; then
    warn "app-id is set but app-key is empty, so the App is not used. Pass app-key to commit as the App."
  fi
  if [[ -n "${APP_KEY}" ]]; then
    warn "app-key is set but app-id is empty, so the App is not used. Pass app-id to commit as the App."
  fi
  if [[ -n "${PROVIDED_TOKEN}" ]]; then
    source=token
  else
    source=default
  fi
fi

if [[ "${REQUIRE_APP}" == "true" && "${source}" != "app" ]]; then
  die "require-app is true, but no App is set. Set the APP_ID variable and the APP_KEY secret, then dispatch again."
fi
set_output source "${source}"
