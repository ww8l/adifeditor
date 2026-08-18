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
# Overridable so a checking build can go somewhere disposable rather than replacing the
# bundle that is routinely open on this machine — see Scripts/ci-local.sh.
APP="${BUNDLE_DEST:-$ROOT/.build/ADIF Editor.app}"
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

# The .icns is generated here rather than committed, so Support/Icon/AppIcon-1024.png is
# the single source of truth and a derived binary can never drift from it. Both tools
# ship with macOS — `sips` and `iconutil` are in /usr/bin, not inside Xcode.app — so this
# costs nothing under decision 9 and runs headless in CI.
#
# The @2x entries are not decoration: macOS picks the representation by point size, and a
# Retina Dock asks for 512x512@2x. Omit them and the icon renders from a smaller bitmap
# and looks soft on exactly the displays this app is used on.
echo "Building icon…"
ICONSET="$ROOT/.build/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"

for spec in \
    "16 icon_16x16" "32 icon_16x16@2x" \
    "32 icon_32x32" "64 icon_32x32@2x" \
    "128 icon_128x128" "256 icon_128x128@2x" \
    "256 icon_256x256" "512 icon_256x256@2x" \
    "512 icon_512x512" "1024 icon_512x512@2x"
do
    px="${spec% *}"
    name="${spec#* }"
    sips -z "$px" "$px" "$ROOT/Support/Icon/AppIcon-1024.png" \
        --out "$ICONSET/$name.png" >/dev/null

    # `sips` prints "not a valid file - skipping" and exits 0 when it cannot read the
    # source, so `set -e` never sees a size go missing. What ships then is an app whose
    # Dock icon silently falls back to a smaller bitmap — the exact thing the @2x entries
    # above exist to prevent.
    [ -s "$ICONSET/$name.png" ] \
        || { echo "error: icon size ${px}px ($name) was not produced" >&2; exit 1; }
done

ICNS="$APP/Contents/Resources/AppIcon.icns"
iconutil --convert icns "$ICONSET" --output "$ICNS"
rm -rf "$ICONSET"

# And `iconutil` exits 0 on an iconset holding only some of the representations, writing
# a 4 KB .icns where a complete one is ~150 KB. Converting back is the direct question —
# how many representations does the file actually hold — rather than a guess at a size
# floor that a future icon could fall under honestly.
VERIFY="$ROOT/.build/AppIcon-verify.iconset"
rm -rf "$VERIFY"
iconutil --convert iconset "$ICNS" --output "$VERIFY"
REPRESENTATIONS="$(find "$VERIFY" -name '*.png' | wc -l | tr -d ' ')"
rm -rf "$VERIFY"
[ "$REPRESENTATIONS" -eq 10 ] \
    || { echo "error: AppIcon.icns holds $REPRESENTATIONS of 10 representations" >&2; exit 1; }

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
