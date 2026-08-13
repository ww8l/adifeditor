# ADIF Editor

A native macOS editor for amateur radio ADIF log files, with purpose-built tools for
Parks on the Air (POTA) activation logs.

**Status: pre-release, under construction.** See [DESIGN.md](DESIGN.md) for the full
specification and [CLAUDE.md](CLAUDE.md) for the invariants the implementation is held
to.

## What it's for

POTA activators log with contest and digital-mode software — WSJT-X, MSHV, N1MM — none
of which know anything about POTA. The `.adi` files they produce are valid ADIF but
lack the `MY_SIG_INFO` field carrying the park reference, which POTA's uploader needs.
Every activation therefore requires the same manual edit: add a column, fill it with
the park reference on every row, save under a specific filename. Activations from
multiple parks at once ("n-fers") require that once per park, into separate files.

ADIF Editor makes that two button presses. It also does the general grid editing a log
sometimes needs — deleting the contacts that weren't part of the activation, fixing a
mistyped callsign — without damaging anything else in the file.

It is not a logger. It does not upload. It makes no network connections of any kind.

## Requirements

macOS 14 or later. Universal (Apple Silicon and Intel).

## Building

Requires the Swift toolchain from Xcode or the Command Line Tools. No third-party
dependencies.

```sh
swift build
Scripts/test.sh     # ADIFKit unit tests, including round-trip fidelity
```

Tests use swift-testing. `Scripts/test.sh` wraps `swift test` with the search paths
`Testing.framework` needs when building against Command Line Tools without a full
Xcode install; with Xcode present, plain `swift test` also works.

## Installing

*(To be written — see DESIGN.md §12. The app is ad-hoc signed and not notarized, so
Gatekeeper will block it on first launch and the README will need to document the
"Open Anyway" path through System Settings › Privacy & Security, along with the
`xattr -dr com.apple.quarantine` alternative. Users who would rather not run an
unsigned binary can build it themselves — that is the intended answer.)*

## License

MIT. See [LICENSE](LICENSE).

This is a clean-room implementation written against the public ADIF specification at
[adif.org](https://adif.org). It is not derived from, affiliated with, or endorsed by
any other ADIF editing tool.
