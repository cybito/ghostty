#!/usr/bin/env bash

usage() {
    cat <<'EOF'
Usage: script/update-local-release.sh [--install] [--no-build] [--ref REF]

Merge the latest upstream Ghostty main into custom and build an optimized local app.

Options:
  --install    Replace /Applications/Ghostty.app with the built app
  --no-build   Merge without building
  --ref REF    Merge a specific fetched commit, branch, or tag instead of origin/main
  -h, --help   Show this help

The local build uses Ghostty's ReleaseLocal configuration: release optimizations
with local signing. Set GHOSTTY_CODESIGN_IDENTITY to choose a signing identity;
otherwise the first valid identity is used, falling back to ad-hoc signing.
EOF
}

set -euo pipefail

BRANCH=custom
REMOTE=origin
INSTALL=0
BUILD=1
PINNED_REF=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --install)
            INSTALL=1
            ;;
        --no-build)
            BUILD=0
            ;;
        --ref)
            if [[ $# -lt 2 || "$2" == --* ]]; then
                usage >&2
                exit 2
            fi
            PINNED_REF="$2"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            exit 2
            ;;
    esac
    shift
done

cd "$(git rev-parse --show-toplevel)"

if [[ -n "$(git status --porcelain)" ]]; then
    echo "ERROR: working tree is dirty; commit or stash changes before upgrading." >&2
    git status --short >&2
    exit 1
fi

CURRENT="$(git branch --show-current)"
if [[ "$CURRENT" != "$BRANCH" ]]; then
    git checkout "$BRANCH"
fi

if [[ -n "$PINNED_REF" ]]; then
    git fetch --tags --force "$REMOTE"
    TARGET_REF="$PINNED_REF"
else
    git fetch "$REMOTE" main
    TARGET_REF="$REMOTE/main"
fi

if ! git rev-parse --verify --quiet "$TARGET_REF^{commit}" >/dev/null; then
    echo "ERROR: fetched ref does not resolve to a commit: $TARGET_REF" >&2
    exit 1
fi
echo "==> target ref: $TARGET_REF"

if git merge-base --is-ancestor "$TARGET_REF" HEAD; then
    echo "==> already contains $TARGET_REF"
else
    echo "==> merging $TARGET_REF into $BRANCH"
    if [[ -z "$(git config user.email || true)" ]]; then
        GIT=(git -c user.name="${USER:-local}" -c user.email="${USER:-local}@localhost")
    else
        GIT=(git)
    fi

    if ! "${GIT[@]}" merge --no-edit "$TARGET_REF"; then
        echo >&2
        echo "CONFLICT: upstream and local changes overlap." >&2
        echo "  Continue: git add -A && git merge --continue" >&2
        echo "  Abort:    git merge --abort" >&2
        exit 1
    fi
fi

if [[ $BUILD -eq 1 ]]; then
    [[ "$(uname)" == "Darwin" ]] || { echo "ERROR: the macOS app must be built on Darwin." >&2; exit 1; }
    command -v zig >/dev/null || { echo "ERROR: zig is required." >&2; exit 1; }
    command -v nu >/dev/null || { echo "ERROR: nushell is required." >&2; exit 1; }

    echo "==> building GhosttyKit (ReleaseFast)"
    zig build -Doptimize=ReleaseFast -Demit-macos-app=false

    echo "==> building Ghostty.app (ReleaseLocal)"
    macos/build.nu --scheme Ghostty --configuration ReleaseLocal --action build

    SOURCE="macos/build/ReleaseLocal/Ghostty.app"
    [[ -d "$SOURCE" ]] || { echo "ERROR: build output missing: $SOURCE" >&2; exit 1; }

    SIGNING_IDENTITY="${GHOSTTY_CODESIGN_IDENTITY:-}"
    if [[ -z "$SIGNING_IDENTITY" ]]; then
        SIGNING_IDENTITY="$(security find-identity -v -p codesigning \
            | sed -nE 's/^[[:space:]]*[0-9]+\) ([0-9A-F]{40}) ".*"$/\1/p' \
            | sed -n '1p')"
    fi

    if [[ -n "$SIGNING_IDENTITY" ]]; then
        echo "==> signing with local identity $SIGNING_IDENTITY"
        codesign --force --sign "$SIGNING_IDENTITY" --options runtime --timestamp=none \
            "$SOURCE/Contents/PlugIns/DockTilePlugin.plugin"
        codesign --force --sign "$SIGNING_IDENTITY" --options runtime --timestamp=none \
            --entitlements macos/GhosttyReleaseLocal.entitlements "$SOURCE"
    else
        echo "WARNING: no local signing identity found; privacy permissions may reset after each rebuild." >&2
    fi

    codesign --verify --deep --strict "$SOURCE"

    if [[ $INSTALL -eq 1 ]]; then
        TARGET="/Applications/Ghostty.app"

        if pgrep -xq ghostty || pgrep -xq Ghostty; then
            echo "WARNING: Ghostty is running; quit and relaunch it after installation." >&2
        fi

        STAGING="$(mktemp -d /Applications/.ghostty-install.XXXXXX)"
        trap 'rm -rf "$STAGING"' EXIT
        ditto "$SOURCE" "$STAGING/Ghostty.app"
        rm -rf "$TARGET"
        mv "$STAGING/Ghostty.app" "$TARGET"
        echo "==> installed $TARGET"
    fi
fi

echo "==> done: $BRANCH contains $TARGET_REF"
