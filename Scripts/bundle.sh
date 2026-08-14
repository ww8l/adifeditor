#!/bin/sh
#
# Build ADIF Editor.app.
#
# Why this script exists: `swift build` produces a bare Mach-O executable, and that is
# not a Mac app. A document-based app needs an Info.plist to know its document types,
# and Apple Silicon refuses to execute an unsigned arm64 binary outright (§12), so the
# ad-hoc signature is required to launch at all — not just to avoid a Gatekeeper prompt.
# This script supplies both. Under a full Xcode install this is what the IDE would do.
#
# Usage:
#   Scripts/bundle.sh            debug, this machine's architecture — the dev loop
#   Scripts/bundle.sh release    release, universal arm64 + x86_64 — what ships (§5)
#
# The bundle lands in .build/ and is not tracked.

set -eu

CONFIGURATION="${1:-debug}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/.build/ADIF Editor.app"

case "$CONFIGURATION" in
    debug)   ARCH_FLAGS="" ;;
    release) ARCH_FLAGS="--arch arm64 --arch x86_64" ;;
    *)
        echo "error: unknown configuration '$CONFIGURATION' (expected debug or release)" >&2
        exit 1
        ;;
esac

echo "Building ($CONFIGURATION)…"
# shellcheck disable=SC2086
swift build --configuration "$CONFIGURATION" $ARCH_FLAGS --product ADIFEditor

# --show-bin-path reports the right directory for both the single-arch and the universal
# build, which put their output in different places.
# shellcheck disable=SC2086
BIN="$(swift build --configuration "$CONFIGURATION" $ARCH_FLAGS --show-bin-path)"

echo "Assembling bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN/ADIFEditor" "$APP/Contents/MacOS/ADIFEditor"
cp "$ROOT/Support/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Ad-hoc signature. Not optional on Apple Silicon: an arm64 binary with no signature is
# killed by the kernel rather than merely warned about.
echo "Signing…"
codesign --force --sign - \
    --entitlements "$ROOT/Support/ADIFEditor.entitlements" \
    --timestamp=none \
    "$APP" >/dev/null

codesign --verify --strict "$APP"

echo "Built $APP"
