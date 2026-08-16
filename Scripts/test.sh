#!/bin/sh
#
# Run the ADIFKit test suite.
#
# Why this script exists: with Command Line Tools and no Xcode.app, SwiftPM does not
# wire up the search paths for Testing.framework, so `swift test` fails to find the
# module at compile time and its dylibs at run time. The framework and its interop
# library are both present — they just need to be pointed at explicitly.
#
# Under a full Xcode install none of that applies: SwiftPM finds the framework itself
# (it lives under the platform directory there, not the CLT path below), and plain
# `swift test` works. So a missing CLT framework directory is not an error — it is the
# signal that we are on a machine that does not need the fixup. CI runs this script on a
# hosted runner with real Xcode, which is the only place that branch is ever taken.
#
# Usage:  Scripts/test.sh [additional swift test arguments]

set -eu

DEVELOPER_DIR="$(xcode-select -p)"
FRAMEWORKS="$DEVELOPER_DIR/Library/Developer/Frameworks"
INTEROP="$DEVELOPER_DIR/Library/Developer/usr/lib"

if [ ! -d "$FRAMEWORKS/Testing.framework" ]; then
    # Full Xcode (or any toolchain that resolves Testing on its own).
    exec swift test "$@"
fi

exec swift test \
    -Xswiftc -F -Xswiftc "$FRAMEWORKS" \
    -Xlinker -F -Xlinker "$FRAMEWORKS" \
    -Xlinker -rpath -Xlinker "$FRAMEWORKS" \
    -Xlinker -rpath -Xlinker "$INTEROP" \
    "$@"
