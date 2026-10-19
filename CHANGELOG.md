# Changelog

All notable changes to this project will be documented in this file.

## Unreleased

- fix: Stop `bump` when `ecosystems` names a preset twice, and name the preset when its lock file command fails. (#10)
- fix: Read the `citation` quote style from the value only, accept a comment after a `[package]` header, and keep the spaces or tabs after `Version:` with the `r` preset. (#10)
- fix: Stop the `npm` preset with a clear message on a one-line `package.json`. (#10)
- fix: Keep trailing spaces, which can be hard breaks, in the `NEWS.md` section of the `r` preset. (#10)
- fix: Check the `labels` of `land` before the push, and pass the default label once when `labels` repeats it. (#10)
- fix: Say what to do in the `notes` errors of the `r` preset, and leave no temporary file behind in `release`. (#10)

## 1.5.0 (2026-10-19)

- feat: Add the `ecosystems` input to `bump`. It adds the targets and the lock file commands of the `citation`, `npm`, `cargo`, `typst` and `quarto-extension` presets. (#9)
- feat: Add the `r` preset, with the `dev` bump type, R package versions and `NEWS.md`. `notes` also reads its section from `NEWS.md`. (#9)
- feat: Add the `labels` and `assignees` inputs to `land`, for the pull request. (#9)
- feat: Add the `existing` input to `release`. With `keep`, a repeated run succeeds when the release exists on the target commit. (#9)
- fix: End land cleanly when files is empty and allow-unchanged is true. (#9)

## 1.4.0 (2026-10-17)

- feat: Add the `base` input to `land`. It sets the branch to land on, for a workflow that runs on a tag, such as on a `release` event.

## 1.3.0 (2026-10-17)

- feat: `bump` stops when the files hold a version that a failed run bumped but did not release, so a second run does not skip that version. (#7)
- feat: `bump` stops when `date` is not a real day, such as `2026-02-30`. (#7)
- feat: Add the `after-bump` input to `bump`. It runs a command after the version is written, and the files that the command changes go into the `files` output. (#7)
- feat: `land` stops a release that runs on a branch other than the default branch. Other changes still land on any branch. (#7)
- feat: Add the `require-app` input to `token`. With `true`, the step stops when no GitHub App is set. (#7)
- feat: Add the `footer` input to `notes`, a template at the end of the release body. (#7)
- fix: `release` reads every page of tags before it moves a rolling tag, so a repository with more than 30 tags under `vX` no longer moves it back. (#7)

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
