#!/bin/sh
#
# Structural checks on a built ADIF Editor.app.
#
# `swift build` succeeding says nothing about the bundle: Info.plist, the entitlements
# and the ad-hoc signature come together only in Scripts/bundle.sh, and a broken one of
# any of them still compiles perfectly. Until this existed, the only automated coverage
# of that assembly was a workflow that had never run and a release workflow that fires on
# a tag — so a plist or entitlements regression would surface at the moment a version
# number was being spent, on a 10x-billed runner.
#
# Checks what a wrong file would silently cost, not everything that could be asserted:
#
#   * the executable is there and runnable            — an app that cannot launch
#   * the bundle identifier                           — a second app in LaunchServices,
#                                                       and a Keychain item nothing finds
#   * the document types                              — the app opens nothing by
#                                                       double-click, which is §12's whole
#                                                       reason for the plist
#   * the icon                                        — Scripts/bundle.sh proves it is
#                                                       complete; this proves it shipped
#   * the signature verifies                          — Apple Silicon kills an unsigned
#                                                       arm64 binary outright (§12)
#   * the sandbox and its three entitlements, exactly — §6.5. network.server appearing
#                                                       here would be the one-way door
#                                                       decision 17 refused to open
#
# Usage: Scripts/verify-bundle.sh "path/to/ADIF Editor.app"

set -eu

APP="${1:?usage: verify-bundle.sh <path to .app>}"
PLIST="$APP/Contents/Info.plist"

fail() { printf 'error: %s\n' "$1" >&2; exit 1; }
plist() { /usr/libexec/PlistBuddy -c "Print $1" "$PLIST" 2>/dev/null || true; }

[ -d "$APP" ] || fail "no bundle at $APP"
[ -x "$APP/Contents/MacOS/ADIFEditor" ] || fail "the executable is missing or not runnable"
[ -f "$PLIST" ] || fail "Info.plist is missing — the app would open no documents (§12)"

[ "$(plist :CFBundleIdentifier)" = "com.ww8l.adifeditor" ] \
    || fail "bundle identifier is '$(plist :CFBundleIdentifier)', not com.ww8l.adifeditor"
[ "$(plist :CFBundleExecutable)" = "ADIFEditor" ] \
    || fail "CFBundleExecutable does not name the binary that is here"

# The document types, checked by what they have to contain rather than by counting: the
# app must claim its own UTI and plain text, since FT8CN writes ADIF into a .txt
# (decision 13) and that file has to open by double-click like any other.
types="$(plist :CFBundleDocumentTypes)"
case "$types" in
    *com.ww8l.adifeditor.adi*) ;;
    *) fail "Info.plist does not claim the .adi document type" ;;
esac
case "$types" in
    *public.plain-text*) ;;
    *) fail "Info.plist does not claim plain text, so FT8CN's .txt logs would not open" ;;
esac
case "$(plist :UTExportedTypeDeclarations)" in
    *adi*) ;;
    *) fail "the exported UTI declares no filename extension" ;;
esac

[ -s "$APP/Contents/Resources/AppIcon.icns" ] || fail "AppIcon.icns is missing from the bundle"

codesign --verify --strict "$APP" 2>/dev/null || fail "the signature does not verify"

entitlements="$(codesign -d --entitlements - --xml "$APP" 2>/dev/null || true)"
for key in com.apple.security.app-sandbox \
           com.apple.security.files.user-selected.read-write \
           com.apple.security.network.client
do
    case "$entitlements" in
        *"$key"*) ;;
        *) fail "the signature carries no $key — see Support/ADIFEditor.entitlements" ;;
    esac
done

# The one that is a promise rather than a requirement (§6.5): the app listens for
# nothing, and that half of the original no-network rule survived the QRZ amendment
# untouched.
case "$entitlements" in
    *com.apple.security.network.server*)
        fail "the signature carries network.server — §6.5 says the app listens for nothing" ;;
esac

printf 'Bundle verified: %s\n' "$APP"
