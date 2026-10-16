# Changelog

All notable changes to this project will be documented in this file.

## Unreleased

- fix: `bump` now stops when the tag or the release of the new version already exists, before it writes a file. Give it the same `tag-prefix` as `release`, which allows only letters, digits, dots, hyphens and underscores. (#4)
- feat: Add the `token` input to `bump`. The token needs `contents: read`, and `contents: write` to see draft releases. (#4)

## 1.0.0 (2026-10-15)

- feat: Initial release.
