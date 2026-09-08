#!/usr/bin/env bash
#
# bump-version.sh - Bump the pinned workflow version tag across the whole repo.
#
# GitHub Actions forbids expressions (${{ ... }}) in `uses:` refs, so the
# version tag that this repository's reusable workflows pin against cannot be
# read from a single runtime variable. Instead, this script rewrites every
# occurrence in one step so a version bump touches only one command.
#
# Usage:
#   ./scripts/bump-version.sh vX.Y.Z
#
# The current (old) version is auto-detected by scanning the workflow files.
# If the workflows contain more than one distinct tag (i.e. refs have drifted),
# the script aborts rather than guessing.
#
# It rewrites the tag in three textual forms:
#   1. @vX.Y.Z            - in `uses:` refs and the `config-file:` value
#   2. ref: vX.Y.Z        - standalone checkout refs
#   3. `...vX.Y.Z...`     - README prose / backtick-wrapped mentions
#
# Files covered:
#   - .github/workflows/*.yml
#   - README.md
#   - examples/caller-workflows/*.yml

set -euo pipefail

# Resolve repo root relative to this script so it works from any CWD.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

die() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

# --- Validate arguments -----------------------------------------------------

[ "$#" -eq 1 ] || die "usage: $(basename "$0") vX.Y.Z"

NEW_VERSION="$1"
VERSION_RE='^v[0-9]+\.[0-9]+\.[0-9]+$'
[[ "$NEW_VERSION" =~ $VERSION_RE ]] \
  || die "new version '$NEW_VERSION' is not a valid semver tag (expected vX.Y.Z)"

# --- Collect the files we operate on ----------------------------------------

FILES=()
while IFS= read -r f; do
  [ -f "$f" ] && FILES+=("$f")
done <<EOF
$(
  ls "$REPO_ROOT"/.github/workflows/*.yml 2>/dev/null || true
  ls "$REPO_ROOT"/examples/caller-workflows/*.yml 2>/dev/null || true
  [ -f "$REPO_ROOT/README.md" ] && printf '%s\n' "$REPO_ROOT/README.md"
)
EOF

[ "${#FILES[@]}" -gt 0 ] || die "no target files found under $REPO_ROOT"

# --- Auto-detect the current (old) version ----------------------------------
# Authoritative source: the workflow files. We look for the tag in both the
# `@vX.Y.Z` form and the `ref: vX.Y.Z` form, restricted to this project's own
# repo references, so unrelated pins (actions/checkout@v7, swiftlint@v1.1.0)
# never interfere.

TAG_GREP='(adesso-mobile-open-source/[^@[:space:]]+@|ref:[[:space:]]+)v[0-9]+\.[0-9]+\.[0-9]+'

DETECTED="$(
  grep -hoE "$TAG_GREP" "$REPO_ROOT"/.github/workflows/*.yml 2>/dev/null \
    | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' \
    | sort -u || true
)"

[ -n "$DETECTED" ] || die "could not detect any current version tag in .github/workflows/*.yml"

DISTINCT_COUNT="$(printf '%s\n' "$DETECTED" | grep -c .)"
if [ "$DISTINCT_COUNT" -ne 1 ]; then
  {
    printf 'error: workflows contain %s distinct version tags; refusing to guess.\n' "$DISTINCT_COUNT"
    printf 'Detected tags:\n'
    printf '  %s\n' $DETECTED
    printf 'Reconcile them manually first, then re-run.\n'
  } >&2
  exit 1
fi

OLD_VERSION="$DETECTED"

if [ "$OLD_VERSION" = "$NEW_VERSION" ]; then
  die "current version is already $NEW_VERSION; nothing to do"
fi

# --- Perform the replacement -------------------------------------------------
# Anchor on the exact OLD literal with explicit delimiter guards so the match is
# unambiguous and portable across BSD (macOS) and GNU sed (neither `\b` nor
# lookahead can be relied on):
#   - The tag is always preceded by `@`, a space, a backtick, or a quote, and
#     the surrounding regex already scopes to that, so no left guard is needed
#     beyond matching the literal.
#   - The right guard `([^0-9.]|$)` ensures we do not match a prefix of a longer
#     tag (e.g. v1.0.3 inside v1.0.30) and is captured/re-emitted as \1.
# This cannot collide with @v7, @v1.1.0, or the illustrative "1.2.3" example in
# the README (which has no leading `v`).

OLD_ESC="$(printf '%s' "$OLD_VERSION" | sed 's/[.[\*^$/]/\\&/g')"
NEW_ESC="$(printf '%s' "$NEW_VERSION" | sed 's/[&/\]/\\&/g')"

TOTAL=0
CHANGED_FILES=()
for f in "${FILES[@]}"; do
  count="$(grep -oE "${OLD_ESC}([^0-9.]|$)" "$f" 2>/dev/null | grep -c . || true)"
  if [ "$count" -gt 0 ]; then
    # Use a temp file instead of `sed -i` to stay portable across BSD/GNU sed.
    tmp="$(mktemp)"
    sed -E "s/${OLD_ESC}([^0-9.]|\$)/${NEW_ESC}\1/g" "$f" > "$tmp"
    mv "$tmp" "$f"
    CHANGED_FILES+=("$f")
    TOTAL=$((TOTAL + count))
  fi
done

[ "$TOTAL" -gt 0 ] || die "found version $OLD_VERSION but replaced 0 occurrences (unexpected)"

# --- Summary -----------------------------------------------------------------

printf 'Bumped %s -> %s (%s occurrence(s) across %s file(s)):\n' \
  "$OLD_VERSION" "$NEW_VERSION" "$TOTAL" "${#CHANGED_FILES[@]}"
for f in "${CHANGED_FILES[@]}"; do
  printf '  %s\n' "${f#"$REPO_ROOT"/}"
done
printf '\nReview the diff, then commit:\n'
printf "  git commit -am 'Bump workflow version to %s'\n" "$NEW_VERSION"
