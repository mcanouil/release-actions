# Changelog

All notable changes to this project will be documented in this file.

## Unreleased

- feat: `bump` stops when the files hold a version that a failed run bumped but did not release, so a second run does not skip that version. (#7)
- feat: `bump` stops when `date` is not a real day, such as `2026-02-30`. (#7)
- feat: Add the `after-bump` input to `bump`. It runs a command after the version is written, and the files that the command changes go into the `files` output. (#7)
- feat: `land` stops a release that runs on a branch other than the default branch. Other changes still land on any branch. (#7)
- feat: Add the `require-app` input to `token`. With `true`, the step stops when no GitHub App is set. (#7)
- feat: Add the `footer` input to `notes`, a template at the end of the release body. (#7)

## 1.2.0 (2026-10-17)

- feat: Add the `land` action. It commits a bump or any other change and lands it on the branch, with a push or with a pull request that it can merge.
- feat: Add the `{count}` placeholder to the release title. It adds `(2)` after a space for a second CalVer release on the same day, and nothing for the first.
- feat: `bump` names the line to add when a target matches nothing.
- feat: Add the `token` action. It picks a GitHub App token, a token that you give, or the default token, and sets the matching git identity.

## 1.1.0 (2026-10-16)

- fix: `bump` now stops when the tag or the release of the new version already exists, before it writes a file. Give it the same `tag-prefix` as `release`, which allows only letters, digits, dots, hyphens and underscores. (#4)
- feat: Add the `token` input to `bump`. The token needs `contents: read`, and `contents: write` to see draft releases. (#4)

## 1.0.0 (2026-10-15)

- feat: Initial release.
