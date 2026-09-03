# workflows-swift

The Repository for Shared Pipelines used for the adesso mobile open source projects.

Reusable GitHub Actions workflows and composite actions for Swift package repositories, designed to keep
integration into individual packages minimal while covering build, test, lint, formatting, dependency
auditing, semver-label enforcement, and automatic tagging on merge.

## What's provided

Each concern is a small, independently maintainable, isolated reusable workflow (`.github/workflows/*.yml`,
invoked via `workflow_call`). Shared logic that isn't pure YAML lives in composite actions under `actions/*`.

| Workflow | Responsibility | Runner(s) |
|---|---|---|
| `detect-platforms.yml` | Reads `Package.swift` and produces a build matrix. Falls back to Linux-only when no platforms are declared; Linux inclusion is configurable via the `linux` input (`auto`/`always`/`never`). | `ubuntu-latest` |
| `build-test.yml` | Builds and tests each matrix entry: `swift build && swift test` for `linux`/`macos`, `xcodebuild build test` against a simulator for `ios`/`watchos`/`tvos`/`visionos`. | `ubuntu-latest` / `macos-latest` |
| `lint.yml` | Runs SwiftLint via [`cirruslabs/swiftlint-action`](https://github.com/cirruslabs/swiftlint-action), which downloads a self-contained `swiftlint` binary directly (no Docker/Swift toolchain needed). Always enforces the [shared config](configs/.swiftlint.yml) — not overridable per-package. | `ubuntu-latest` |
| `swiftformat-apply.yml` | Runs [SwiftFormat](https://github.com/nicklockwood/SwiftFormat) in apply mode against the [shared config](configs/.swiftformat) and opens a `bump:patch`-labeled pull request to `main` with the changes. Intended to be scheduled (e.g. weekly), not run on every PR. | `macos-latest` |
| `audit.yml` | Resolves dependencies, prints the dependency graph, and runs GitHub's dependency review action on PRs. | `ubuntu-latest` |
| `copyright-header-check.yml` | Fails unless every `*.swift` file carries the required Apache 2.0 copyright header (`Copyright <YEAR> adesso SE` + license notice) near the top of the file. | `ubuntu-latest` |
| `pr-label-check.yml` | Fails unless the pull request has **exactly one** of the labels `bump:major`, `bump:minor`, `bump:patch`. | `ubuntu-latest` |
| `auto-tag.yml` | On merge of a labeled PR into `main`, computes and pushes the next semver tag based on the label. Tag only — no GitHub Release. | `ubuntu-latest` |
| `pr-checks.yml` | Aggregator that chains `detect-platforms` → `build-test` + `lint` + `audit` + `copyright-header-check` for single-line integration. | mixed |

Composite actions (`actions/*`) hold the actual scripts and are consumed by the reusable workflows above; you
generally won't reference them directly unless building a custom workflow.

## Integrating a package (minimal footprint)

> **TODO:** the intended integration path is a dedicated **template repository** that new packages are
> created from, with the caller workflows below already wired up — no manual copying required. That template
> repository does not exist yet.

**Interim stopgap:** until the template repository exists, manually copy the example caller workflows from
[`examples/caller-workflows/`](examples/caller-workflows) into the consuming repository's
`.github/workflows/`. Four caller files are needed because they respond to four different GitHub events (PR
checks, label validation, post-merge tagging, scheduled formatting).

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
    uses: adesso-mobile-open-source/workflows-swift/.github/workflows/pr-checks.yml@v1
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
    uses: adesso-mobile-open-source/workflows-swift/.github/workflows/pr-label-check.yml@v1
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
    uses: adesso-mobile-open-source/workflows-swift/.github/workflows/auto-tag.yml@v1
    secrets: inherit
```

### 4. Scheduled SwiftFormat apply

```yaml
# .github/workflows/swiftformat-apply.yml
name: SwiftFormat Apply
on:
  schedule:
    - cron: "0 6 * * 1" # weekly, Monday 06:00 UTC
  workflow_dispatch: {}
jobs:
  swiftformat-apply:
    permissions: { contents: write, pull-requests: write }
    uses: adesso-mobile-open-source/workflows-swift/.github/workflows/swiftformat-apply.yml@v1
```

This opens a `bump:patch`-labeled pull request against `main` with any formatting changes — see
[`examples/caller-workflows/swiftformat-apply.yml`](examples/caller-workflows/swiftformat-apply.yml) and the
[Configuration overrides](#configuration-overrides) section below for why this runs on a schedule instead of
as a PR check.

## One-time setup per package repository

1. **Create three labels**: `bump:major`, `bump:minor`, `bump:patch`.
2. **Branch protection on `main`:**
   - Require the `PR Label` check (and the `PR Checks` check) to pass before merging.
   - Disallow direct pushes to `main` (all changes must go through a labeled PR) — this is what makes
     auto-tagging reliable, since it relies on the merged PR's label.
3. Every PR must carry exactly one of `bump:major`/`bump:minor`/`bump:patch` before it can merge. On merge,
   the tag is bumped and pushed automatically.

## Configuration overrides

- **SwiftLint:** the [shared config](configs/.swiftlint.yml) is always enforced by `lint.yml` and is **not**
  overridable per-package. A `.swiftlint.yml` committed in a consuming repository is ignored. This is
  intentional — a single, consistent lint config across all consuming packages is the point.
- **SwiftFormat:** likewise, the [shared config](configs/.swiftformat) is always enforced by
  `swiftformat-apply.yml` and is not overridable per-package. Formatting is applied (not just checked) by a
  scheduled job that opens a pull request with the result (see
  [§4 above](#4-scheduled-swiftformat-apply)), rather than by a blocking PR check. This is deliberate: running
  SwiftFormat in `--lint` mode as a required PR check alongside SwiftLint risks the two tools disagreeing on
  formatting-adjacent rules and blocking merges. Reviewing formatting changes as a normal, scheduled PR avoids
  that conflict.
  - The opened PR is authored with the default `GITHUB_TOKEN`, so it will **not** automatically trigger your
    `PR Checks`/`PR Label` workflows (GitHub's recursion-prevention rule for `GITHUB_TOKEN`-authored PRs).
    Review and merge it manually, or supply a PAT/GitHub App token via the workflow's `github-token` input if
    you need CI to run on it automatically.

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

### Linux support

SwiftPM's `platforms:` array can only express Apple platforms — there is no `.linux` case — so **whether a
package is built/tested on Linux cannot be derived from `Package.swift`**. It is controlled by the `linux`
input (exposed on `pr-checks.yml` and `detect-platforms.yml`, default `auto`):

- **`auto`** (default) — Linux runs only as the cross-platform fallback (i.e. when no `platforms:` array is
  declared). It is not added alongside declared Apple platforms. Preserves historical behavior.
- **`always`** — a Linux job always runs, in addition to any declared Apple platforms. Use this for
  pure-Swift libraries that pin Apple minimums (e.g. `platforms: [.macOS(.v13), .iOS(.v16)]`) but also
  support Linux.
- **`never`** — no Linux job ever runs. Fails loudly if that would leave an empty matrix (a cross-platform
  package with no Apple platforms).

```yaml
jobs:
  checks:
    uses: adesso-mobile-open-source/workflows-swift/.github/workflows/pr-checks.yml@v1
    secrets: inherit
    with:
      linux: always   # auto | always | never
```

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
- **GITHUB_TOKEN-authored PRs don't trigger PR checks either.** The pull request opened by
  `swiftformat-apply.yml` uses the default `GITHUB_TOKEN` unless a `github-token` override is supplied, so
  `PR Checks`/`PR Label` won't run on it automatically — review and merge manually, or supply a PAT/App token.
- **`uses:` cannot contain expressions.** Composite action references inside the reusable workflows (e.g.
  `adesso-mobile-open-source/workflows-swift/actions/detect-platforms@v1`) are pinned to a static ref by necessity — this
  is a hard GitHub Actions restriction, not an oversight. Bump these refs in lockstep with this repository's
  version tags.

## Versioning of this repository

This repository is tagged with semver tags (`1.2.3`) and a moving major tag (`v1`) that consuming packages
pin against in their `uses:` references, e.g. `...@v1`. Update the moving major tag when publishing
backwards-compatible releases.
