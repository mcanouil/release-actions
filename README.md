# Release Actions

Five composite GitHub Actions that release a repository from its changelog.

- `token` picks the token of the workflow: a GitHub App token, a token that you give, or the default token.
  It also sets the git identity that matches this token.
- `bump` writes the next version to your files and turns the `## Unreleased` section of `CHANGELOG.md` into the section of the new version.
- `notes` makes the release body from a header template, that changelog section, and the notes that GitHub generates.
- `land` commits the bump and lands it on the branch, with a push or with a pull request that it merges.
- `release` creates the GitHub release and, on request, moves the rolling `vX` and `vX.Y` tags.

## Requirements

The actions run on the GitHub-hosted Ubuntu and macOS runners.
These runners have bash, perl, `yq` v4 and `gh`.
On other runners, install `yq` v4 and `gh` before the first step.
`bump`, `release`, and `notes` with `generate-notes: true` call the GitHub API, so the job needs `contents: read` at least.

## Example

```yaml
- name: Get the token
  id: token
  uses: mcanouil/release-actions/token@v1
  with:
    app-id: ${{ vars.APP_ID }}
    app-key: ${{ secrets.APP_KEY }}

- name: Check out the repository
  uses: actions/checkout@v7
  with:
    fetch-depth: 0
    token: ${{ steps.token.outputs.token }}

- name: Bump the version
  id: bump
  uses: mcanouil/release-actions/bump@v1
  with:
    bump: minor
    token: ${{ steps.token.outputs.token }}
    targets: |
      - file: CITATION.cff
        pattern: '^version: {version}$'
      - file: CITATION.cff
        pattern: '^date-released: "{date}"$'
      - file: package.json
        pattern: '^  "version": "{version}",$'

- name: Land the bump
  id: land
  uses: mcanouil/release-actions/land@v1
  with:
    mode: push
    files: ${{ steps.bump.outputs.files }}
    version: ${{ steps.bump.outputs.version }}
    token: ${{ steps.token.outputs.token }}

- name: Make the release body
  id: notes
  uses: mcanouil/release-actions/notes@v1
  with:
    notes-file: ${{ steps.bump.outputs.notes-file }}
    version: ${{ steps.bump.outputs.version }}
    tag: ${{ steps.bump.outputs.version }}
    target: ${{ steps.land.outputs.sha }}
    generate-notes: true
    token: ${{ steps.token.outputs.token }}

- name: Create the release
  uses: mcanouil/release-actions/release@v1
  with:
    version: ${{ steps.bump.outputs.version }}
    body-file: ${{ steps.notes.outputs.body-file }}
    target: ${{ steps.land.outputs.sha }}
    token: ${{ steps.token.outputs.token }}
```

## token

`token` picks one token for all the steps of a job, in this order:

1. A GitHub App token, if you give `app-id` and `app-key`.
2. The value of `token`, for example a personal access token.
3. The default token, `github.token`.

If you give `app-id` without `app-key`, the step writes a warning and does not use the App.
The step never stops because a credential is missing, because the default token is always available.

`token` also sets the global git identity:

- For an App, the identity is the bot of the App, such as `my-app[bot]`.
- For a token that you give, the identity is the owner of the token.
- For the default token, the identity is `github-actions[bot]`.

If GitHub does not answer the lookup of the App bot or of the owner, the identity is `github-actions[bot]`, and the step writes a warning.

Give the `token` output to `actions/checkout`, because `land` pushes with the credentials that checkout keeps.

| Input | Default | Description |
| --- | --- | --- |
| `app-id` | `''` | Client id of the GitHub App. |
| `app-key` | `''` | Private key of the GitHub App. |
| `token` | `''` | Token to use when there is no App. |

| Output | Description |
| --- | --- |
| `token` | The token that the step picked. |
| `source` | Where the token comes from: `app`, `token` or `default`. |

## bump

`bump` reads the current version, calculates the next version, and writes it to the target files.
It also rolls the changelog.
It does all of its checks before it writes a file, so a failed step does not change the working tree.
One of these checks looks for the tag `<tag-prefix><version>` and for a release with this name.
If one of them exists, or if GitHub does not answer, the step stops.
`release` does the same check, but at that time the bump is already on the default branch.

| Input | Default | Description |
| --- | --- | --- |
| `bump` | (required) | `patch`, `minor`, `major`, `calver`, or an explicit version such as `1.2.3`. |
| `targets` | `''` | YAML list of targets. Each target has `file`, `pattern`, and optionally `source` and `required`. |
| `version-source` | `target` | Where the current version comes from: `target` or `tag`. |
| `tag-prefix` | `''` | Prefix of the version tags, such as `v`. Give the same value to `release`. |
| `changelog` | `CHANGELOG.md` | Path of the changelog. An empty string turns off the changelog roll. |
| `changelog-heading` | `## {version} ({date})` | Heading that the Unreleased section becomes. |
| `allow-empty` | `false` | Release when the Unreleased section is empty. |
| `date` | today in UTC | Release date, `YYYY-MM-DD`. |
| `token` | `github.token` | Token for the GitHub API. Only a token with `contents: write` sees draft releases. |

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

## land

`land` commits the files of a bump on the branch of the workflow.
The release is `<tag-prefix><version>` in the text below.
The `mode` input sets how the commit gets to the branch.

With `mode: push`, `land` commits `ci: release <tag-prefix><version> [skip ci]` and pushes it to the branch.
`[skip ci]` stops the checks from running again on the same tree.

With `mode: pull-request`, `land` does these steps:

1. It commits `ci: release <tag-prefix><version>` on the branch `release/<tag-prefix><version>`, and force-pushes this branch.
   If an earlier run left a pull request open for this branch, `land` closes it first.
2. It opens a pull request, with the label `Type: CI/CD :robot:` if the repository has this label.
3. It squash-merges the pull request and deletes the branch.
   If checks block the merge, it turns on auto-merge.
4. It waits until the pull request merges, for `merge-timeout` seconds at most.

The commit of a pull request has no `[skip ci]`, because the required checks of the pull request must run.

After `land`, the working tree is at the landed commit, with a detached `HEAD`.
The next steps, for example a build, use the released files.

| Input | Default | Description |
| --- | --- | --- |
| `mode` | (required) | `push` or `pull-request`. |
| `files` | (required) | Paths to commit, one per line, usually the `files` output of `bump`. |
| `version` | (required) | The version, usually the `version` output of `bump`. |
| `tag-prefix` | `''` | Prefix of the release name in the commit message and the branch. |
| `merge-timeout` | `600` | Seconds to wait for the pull request to merge. |
| `token` | `github.token` | Token for the GitHub API in `pull-request` mode, with `contents: write` and `pull-requests: write`. |

| Output | Description |
| --- | --- |
| `sha` | The commit on the branch that contains the bump. |

`land` pushes with the credentials that `actions/checkout` keeps, in both modes.
Thus the token of the checkout decides if the push is accepted.
Give the same token to `actions/checkout` and to `land`.

`land` commits only the paths in `files`.
If the workflow changes other files, add their paths to `files`.
If the files have no change, the step stops: the bump can already be on the branch.

### Modes and tokens

The rules of the branch decide which token can land the bump in each mode.
The token in this table is the token of `actions/checkout`.

| Mode and branch | App on the bypass list | Your token | Default token |
| --- | --- | --- | --- |
| `push`, the branch requires a pull request | lands | lands only if the owner can bypass the rule | refused |
| `push`, no rule on the branch | lands | lands | lands |
| `pull-request`, no required checks | lands | lands | lands |
| `pull-request`, required checks | lands | lands | blocked |

A push with the default token starts no workflow.
As a result, the required checks of the pull request never start, and the merge cannot occur.
`land` finds this case after 120 seconds and stops with an error.

If a workflow must work with the default token, use `mode: pull-request` on a branch with no required checks.

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
For the same reason, `rolling` needs a release version, such as `1.2.3` or `2026.10.15-2`, and refuses a version such as `1.2.3-rc.1`.
`tag-prefix` can contain only letters, digits, dots, hyphens and underscores.
A rolling tag does not move back: if a higher release already exists under `vX` or `vX.Y`, that tag stays, and the step writes a warning.

If a ruleset protects the tags or the default branch, use a GitHub App token that the ruleset exempts.

## Recipes

### Draft release

1. Run `bump`, then `land`.
2. Run `notes`.
3. Run `release` with `draft: true`, and keep `rolling` at `false`.
4. Publish the draft in a later workflow, for example after an external registry accepts the package.
