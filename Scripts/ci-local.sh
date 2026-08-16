#!/bin/sh
#
# Local equivalent of .github/workflows/ci.yml. Wired to the pre-push hook so breakage is
# caught before it costs Actions minutes.
#
# Keep the step list below in sync with ci.yml.
#
# Two of ci.yml's steps are deliberately absent:
#
#   * The bundle. `Scripts/bundle.sh` starts by `rm -rf`-ing .build/ADIF Editor.app, and
#     that bundle is routinely open and in use on this machine. A pre-push hook is no
#     place to yank an app out from under someone. CI bundles on a runner where nothing
#     is running.
#   * The release build, which needs the full Xcode the hosted runner has and this
#     machine does not (decision 9).
#
# So passing here is not a promise that CI passes — it only means the obvious breakage is
# already caught. That asymmetry is the point: this is the cheap gate, CI is the real one.
#
# Usage: Scripts/ci-local.sh

set -eu

cd "$(dirname "$0")/.."

step() { printf '\n\033[1;34m==>\033[0m \033[1m%s\033[0m\n' "$1"; }

start=$(date +%s)

step "swift build"
swift build

step "Scripts/test.sh"
Scripts/test.sh

printf '\n\033[1;32m==> Local CI passed\033[0m (%ss)\n' "$(( $(date +%s) - start ))"
