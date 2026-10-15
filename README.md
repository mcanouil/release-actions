# release-actions

Three composite GitHub Actions that release a repository from its changelog.

- `bump` writes the next version to your files and turns the `## Unreleased` section of `CHANGELOG.md` into the section of the new version.
- `notes` makes the release body from a header template, that changelog section, and the notes that GitHub generates.
- `release` creates the GitHub release and, on request, moves the rolling `vX` and `vX.Y` tags.

The actions do not commit or push.
Your workflow lands the commit between `bump` and `release`, with a push or with a pull request.

## Requirements

The actions run on the GitHub-hosted Ubuntu and macOS runners.
These runners have bash, perl, `yq` v4 and `gh`.
On other runners, install `yq` v4 and `gh` before the first step.

## Example

```yaml
- name: Bump the version
  id: bump
  uses: mcanouil/release-actions/bump@v1
  with:
    bump: minor
    targets: |
      - file: CITATION.cff
        pattern: '^version: {version}$'
      - file: CITATION.cff
        pattern: '^date-released: "{date}"$'
      - file: package.json
        pattern: '^  "version": "{version}",$'

- name: Commit and push
  id: push
  shell: bash
  env:
    VERSION: ${{ steps.bump.outputs.version }}
    FILES: ${{ steps.bump.outputs.files }}
  run: |
    set -euo pipefail
    printf '%s\n' "${FILES}" | git add --pathspec-from-file=-
    git commit -m "ci: release ${VERSION} [skip ci]"
    git push origin "HEAD:${GITHUB_REF_NAME}"
    echo "sha=$(git rev-parse HEAD)" >>"${GITHUB_OUTPUT}"

- name: Make the release body
  id: notes
  uses: mcanouil/release-actions/notes@v1
  with:
    notes-file: ${{ steps.bump.outputs.notes-file }}
    version: ${{ steps.bump.outputs.version }}
    tag: ${{ steps.bump.outputs.version }}
    target: ${{ steps.push.outputs.sha }}
    generate-notes: true

- name: Create the release
  uses: mcanouil/release-actions/release@v1
  with:
    version: ${{ steps.bump.outputs.version }}
    body-file: ${{ steps.notes.outputs.body-file }}
    target: ${{ steps.push.outputs.sha }}
```

## bump

`bump` reads the current version, calculates the next version, and writes it to the target files.
It also rolls the changelog.
It does all of its checks before it writes a file, so a failed step does not change the working tree.

| Input | Default | Description |
| --- | --- | --- |
| `bump` | (required) | `patch`, `minor`, `major`, `calver`, or an explicit version such as `1.2.3`. |
| `targets` | `''` | YAML list of targets. Each target has `file`, `pattern`, and optionally `source` and `required`. |
| `version-source` | `target` | Where the current version comes from: `target` or `tag`. |
| `tag-prefix` | `''` | Prefix of the version tags, such as `v`, for `version-source: tag`. |
| `changelog` | `CHANGELOG.md` | Path of the changelog. An empty string turns off the changelog roll. |
| `changelog-heading` | `## {version} ({date})` | Heading that the Unreleased section becomes. |
| `allow-empty` | `false` | Release when the Unreleased section is empty. |
| `date` | today in UTC | Release date, `YYYY-MM-DD`. |

| Output | Description |
| --- | --- |
| `version` | The new version, without a tag prefix. |
| `previous` | The version before the bump. |
| `major` | The major part of the new version. |
| `minor` | The major and minor parts of the new version, such as `1.5`. |
| `date` | The release date. |
| `notes-file` | Path of a file that contains the changelog section of the release. |
| `files` | The changed files, one per line. |

### Targets

Each target tells `bump` where a version or a date is in a file.

- `file` is a glob, such as `_extensions/*/_extension.yml`.
- `pattern` is literal text with placeholders.
  `{version}` matches a version such as `1.2.3`, `2026.10.15` or `2026.10.15-2`.
  `{date}` matches a date such as `2026-10-15`.
  `{major}` matches the major number, for pins such as `@v{major}`.
- A `^` at the start of the pattern anchors it to the start of a line.
  A `$` at the end anchors it to the end of a line.
- `source: true` marks the target that gives the current version.
  Only one target can set it.
- `required: false` lets a target match no file, or a file with no match.
  By default, both cases stop the step with an error.

`bump` replaces every match in a file.
All other characters in a pattern match literally, so quotes, dots and `=` need no escape.

Anchors prevent false matches.
For example, `version: {version}` also matches the line `cff-version: 1.2.0` in `CITATION.cff`.
Write `^version: {version}$` for this file.

These targets are ready to use:

```yaml
- file: CITATION.cff
  pattern: '^version: {version}$'
- file: CITATION.cff
  pattern: '^date-released: "{date}"$'
- file: typst.toml
  pattern: '^version = "{version}"$'
- file: package.json
  pattern: '^  "version": "{version}",$'
- file: Cargo.toml
  pattern: '^version = "{version}"$'
- file: _extensions/*/_extension.yml
  pattern: '^version: {version}$'
- file: README.md
  pattern: 'owner/repository@{version}'
```

A pattern cannot update a lock file.
To update `package-lock.json` or `Cargo.lock`, add a step after `bump` that runs `npm install --package-lock-only` or `cargo update --workspace --offline`.

### Current version and next version

With `version-source: target`, the current version comes from one target.
This is the target with `source: true`.
If no target sets `source`, it is the first target whose pattern contains `{version}`.
The pattern of this target must match exactly one version in exactly one file.

With `version-source: tag`, the current version comes from the highest tag that is `<tag-prefix>X.Y.Z`.
If the repository has no such tag, the current version is `0.0.0`.
The workflow must fetch the tags, for example with `fetch-depth: 0` on `actions/checkout`.

The `bump` input sets the next version:

- `patch`, `minor` and `major` increase that part and set the lower parts to zero.
- `calver` gives the date as `YYYY.MM.DD`.
  If the current version already has this date, `bump` adds `-2`, or increases the number after the dash.
- An explicit version, such as `2.0.0`, becomes the next version.
  It must be different from the current version.

### Changelog

`bump` finds the `## Unreleased` or `## [Unreleased]` heading in the changelog.
It replaces this heading with `changelog-heading`, and adds a new empty Unreleased heading above it, in the same form.
The text under the old heading becomes the `notes-file` output.

If the Unreleased section is empty, the step stops with an error.
Set `allow-empty: true` to release with an empty section.
Set `changelog: ''` if the repository has no changelog.

## notes

`notes` makes the release body in a file.
It does not change the repository.

| Input | Default | Description |
| --- | --- | --- |
| `notes-file` | `''` | File that contains the changelog section, usually the `notes-file` output of `bump`. |
| `version` | `''` | Value of `{version}` in the header. Without `notes-file`, also the version whose section `notes` reads from the changelog. |
| `changelog` | `CHANGELOG.md` | Path of the changelog. `notes` reads it only without `notes-file`. |
| `changelog-heading` | `## {version} ({date})` | Form of the version headings. `notes` reads it only without `notes-file`. |
| `header` | `''` | Template file at the start of the body. |
| `section-heading` | `## Changelog` | Heading above the changelog section. An empty string removes it. |
| `date` | today in UTC | Value of `{date}` in the header, `YYYY-MM-DD`. |
| `generate-notes` | `false` | Add the notes that GitHub generates at the end of the body. |
| `tag` | `''` | Value of `{tag}` in the header, and the tag for the generated notes. |
| `target` | `github.sha` | Commit for the generated notes. |
| `previous-tag` | latest release | Start of the range for the generated notes. |
| `token` | `github.token` | Token for the GitHub API. |

| Output | Description |
| --- | --- |
| `body-file` | Path of the release body. |

The body has three parts, in this order: the header, the section heading with the changelog section, and the generated notes.
A blank line separates the parts.
`notes` removes empty parts.
If the changelog section is empty, `notes` also removes the section heading.

The header can contain the placeholders `{version}`, `{tag}`, `{date}` and `{repository}`.
A placeholder is a lower-case name in braces.
A name in braces after a `$`, such as `${VERSION}`, is shell text, and `notes` keeps it.
If the header contains an unknown placeholder, or a placeholder without a value, the step stops with an error.

The body must be 125,000 characters or less, which is the GitHub limit.

## release

`release` creates the GitHub release of a version.
GitHub creates the tag as a lightweight tag on `target`.

| Input | Default | Description |
| --- | --- | --- |
| `version` | (required) | The version to release, usually the `version` output of `bump`. |
| `tag-prefix` | `''` | The tag is `<tag-prefix><version>`. |
| `body-file` | (required) | The release body, usually the `body-file` output of `notes`. |
| `title` | `{tag}` | Title of the release. Placeholders: `{tag}`, `{version}`, `{date}`. |
| `date` | today in UTC | Value of `{date}` in the title, `YYYY-MM-DD`. |
| `target` | `github.sha` | Commit to tag. |
| `assets` | `''` | Globs of the files to attach, one per line. Add `#label` to a line to give a label. |
| `draft` | `false` | Create a draft release. |
| `prerelease` | `false` | Mark the release as a prerelease. |
| `latest` | `auto` | Mark the release as the latest: `auto`, `true` or `false`. |
| `rolling` | `false` | Move `<tag-prefix>X` and `<tag-prefix>X.Y` to `target`. |
| `token` | `github.token` | Token with `contents: write`. |

| Output | Description |
| --- | --- |
| `tag` | Tag of the release. |
| `url` | URL of the release. |
| `release-id` | Numeric identifier of the release. |

If the tag or the release already exists, the step stops before it creates anything.
Each asset glob must match at least one file.

With `rolling: true`, `target` must be a full commit SHA.
A draft release has no tag, so `rolling` and `draft` cannot both be `true`.
`rolling` and `prerelease` cannot both be `true`, because callers that pin the rolling tags would then get the prerelease.
`tag-prefix` can contain only letters, digits, dots, hyphens and underscores.
A rolling tag does not move back: if a higher release already exists under `vX` or `vX.Y`, that tag stays, and the step writes a warning.

If a ruleset protects the tags or the default branch, use a GitHub App token that the ruleset exempts.

## Recipes

### Push to the default branch

The example above pushes the bump commit to the default branch.
The default branch usually requires a pull request.
In this case, give the push a GitHub App token, and add the App to the bypass list of the ruleset.
Use `[skip ci]` in the commit message so that the checks do not run again on the same tree.

### Pull request with automerge

1. Run `bump`.
2. Commit the changes on a new branch, and open a pull request.
3. Turn on automerge for the pull request, and wait until it merges.
4. Run `notes` and `release` with `target` set to the merge commit.

### Draft release

1. Run `bump`, commit and push.
2. Run `notes`.
3. Run `release` with `draft: true`, and keep `rolling` at `false`.
4. Publish the draft in a later workflow, for example after an external registry accepts the package.
