#!/usr/bin/env bash
# Sets the global git identity that matches the source of the token: the App
# bot, the owner of a provided token, or github-actions[bot]. A failed lookup
# falls back to github-actions[bot] with a warning.
set -euo pipefail

# shellcheck disable=SC2034 # Read by die in lib/common.sh.
SCRIPT_NAME=token
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
# shellcheck disable=SC1091 # lib/common.sh is linted as a file of its own.
source "${LIB}/common.sh"

SOURCE="${SOURCE:-}"
APP_SLUG="${APP_SLUG:-}"

name='github-actions[bot]'
email='41898282+github-actions[bot]@users.noreply.github.com'

case "${SOURCE}" in
app)
  require_tools gh
  if id="$(gh api "/users/${APP_SLUG}%5Bbot%5D" --jq .id)" && [[ -n "${id}" ]]; then
    name="${APP_SLUG}[bot]"
    email="${id}+${APP_SLUG}[bot]@users.noreply.github.com"
  else
    warn "could not look up the user id of ${APP_SLUG}[bot], so commits use ${name}."
  fi
  ;;
token)
  require_tools gh
  if owner="$(gh api /user --jq '"\(.login) \(.id)"')" && [[ "${owner}" == *" "* ]]; then
    name="${owner% *}"
    email="${owner##* }+${name}@users.noreply.github.com"
  else
    warn "could not look up the owner of the token, so commits use ${name}."
  fi
  ;;
default) ;;
*) die "source is '${SOURCE}'. Use app, token or default." ;;
esac

git config --global user.name "${name}"
git config --global user.email "${email}"
printf 'Git identity: %s <%s>\n' "${name}" "${email}"
