#!/bin/sh
#
# Build ADIF Editor.app, and for a release build the .dmg that ships it.
#
# Why this script exists: `swift build` produces a bare Mach-O executable, and that is
# not a Mac app. A document-based app needs an Info.plist to know its document types,
# and Apple Silicon refuses to execute an unsigned arm64 binary outright (§12), so the
# ad-hoc signature is required to launch at all — not just to avoid a Gatekeeper prompt.
# This script supplies both. Under a full Xcode install this is what the IDE would do.
#
# Usage:
#   Scripts/bundle.sh            debug, this machine's architecture — the dev loop
#   Scripts/bundle.sh release    universal arm64 + x86_64, plus the .dmg — what ships (§5)
#
# Both land in .build/ and are not tracked.
#
# Optional: MARKETING_VERSION=26.8.16 stamps that version into the bundled Info.plist
# instead of the value checked into Support/Info.plist. The release workflow sets it from
# the git tag, so the shipped .app carries the version it was tagged with and nobody has
# to remember to bump a plist by hand. Unset, the checked-in value is used untouched.

set -eu

CONFIGURATION="${1:-debug}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/.build/ADIF Editor.app"
DMG="$ROOT/.build/ADIF Editor.dmg"

# §5's minimum. Spelled into the triples below so a release build cannot silently
# acquire a higher deployment target than the one that was promised.
DEPLOYMENT_TARGET="14.0"

case "$CONFIGURATION" in
    debug|release) ;;
    *)
        echo "error: unknown configuration '$CONFIGURATION' (expected debug or release)" >&2
        exit 1
        ;;
esac

# Builds one architecture and echoes the directory its product landed in.
build_arch() {
    arch="$1"
    triple="$arch-apple-macosx$DEPLOYMENT_TARGET"

    swift build --configuration release --triple "$triple" --product ADIFEditor >&2
    swift build --configuration release --triple "$triple" --show-bin-path
}

echo "Building ($CONFIGURATION)…"

if [ "$CONFIGURATION" = "debug" ]; then
    swift build --configuration debug --product ADIFEditor
    BIN="$(swift build --configuration debug --show-bin-path)/ADIFEditor"
else
    # Two single-architecture builds joined with lipo, rather than SwiftPM's
    # `--arch arm64 --arch x86_64`. That flag delegates to xcbuild, which lives inside
    # Xcode.app and is absent from Command Line Tools — so on this machine (decision 9)
    # it fails outright with "xcbuild executable ... does not exist". Cross-compiling to
    # x86_64 works fine under CLT, so building each slice separately gets the universal
    # binary §5 asks for without reintroducing the Xcode dependency.
    ARM_BIN="$(build_arch arm64)"
    X86_BIN="$(build_arch x86_64)"

    BIN="$ROOT/.build/ADIFEditor-universal"
    lipo -create -output "$BIN" "$ARM_BIN/ADIFEditor" "$X86_BIN/ADIFEditor"
fi

echo "Assembling bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/ADIFEditor"
cp "$ROOT/Support/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Version stamped into the copy, never back into Support/Info.plist: the source file
# stays at whatever the working tree says, so a release build leaves no dirt behind and
# the git tag is the single source of truth for what shipped.
#
# Both keys, not just the display string. CFBundleVersion is what macOS compares to
# decide which of two builds is newer, and it is hardcoded to 1 in Support/Info.plist —
# ship that unchanged and every release claims to be the same build. CalVer sorts
# correctly there because the comparison is component-wise: 26.8.6 < 26.8.16.
if [ -n "${MARKETING_VERSION:-}" ]; then
    /usr/libexec/PlistBuddy \
        -c "Set :CFBundleShortVersionString $MARKETING_VERSION" \
        -c "Set :CFBundleVersion $MARKETING_VERSION" \
        "$APP/Contents/Info.plist"
    echo "Stamped version $MARKETING_VERSION"
fi

# Ad-hoc signature. Not optional on Apple Silicon: an arm64 binary with no signature is
# killed by the kernel rather than merely warned about.
#
# Signed after lipo, never before: joining two signed slices invalidates both, because
# each signature covers a Mach-O that no longer exists byte-for-byte inside the fat file.
echo "Signing…"
codesign --force --sign - \
    --entitlements "$ROOT/Support/ADIFEditor.entitlements" \
    --timestamp=none \
    "$APP" >/dev/null

codesign --verify --strict "$APP"

echo "Built $APP"

[ "$CONFIGURATION" = "release" ] || exit 0

# The disk image. `hdiutil` ships with macOS, so unlike the universal build this needs
# nothing from Xcode and runs headless in CI.
#
# Deliberately a plain image: the app and a symlink to /Applications, which is the
# drag-across layout people expect. A custom background and fixed icon positions would
# need Finder scripting and a real GUI session, which CI does not have.
echo "Building disk image…"

STAGE="$ROOT/.build/dmg-stage"
rm -rf "$STAGE"
mkdir -p "$STAGE"

cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create \
    -volname "ADIF Editor" \
    -srcfolder "$STAGE" \
    -ov -quiet -format UDZO \
    "$DMG"

rm -rf "$STAGE"

hdiutil verify -quiet "$DMG"

echo "Built $DMG"
