#!/usr/bin/env bash
#
# detect-platforms.sh
#
# Parses the Package.swift manifest of a Swift package directly - no Swift
# toolchain required - and emits a JSON build matrix describing which
# platform jobs should run.
#
# Rules:
#   - If the manifest declares NO `platforms:` array, the package is
#     treated as cross-platform and only a Linux job is emitted.
#   - If a `platforms:` array IS declared, only the platforms found in that
#     array are emitted (no implicit Linux job is added). The array must be
#     a static literal (e.g. `platforms: [.iOS(.v16), .macOS(.v13)]`) -
#     computed/dynamic platform lists are not supported and cause a loud
#     failure rather than silently producing an incorrect matrix.
#   - Apple platforms (ios, macos, watchos, tvos, visionos) map to
#     macos-latest runners. Everything else not covered maps to Linux.
#   - Multiple platforms declared together are all emitted - there is no
#     "pick one" behavior. Every recognized platform literal in the array
#     becomes its own matrix entry, so declaring several Apple platforms at
#     once (e.g. an app that ships on macOS, iOS, and watchOS) produces one
#     job per platform, all running in parallel. See the worked example
#     below and the "Why this produces one job per platform" note further
#     down for the mechanics.
#
# Usage:
#   detect-platforms.sh [package-path]
#
# Output (stdout): a single line of JSON, e.g.
#   {"include":[{"platform":"linux","runner":"ubuntu-latest","kind":"spm"}]}
#
# This JSON is intended to be assigned directly to a GitHub Actions
# `strategy.matrix` via `fromJSON(...)`.
#
# Worked example - multiple platforms declared together:
#
#   Given this Package.swift:
#     platforms: [.macOS(.v13), .iOS(.v16), .watchOS(.v9)]
#
#   This script emits (formatted here for readability; actual output is a
#   single line):
#     {"include":[
#       {"platform":"macos","runner":"macos-latest","kind":"spm"},
#       {"platform":"ios","runner":"macos-latest","kind":"xcodebuild","sdk":"iphonesimulator"},
#       {"platform":"watchos","runner":"macos-latest","kind":"xcodebuild","sdk":"watchsimulator"}
#     ]}
#
#   Each object in "include" is consumed by build-test.yml as exactly one
#   matrix job (see that workflow's `strategy.matrix` for how GitHub Actions
#   turns this array into three parallel "macos" / "ios" / "watchos" jobs -
#   no cartesian product, no extra config needed per platform).

set -euo pipefail

PACKAGE_PATH="${1:-.}"
MANIFEST="$PACKAGE_PATH/Package.swift"

if [ ! -f "$MANIFEST" ]; then
  echo "error: Package.swift not found at '$MANIFEST'" >&2
  exit 1
fi

# Extract the `platforms: [ ... ]` array, if present. This is a plain-text
# extraction (no Swift compiler involved): it assumes the array is a static
# literal that does not itself span nested `[`/`]` pairs - true for every
# supported platform literal (e.g. `.iOS(.v16)` uses parentheses, not
# brackets, for its version specifier), so the first `]` encountered after
# `platforms:` closes the array in all realistic manifests.
PLATFORMS_BLOCK=""
FOUND_KEY=0
IN_BLOCK=0
while IFS= read -r line; do
  if [ "$IN_BLOCK" -eq 0 ]; then
    if printf '%s' "$line" | grep -q 'platforms[[:space:]]*:'; then
      FOUND_KEY=1
      IN_BLOCK=1
      # Drop everything before 'platforms:' on this line (e.g. leading
      # whitespace/indentation).
      line=$(printf '%s' "$line" | sed -E 's/^.*(platforms[[:space:]]*:)/\1/')
    else
      continue
    fi
  fi
  PLATFORMS_BLOCK="${PLATFORMS_BLOCK}${line}"$'\n'
  if printf '%s' "$line" | grep -q ']'; then
    break
  fi
done < "$MANIFEST"

if [ "$FOUND_KEY" -eq 1 ] && ! printf '%s' "$PLATFORMS_BLOCK" | grep -q ']'; then
  echo "error: found 'platforms:' in Package.swift but could not locate a closing ']' - the array may use unsupported formatting (e.g. it spans a very large number of lines, or is computed rather than a static literal)" >&2
  exit 1
fi

# An explicitly empty array (`platforms: []`) is a valid, common way to mark
# a package as cross-platform - distinguish it from a non-empty array we
# simply failed to parse (which is treated as an error below).
PLATFORMS_ARRAY_EMPTY=0
if [ "$FOUND_KEY" -eq 1 ]; then
  INNER=$(printf '%s' "$PLATFORMS_BLOCK" | sed -E 's/^[^\[]*\[//; s/\].*$//')
  if ! printf '%s' "$INNER" | grep -qE '[^[:space:]]'; then
    PLATFORMS_ARRAY_EMPTY=1
  fi
fi

# Map a declared platform literal (e.g. ".iOS") to its lowercase name.
# Matching is case-sensitive, mirroring the exact enum case spelling Swift
# itself requires (e.g. `.iOS`, not `.ios`).
# NOTE: avoid `mapfile`/`readarray` (bash 4+) for portability - macOS ships
# bash 3.2, and GitHub's macos-latest runners default to it as well.
# Why multi-platform declarations work: `grep -oE` (the `-o` flag) prints
# EVERY non-overlapping match in the block, not just the first - so a
# manifest declaring `[.macOS(.v13), .iOS(.v16), .watchOS(.v9)]` yields
# three separate lines (macos / ios / watchos) here, not one. The final
# `awk '!seen[$0]++'` only removes exact duplicates (e.g. if a platform
# literal appeared twice by mistake); it does not collapse distinct
# platforms into one. Each surviving name below becomes its own matrix
# entry further down, which is what ultimately produces one parallel job
# per declared platform in the GitHub Actions matrix.
DECLARED_PLATFORMS=()
if [ "$FOUND_KEY" -eq 1 ] && [ "$PLATFORMS_ARRAY_EMPTY" -eq 0 ]; then
  while IFS= read -r name; do
    [ -n "$name" ] && DECLARED_PLATFORMS+=("$name")
  done < <(
    printf '%s' "$PLATFORMS_BLOCK" \
      | grep -oE '\.(iOS|macOS|watchOS|tvOS|visionOS|linux|macCatalyst|driverKit)\b' \
      | sed 's/^\.//' \
      | tr '[:upper:]' '[:lower:]' \
      | awk '!seen[$0]++'
  )

  if [ "${#DECLARED_PLATFORMS[@]}" -eq 0 ]; then
    echo "error: found 'platforms:' in Package.swift but could not recognize any platform literal inside it - the array may use unsupported formatting or be computed rather than a static literal" >&2
    exit 1
  fi
fi

# Map a declared platform name to {platform, runner, kind}.
# kind: "spm"       -> plain `swift build && swift test`
#       "xcodebuild" -> `xcodebuild` against a simulator destination
platform_entry() {
  local name="$1"
  case "$name" in
    linux)
      printf '{"platform":"linux","runner":"ubuntu-latest","kind":"spm"}'
      ;;
    macos)
      printf '{"platform":"macos","runner":"macos-latest","kind":"spm"}'
      ;;
    ios)
      printf '{"platform":"ios","runner":"macos-latest","kind":"xcodebuild","sdk":"iphonesimulator"}'
      ;;
    watchos)
      printf '{"platform":"watchos","runner":"macos-latest","kind":"xcodebuild","sdk":"watchsimulator"}'
      ;;
    tvos)
      printf '{"platform":"tvos","runner":"macos-latest","kind":"xcodebuild","sdk":"appletvsimulator"}'
      ;;
    visionos)
      printf '{"platform":"visionos","runner":"macos-latest","kind":"xcodebuild","sdk":"xrsimulator"}'
      ;;
    *)
      # Recognized Swift platform literal, but not one we build a matrix
      # entry for (e.g. maccatalyst, driverkit): skip it rather than fail,
      # so newly introduced platform names don't break every consumer.
      echo "warning: unsupported platform '$name' declared in Package.swift - skipping" >&2
      return 1
      ;;
  esac
}

ENTRIES=()

if [ "${#DECLARED_PLATFORMS[@]}" -eq 0 ]; then
  # No `platforms:` array declared, or it was explicitly empty (`[]`) ->
  # treat as cross-platform, Linux only.
  ENTRIES+=("$(platform_entry linux)")
else
  for name in "${DECLARED_PLATFORMS[@]}"; do
    if entry=$(platform_entry "$name"); then
      ENTRIES+=("$entry")
    fi
  done
fi

if [ "${#ENTRIES[@]}" -eq 0 ]; then
  echo "error: no supported platforms could be resolved from Package.swift" >&2
  exit 1
fi

# Join entries into a JSON array and wrap as a matrix `include` list.
#
# Why this shape works with GitHub Actions: `{"include": [...]}` is GitHub
# Actions' "explicit include" form for `strategy.matrix`. Unlike a matrix
# built from dimension arrays (e.g. `os: [a, b]`, `version: [1, 2]`), which
# GitHub expands into a cartesian product, an `include`-only matrix creates
# EXACTLY ONE job per object in the array - no combining, no cartesian
# product. That is precisely what we want here: each object already fully
# describes one job (its platform, runner, and how to build/test it), so a
# 3-entry array (e.g. macos + ios + watchos) becomes 3 parallel jobs, and a
# 1-entry array (e.g. linux only) becomes exactly 1 job.
#
# The caller consumes this via `fromJSON(...)` to turn this JSON string
# into a real matrix object, and each key of an object (platform, runner,
# kind, sdk) becomes available in that job as `matrix.platform`,
# `matrix.runner`, `matrix.kind`, `matrix.sdk` - see build-test.yml for how
# those are read.
JOINED=$(IFS=,; echo "${ENTRIES[*]}")
echo "{\"include\":[${JOINED}]}"
