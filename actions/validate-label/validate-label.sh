#!/usr/bin/env bash
#
# validate-label.sh
#
# Validates that a pull request has EXACTLY ONE of the semver labels
# `major`, `minor`, or `patch` applied. Used to gate merges so that every
# PR unambiguously declares its version bump.
#
# Usage:
#   validate-label.sh <labels-json>
#
# <labels-json> is a JSON array of label name strings, e.g.:
#   '["major"]'                 -> valid (exit 0)
#   '["bug", "patch"]'          -> valid (exit 0)
#   '[]'                        -> invalid: no semver label (exit 1)
#   '["major", "minor"]'        -> invalid: more than one semver label (exit 1)
#
# In a GitHub Actions workflow this is typically invoked as:
#   validate-label.sh "$(jq -c '.' <<< "$LABELS_JSON")"
# where LABELS_JSON comes from:
#   toJSON(github.event.pull_request.labels.*.name)

set -euo pipefail

LABELS_JSON="${1:-}"

if [ -z "$LABELS_JSON" ]; then
  echo "::error::no labels JSON provided to validate-label.sh" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "::error::'jq' is required but not found on PATH" >&2
  exit 1
fi

SEMVER_LABELS=(major minor patch)

MATCHED=()
for label in "${SEMVER_LABELS[@]}"; do
  if echo "$LABELS_JSON" | jq -e --arg l "$label" 'any(.[]; . == $l)' >/dev/null 2>&1; then
    MATCHED+=("$label")
  fi
done

COUNT="${#MATCHED[@]}"

if [ "$COUNT" -eq 0 ]; then
  echo "::error::pull request must have exactly one of the labels: major, minor, patch (found none)" >&2
  exit 1
elif [ "$COUNT" -gt 1 ]; then
  echo "::error::pull request must have exactly one of the labels: major, minor, patch (found: ${MATCHED[*]})" >&2
  exit 1
fi

echo "OK: exactly one semver label found: ${MATCHED[0]}"
exit 0
