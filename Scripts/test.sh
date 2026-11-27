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

# The compiler plugin behind #expect and @Test. CLT for Swift 6.4 (installed 2026-11-23)
# ships it in a `testing/` subdirectory that SwiftPM does not search, and every test
# target then fails to compile with "plugin for module 'TestingMacros' not found". The
# failure is easy to misread: `swift test` still runs the test binaries an earlier build
# left behind, so the log is full of passing tests while the exit status is 1. The CLT
# this script was written against found the plugin unaided, so the flag is added only
# when the directory exists.
PLUGINS="$DEVELOPER_DIR/usr/lib/swift/host/plugins/testing"
if [ -d "$PLUGINS" ]; then
    set -- -Xswiftc -plugin-path -Xswiftc "$PLUGINS" "$@"
fi

exec swift test \
    -Xswiftc -F -Xswiftc "$FRAMEWORKS" \
    -Xlinker -F -Xlinker "$FRAMEWORKS" \
    -Xlinker -rpath -Xlinker "$FRAMEWORKS" \
    -Xlinker -rpath -Xlinker "$INTEROP" \
    "$@"
