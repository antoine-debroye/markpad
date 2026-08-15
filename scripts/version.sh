#!/usr/bin/env bash
# Reads and bumps Markpad's version.
#
#   ./scripts/version.sh              print the current version
#   ./scripts/version.sh patch        1.2.3 -> 1.2.4
#   ./scripts/version.sh minor        1.2.3 -> 1.3.0
#   ./scripts/version.sh major        1.2.3 -> 2.0.0
#   ./scripts/version.sh set 2.0.0    set the marketing version outright
#   ./scripts/version.sh build        leave the marketing version, bump the build only
#
# project.yml holds both numbers and is the only source of truth: the app target and the
# Quick Look extension both read them, which keeps the extension's version in step with its
# host. Nested code signed with a different version fails validation, so they must not drift.
#
# The build number rises on every bump and is never reset — including across a major bump.
# macOS wants CFBundleVersion to increase monotonically for a given CFBundleShortVersionString,
# and notarised builds are rejected if a version is ever reused. Keeping one ever-rising
# counter makes reuse impossible by construction.
set -euo pipefail

cd "$(dirname "$0")/.."

PROJECT="project.yml"

read_value() {
    # The key appears once, under settings.base.
    sed -nE "s/^[[:space:]]*$1:[[:space:]]*\"?([^\"]*)\"?[[:space:]]*$/\1/p" "$PROJECT" | head -1
}

write_value() {
    local key="$1" value="$2"
    # Anchored to the start of the line so only the settings.base entry is touched, and the
    # existing indentation is preserved.
    sed -i '' -E "s|^([[:space:]]*$key:[[:space:]]*).*$|\1\"$value\"|" "$PROJECT"
}

MARKETING="$(read_value MARKETING_VERSION)"
BUILD="$(read_value CURRENT_PROJECT_VERSION)"

if [[ -z "$MARKETING" || -z "$BUILD" ]]; then
    echo "Could not read the version out of $PROJECT" >&2
    exit 1
fi

# "1.0" and "1" are both valid in a plist but make bumping ambiguous, so normalise to X.Y.Z.
IFS='.' read -r MAJOR MINOR PATCH <<< "$MARKETING"
MAJOR="${MAJOR:-0}"; MINOR="${MINOR:-0}"; PATCH="${PATCH:-0}"

usage() {
    # The usage block at the top of this file, minus the comment markers.
    sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'
}

COMMAND="${1:-show}"
case "$COMMAND" in
    show)
        echo "$MAJOR.$MINOR.$PATCH (build $BUILD)"
        exit 0
        ;;
    major) MAJOR=$((MAJOR + 1)); MINOR=0; PATCH=0 ;;
    minor) MINOR=$((MINOR + 1)); PATCH=0 ;;
    patch) PATCH=$((PATCH + 1)) ;;
    build) ;;
    set)
        NEW="${2:-}"
        if ! [[ "$NEW" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "Usage: $0 set <major.minor.patch>, e.g. $0 set 2.0.0" >&2
            exit 1
        fi
        IFS='.' read -r MAJOR MINOR PATCH <<< "$NEW"
        ;;
    -h|--help|help)
        usage
        exit 0
        ;;
    *)
        echo "Unknown command: $COMMAND" >&2
        echo >&2
        usage >&2
        exit 1
        ;;
esac

NEW_MARKETING="$MAJOR.$MINOR.$PATCH"
NEW_BUILD=$((BUILD + 1))

write_value MARKETING_VERSION "$NEW_MARKETING"
write_value CURRENT_PROJECT_VERSION "$NEW_BUILD"

echo "==> $MARKETING (build $BUILD) -> $NEW_MARKETING (build $NEW_BUILD)"

# Regenerating keeps Markpad.xcodeproj in step, so a build straight after a bump carries the
# new number rather than the previous one.
if command -v xcodegen >/dev/null 2>&1; then
    xcodegen generate >/dev/null
    echo "==> Regenerated Markpad.xcodeproj"
else
    echo "Note: xcodegen not found; run it before building so the change takes effect." >&2
fi
