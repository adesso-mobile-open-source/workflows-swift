# shared-pipelines

The Repository for Shared Pipelines used for the adesso mobile open source projects.

Reusable GitHub Actions workflows and composite actions for Swift package repositories, designed to keep
integration into individual packages minimal while covering build, test, lint, formatting, dependency
auditing, semver-label enforcement, and automatic tagging on merge.

## What's provided

Each concern is a small, independently maintainable, isolated reusable workflow (`.github/workflows/*.yml`,
invoked via `workflow_call`). Shared logic that isn't pure YAML lives in composite actions under `actions/*`.

| Workflow | Responsibility | Runner(s) |
|---|---|---|
| `detect-platforms.yml` | Reads `Package.swift` and produces a build matrix. Falls back to Linux-only when no platforms are declared. | `ubuntu-latest` |
| `build-test.yml` | Builds and tests each matrix entry: `swift build && swift test` for `linux`/`macos`, `xcodebuild build test` against a simulator for `ios`/`watchos`/`tvos`/`visionos`. | `ubuntu-latest` / `macos-latest` |
| `lint.yml` | Runs SwiftLint via [`cirruslabs/swiftlint-action`](https://github.com/cirruslabs/swiftlint-action), which downloads a self-contained `swiftlint` binary directly (no Docker/Swift toolchain needed). | `ubuntu-latest` |
| `format-check.yml` | Runs [SwiftFormat](https://github.com/nicklockwood/SwiftFormat) in `--lint` mode. Preinstalled on macOS GitHub-hosted runners, so no install/version pinning is needed. | `macos-latest` |
| `audit.yml` | Resolves dependencies, prints the dependency graph, and runs GitHub's dependency review action on PRs. | `ubuntu-latest` |
| `pr-label-check.yml` | Fails unless the pull request has **exactly one** of the labels `major`, `minor`, `patch`. | `ubuntu-latest` |
| `auto-tag.yml` | On merge of a labeled PR into `main`, computes and pushes the next semver tag based on the label. Tag only — no GitHub Release. | `ubuntu-latest` |
| `pr-checks.yml` | Aggregator that chains `detect-platforms` → `build-test` + `lint` + `format-check` + `audit` for single-line integration. | mixed |

Composite actions (`actions/*`) hold the actual scripts and are consumed by the reusable workflows above; you
generally won't reference them directly unless building a custom workflow.

## Integrating a package (minimal footprint)

Copy the templates from [`examples/caller-workflows/`](examples/caller-workflows) into the consuming
repository's `.github/workflows/`. Three caller files are needed because they respond to three different
GitHub events (PR checks, label validation, post-merge tagging).

### 1. PR checks — pick one

**Easiest (recommended):** single aggregated job.

```yaml
# .github/workflows/pr-checks.yml
name: PR Checks
on:
  push: { branches: [main] }
  pull_request: {}
jobs:
  checks:
    uses: adesso-mobile-open-source/shared-pipelines/.github/workflows/pr-checks.yml@v1
    secrets: inherit
```

**À la carte:** wire only the checks you need — see
[`examples/caller-workflows/pr-checks-granular.yml`](examples/caller-workflows/pr-checks-granular.yml).

### 2. Semver label validation (required for merge)

```yaml
# .github/workflows/pr-label-check.yml
name: PR Label
on:
  pull_request:
    types: [opened, synchronize, reopened, labeled, unlabeled]
jobs:
  label:
    uses: adesso-mobile-open-source/shared-pipelines/.github/workflows/pr-label-check.yml@v1
```

### 3. Auto-tag on merge to main

```yaml
# .github/workflows/auto-tag.yml
name: Auto Tag
on:
  pull_request:
    types: [closed]
    branches: [main]
jobs:
  tag:
    permissions: { contents: write }
    uses: adesso-mobile-open-source/shared-pipelines/.github/workflows/auto-tag.yml@v1
    secrets: inherit
```

## One-time setup per package repository

1. **Create three labels**: `major`, `minor`, `patch`.
2. **Branch protection on `main`:**
   - Require the `PR Label` check (and the `PR Checks` check) to pass before merging.
   - Disallow direct pushes to `main` (all changes must go through a labeled PR) — this is what makes
     auto-tagging reliable, since it relies on the merged PR's label.
3. Every PR must carry exactly one of `major`/`minor`/`patch` before it can merge. On merge, the tag is bumped
   and pushed automatically.

## Configuration overrides

- **SwiftLint:** commit a `.swiftlint.yml` at your package root to override the
  [shared default](configs/.swiftlint.yml).
- **SwiftFormat:** commit a `.swiftformat` at your package root to override the
  [shared default](configs/.swiftformat). Note this is a plain-text, one-option-per-line file (SwiftFormat's
  own format, not JSON) — see the [SwiftFormat config docs](https://github.com/nicklockwood/SwiftFormat#config-file).
- If no override is present, the shared default is used automatically — no action needed.

## Platform detection behavior

`detect-platforms.yml` parses `Package.swift` directly (no Swift toolchain install required) and inspects the
declared `platforms` array:

- **No `platforms:` declared, or declared as an empty array (`platforms: []`)** → treated as cross-platform,
  a single Linux job runs.
- **Platforms declared** → only those exact platforms run (no implicit Linux job is added). Apple platforms
  (`ios`, `watchos`, `tvos`, `visionos`) run on `macos-latest` via `xcodebuild` against a simulator
  destination; `macos` runs `swift build && swift test` on `macos-latest`; `linux` runs on `ubuntu-latest`.
- **Caveat:** the `platforms:` array must be a static literal (e.g. `platforms: [.iOS(.v16), .macOS(.v13)]`),
  since it's parsed as text rather than evaluated by the Swift compiler. A computed/dynamic platforms list
  (e.g. `platforms: someFunction()`) will cause the detect job to fail loudly rather than silently produce an
  incorrect matrix.

## Swift version

`build-test.yml`, `audit.yml`, and `pr-checks.yml` expose a `swift-version` input that defaults to
**`"6.2"`** — the minimum version required by this repository's tooling. This default is only applied to
`spm`-kind jobs (`linux`/`macos`) and `audit.yml`; `xcodebuild`-kind jobs (`ios`/`watchos`/`tvos`/`visionos`)
always use the Xcode-bundled toolchain preinstalled on the `macos-latest` runner, which is not currently
pinned by this repository.

Override `swift-version` to pin a newer version if your package requires one. Note that
[`swift-actions/setup-swift`](https://github.com/swift-actions/setup-swift) resolves versions using strict
semver matching (e.g. `"6.2"` resolves to the latest `6.2.x` patch, not "6.2 or later"), so the default does
not automatically track newer Swift releases — bump it explicitly here (or via override) when needed.

## Runners

Workflows default to the lowest-cost GitHub-hosted runners where possible (`ubuntu-latest`), reserving
`macos-latest` only for jobs that require an Apple SDK/toolchain or a preinstalled macOS-only tool
(Apple-platform builds, SwiftFormat).
Runner selection is centralized in `detect-platforms.yml`'s matrix output and each workflow's `runs-on`, so
migrating to custom/self-hosted runners later only requires changing those values in one place.

## Important caveats

- **Tag-only releases:** `auto-tag.yml` pushes a tag but does not create a GitHub Release. This can be added
  later.
- **GITHUB_TOKEN-pushed tags do not trigger further workflows.** This is a GitHub recursion-prevention rule.
  If a future release workflow needs to fire when `auto-tag.yml` pushes a new tag, that will require a
  Personal Access Token or GitHub App installation token instead of the default `GITHUB_TOKEN`.
- **`uses:` cannot contain expressions.** Composite action references inside the reusable workflows (e.g.
  `adesso-mobile-open-source/shared-pipelines/actions/detect-platforms@v1`) are pinned to a static ref by necessity — this
  is a hard GitHub Actions restriction, not an oversight. Bump these refs in lockstep with this repository's
  version tags.

## Versioning of this repository

This repository is tagged with semver tags (`v1.2.3`) and a moving major tag (`v1`) that consuming packages
pin against in their `uses:` references, e.g. `...@v1`. Update the moving major tag when publishing
backwards-compatible releases.
