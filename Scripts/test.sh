#!/bin/sh
#
# Run the ADIFKit test suite.
#
# Why this script exists: with Command Line Tools and no Xcode.app, SwiftPM does not
# wire up the search paths for Testing.framework, so `swift test` fails to find the
# module at compile time and its dylibs at run time. The framework and its interop
# library are both present — they just need to be pointed at explicitly. Under a full
# Xcode install this is all automatic and plain `swift test` works.
#
# Usage:  Scripts/test.sh [additional swift test arguments]

set -eu

CLT="$(xcode-select -p)"
FRAMEWORKS="$CLT/Library/Developer/Frameworks"
INTEROP="$CLT/Library/Developer/usr/lib"

if [ ! -d "$FRAMEWORKS/Testing.framework" ]; then
    echo "error: Testing.framework not found under $FRAMEWORKS" >&2
    echo "       Expected it in the active developer directory ($CLT)." >&2
    exit 1
fi

exec swift test \
    -Xswiftc -F -Xswiftc "$FRAMEWORKS" \
    -Xlinker -F -Xlinker "$FRAMEWORKS" \
    -Xlinker -rpath -Xlinker "$FRAMEWORKS" \
    -Xlinker -rpath -Xlinker "$INTEROP" \
    "$@"
