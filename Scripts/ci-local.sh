#!/bin/sh
#
# Local equivalent of .github/workflows/ci.yml. Wired to the pre-push hook so breakage is
# caught before it costs Actions minutes.
#
# Keep the step list below in sync with ci.yml.
#
# The bundle is built too, but into a temporary directory rather than over
# .build/ADIF Editor.app, which is routinely open and in use on this machine — a pre-push
# hook is no place to yank an app out from under someone. That objection was why the step
# was skipped entirely, which left Info.plist, the entitlements and the signature with no
# local coverage at all: `swift build` is happy with any of them broken, and the only
# automated check was a workflow that has never run.
#
# One of ci.yml's steps is still deliberately absent: the release build, which needs the
# full Xcode the hosted runner has and this machine does not (decision 9).
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

step "Scripts/bundle.sh + verify-bundle.sh"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT INT TERM
BUNDLE_DEST="$SCRATCH/ADIF Editor.app" Scripts/bundle.sh
Scripts/verify-bundle.sh "$SCRATCH/ADIF Editor.app"

printf '\n\033[1;32m==> Local CI passed\033[0m (%ss)\n' "$(( $(date +%s) - start ))"
