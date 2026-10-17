# Changelog

All notable changes to this project will be documented in this file.

## Unreleased

- feat: Add the `land` action. It commits a bump or any other change and lands it on the branch, with a push or with a pull request that it can merge.
- feat: Add the `{count}` placeholder to the release title. It adds `(2)` after a space for a second CalVer release on the same day, and nothing for the first.
- feat: `bump` names the line to add when a target matches nothing.
- feat: Add the `token` action. It picks a GitHub App token, a token that you give, or the default token, and sets the matching git identity.

## 1.1.0 (2026-10-16)

- fix: `bump` now stops when the tag or the release of the new version already exists, before it writes a file. Give it the same `tag-prefix` as `release`, which allows only letters, digits, dots, hyphens and underscores. (#4)
- feat: Add the `token` input to `bump`. The token needs `contents: read`, and `contents: write` to see draft releases. (#4)

## 1.0.0 (2026-10-15)

- feat: Initial release.
