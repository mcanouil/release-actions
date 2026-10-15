#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091 # tests/lib.sh is linted as a file of its own.
source "${ROOT}/tests/lib.sh"

script="${ROOT}/lib/section.pl"
changelog="${SCRATCH}/CHANGELOG.md"

cat >"${changelog}" <<'EOF'
# Changelog

## Unreleased

### Features

- feat: Next. (#3)

```bash
## not a heading inside a fence
```

## 1.4.2 (2026-01-02)

- fix: Old.

## [1.0.0] - 2025-12-01

- feat: Initial release.
EOF

expected=$'### Features\n\n- feat: Next. (#3)\n\n```bash\n## not a heading inside a fence\n```'
assert_eq "${expected}" "$(perl "${script}" unreleased "${changelog}")" "unreleased with a fence"
assert_eq "- fix: Old." "$(perl "${script}" version "${changelog}" '## {version} ({date})' 1.4.2)" "version section"
assert_eq "- feat: Initial release." "$(perl "${script}" version "${changelog}" '## [{version}] - {date}' 1.0.0)" "bracket heading"

status=0
perl "${script}" version "${changelog}" '## {version} ({date})' 9.9.9 >/dev/null || status=$?
assert_status 2 "${status}" "missing version"

status=0
perl "${script}" version "${changelog}" '## {version} ({date})' 1x4x2 >/dev/null || status=$?
assert_status 2 "${status}" "dots in the version are literal"

printf '# Changelog\n\n## [Unreleased]\n\n- fix: Bracket form.\n' >"${changelog}"
assert_eq "- fix: Bracket form." "$(perl "${script}" unreleased "${changelog}")" "bracket Unreleased"

printf '## Unreleased  \r\n\r\n- feat: X.\r\n\r\n## 1.0.0 (2026-01-01)\r\n' >"${changelog}"
assert_eq "- feat: X." "$(perl "${script}" unreleased "${changelog}")" "CRLF and trailing spaces"

printf '## Unreleased\n\n## 1.0.0 (2026-01-01)\n\n- feat: Old.\n' >"${changelog}"
assert_eq "" "$(perl "${script}" unreleased "${changelog}")" "empty section"

printf '# Changelog\n\n## 1.0.0 (2026-01-01)\n' >"${changelog}"
status=0
perl "${script}" unreleased "${changelog}" >/dev/null || status=$?
assert_status 2 "${status}" "no Unreleased heading"

printf '## Unreleased\n\n- a\n\n## [Unreleased]\n\n- b\n' >"${changelog}"
status=0
perl "${script}" unreleased "${changelog}" >/dev/null || status=$?
assert_status 3 "${status}" "two Unreleased headings"

status=0
perl "${script}" unreleased "${SCRATCH}/missing.md" 2>/dev/null || status=$?
assert_status 1 "${status}" "missing file"
