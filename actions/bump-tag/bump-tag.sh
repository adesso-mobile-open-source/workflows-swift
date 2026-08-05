#!/usr/bin/env bash
#
# bump-tag.sh
#
# Computes the next semantic version tag based on the latest existing
# `v<major>.<minor>.<patch>` tag and a bump level (major|minor|patch), then
# creates and pushes that tag pointing at the current commit (HEAD).
#
# This script does NOT create a GitHub Release - it only pushes the tag.
# It intentionally pushes using whatever credentials are already configured
# for `git push` in the calling environment (typically the default
# GITHUB_TOKEN). Note: tags pushed with the default GITHUB_TOKEN do not
# trigger further workflow runs - see README for details.
#
# Usage:
#   bump-tag.sh <major|minor|patch> [--dry-run]
#
# Requires: git (run inside a checkout with full tag history, i.e.
# `actions/checkout` with `fetch-depth: 0`).

set -euo pipefail

BUMP_LEVEL="${1:-}"
DRY_RUN="${2:-}"

case "$BUMP_LEVEL" in
  major|minor|patch) ;;
  *)
    echo "::error::usage: bump-tag.sh <major|minor|patch> [--dry-run]" >&2
    exit 1
    ;;
esac

if ! command -v git >/dev/null 2>&1; then
  echo "::error::'git' is required but not found on PATH" >&2
  exit 1
fi

git fetch --tags --quiet || true

LATEST_TAG=$(git tag --list 'v[0-9]*.[0-9]*.[0-9]*' --sort=-v:refname | head -n1)
LATEST_TAG="${LATEST_TAG:-v0.0.0}"

VERSION="${LATEST_TAG#v}"
IFS='.' read -r MAJOR MINOR PATCH <<< "$VERSION"

MAJOR="${MAJOR:-0}"
MINOR="${MINOR:-0}"
PATCH="${PATCH:-0}"

case "$BUMP_LEVEL" in
  major)
    MAJOR=$((MAJOR + 1))
    MINOR=0
    PATCH=0
    ;;
  minor)
    MINOR=$((MINOR + 1))
    PATCH=0
    ;;
  patch)
    PATCH=$((PATCH + 1))
    ;;
esac

NEXT_TAG="v${MAJOR}.${MINOR}.${PATCH}"

echo "Latest tag: ${LATEST_TAG}"
echo "Bump level: ${BUMP_LEVEL}"
echo "Next tag:   ${NEXT_TAG}"

if [ "$DRY_RUN" = "--dry-run" ]; then
  echo "Dry run - not creating or pushing tag."
else
  git tag "$NEXT_TAG"
  git push origin "$NEXT_TAG"
fi

# Emit for consumption via GITHUB_OUTPUT if present (both dry-run and real).
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "next-tag=${NEXT_TAG}" >> "$GITHUB_OUTPUT"
fi
