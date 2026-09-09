#!/usr/bin/env bash
#
# detect-platforms.sh
#
# Parses the Package.swift manifest of a Swift package directly - no Swift
# toolchain required - and emits a JSON build matrix describing which
# platform jobs should run.
#
# Rules:
#   - The `platforms:` array is the single source of truth for which jobs
#     run. Every recognized platform literal in that array becomes its own
#     matrix entry (one parallel job per platform - there is no "pick one"
#     behavior). The array must be a static literal (e.g.
#     `platforms: [.iOS(.v16), .macOS(.v13)]`) - computed/dynamic platform
#     lists are not supported and cause a loud failure rather than silently
#     producing an incorrect matrix.
#   - Apple platforms (ios, macos, watchos, tvos, visionos) map to
#     macos-latest runners (macos runs `swift build && swift test`; the
#     simulator platforms run `xcodebuild` against a simulator destination).
#   - If NO `platforms:` array is declared (or it is empty, `[]`), the
#     matrix is empty and the script fails loudly - a package must declare
#     at least one platform (see "Linux support" below for how to opt in to
#     a Linux job).
#
# Linux support:
#   SwiftPM's `platforms:` array has no `.linux` case in its `SupportedPlatform`
#   factories, so a bare `.linux` literal is not valid Swift. Linux is opted
#   into explicitly by declaring a custom platform inside the SAME `platforms:`
#   array:
#
#     platforms: [.macOS(.v13), .custom("linux", versionString: "1.0")]
#
#   This is valid Swift (PackageDescription >= 5.6 / swift-tools-version >= 5.6)
#   and lives in the repo-owned Package.swift rather than in a template-synced
#   workflow input, so it never shows up as template drift. Semantics are a
#   strict boolean:
#     - `.custom("linux", ...)` present  -> a Linux job (ubuntu-latest, spm) runs.
#     - `.custom("linux", ...)` absent   -> no Linux job runs.
#   There is no implicit Linux fallback: a package with no `platforms:` array
#   (or an empty one) resolves to an empty matrix and fails loudly.
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
#     platforms: [.macOS(.v13), .iOS(.v16), .custom("linux", versionString: "1.0")]
#
#   This script emits (formatted here for readability; actual output is a
#   single line):
#     {"include":[
#       {"platform":"macos","runner":"macos-latest","kind":"spm"},
#       {"platform":"ios","runner":"macos-latest","kind":"xcodebuild","sdk":"iphonesimulator"},
#       {"platform":"linux","runner":"ubuntu-latest","kind":"spm"}
#     ]}
#
#   Each object in "include" is consumed by build-test.yml as exactly one
#   matrix job (see that workflow's `strategy.matrix` for how GitHub Actions
#   turns this array into parallel jobs - no cartesian product, no extra
#   config needed per platform).

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
# brackets, for its version specifier, and `.custom("linux", ...)` likewise),
# so the first `]` encountered after `platforms:` closes the array in all
# realistic manifests.
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

# An explicitly empty array (`platforms: []`) is distinguished from a
# non-empty array we simply failed to parse (which is treated as an error
# below). Both an empty array and a missing array resolve to an empty matrix
# and fail loudly further down.
PLATFORMS_ARRAY_EMPTY=0
if [ "$FOUND_KEY" -eq 1 ]; then
  INNER=$(printf '%s' "$PLATFORMS_BLOCK" | sed -E 's/^[^\[]*\[//; s/\].*$//')
  if ! printf '%s' "$INNER" | grep -qE '[^[:space:]]'; then
    PLATFORMS_ARRAY_EMPTY=1
  fi
fi

# Detect an opt-in Linux job. SwiftPM has no `.linux` SupportedPlatform
# factory, so Linux is declared via `.custom("linux", versionString: "...")`
# inside the same `platforms:` array. Match is tolerant of whitespace and
# either single or double quotes around the platform name, e.g.
#   .custom("linux", versionString: "1.0")
#   .custom( 'linux' , versionString: "1.0" )
HAS_CUSTOM_LINUX=0
if [ "$FOUND_KEY" -eq 1 ] && [ "$PLATFORMS_ARRAY_EMPTY" -eq 0 ]; then
  if printf '%s' "$PLATFORMS_BLOCK" \
    | grep -qE '\.custom[[:space:]]*\([[:space:]]*["'\'']linux["'\'']'; then
    HAS_CUSTOM_LINUX=1
  fi
fi

# Map a declared Apple platform literal (e.g. ".iOS") to its lowercase name.
# Matching is case-sensitive, mirroring the exact enum case spelling Swift
# itself requires (e.g. `.iOS`, not `.ios`).
# NOTE: avoid `mapfile`/`readarray` (bash 4+) for portability - macOS ships
# bash 3.2, and GitHub's macos-latest runners default to it as well.
# Why multi-platform declarations work: `grep -oE` (the `-o` flag) prints
# EVERY non-overlapping match in the block, not just the first - so a
# manifest declaring `[.macOS(.v13), .iOS(.v16)]` yields two separate lines
# (macos / ios) here, not one. The final `awk '!seen[$0]++'` only removes
# exact duplicates; it does not collapse distinct platforms into one.
# The `.custom("linux", ...)` literal is handled separately (above) and is
# intentionally NOT matched here.
DECLARED_PLATFORMS=()
if [ "$FOUND_KEY" -eq 1 ] && [ "$PLATFORMS_ARRAY_EMPTY" -eq 0 ]; then
  while IFS= read -r name; do
    [ -n "$name" ] && DECLARED_PLATFORMS+=("$name")
  done < <(
    printf '%s' "$PLATFORMS_BLOCK" \
      | grep -oE '\.(iOS|macOS|watchOS|tvOS|visionOS|macCatalyst|driverKit)\b' \
      | sed 's/^\.//' \
      | tr '[:upper:]' '[:lower:]' \
      | awk '!seen[$0]++'
  )

  if [ "${#DECLARED_PLATFORMS[@]}" -eq 0 ] && [ "$HAS_CUSTOM_LINUX" -eq 0 ]; then
    echo "error: found 'platforms:' in Package.swift but could not recognize any supported platform literal inside it - the array may use unsupported formatting or be computed rather than a static literal" >&2
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

# Build one entry per recognized Apple platform declared in the array.
for name in "${DECLARED_PLATFORMS[@]:-}"; do
  [ -z "$name" ] && continue
  if entry=$(platform_entry "$name"); then
    ENTRIES+=("$entry")
  fi
done

# Add the Linux entry iff the package opted in via `.custom("linux", ...)`.
if [ "$HAS_CUSTOM_LINUX" -eq 1 ]; then
  ENTRIES+=("$(platform_entry linux)")
fi

if [ "${#ENTRIES[@]}" -eq 0 ]; then
  echo "error: no platforms resolved from Package.swift - declare at least one platform in the 'platforms:' array (Apple platforms via e.g. '.macOS(.v13)', and/or Linux via '.custom(\"linux\", versionString: \"1.0\")')" >&2
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
# 3-entry array (e.g. macos + ios + linux) becomes 3 parallel jobs, and a
# 1-entry array (e.g. linux only) becomes exactly 1 job.
#
# The caller consumes this via `fromJSON(...)` to turn this JSON string
# into a real matrix object, and each key of an object (platform, runner,
# kind, sdk) becomes available in that job as `matrix.platform`,
# `matrix.runner`, `matrix.kind`, `matrix.sdk` - see build-test.yml for how
# those are read.
JOINED=$(IFS=,; echo "${ENTRIES[*]}")
echo "{\"include\":[${JOINED}]}"
