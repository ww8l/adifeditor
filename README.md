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

It is not a logger, and it never uploads your log anywhere — you upload to POTA
yourself.

It makes exactly one kind of network connection: a QRZ callsign lookup, to fill in
station details you would otherwise type by hand. It happens only when you invoke it,
only if you have entered QRZ credentials, and it sends one callsign — never your log,
never a file. With no credentials stored, the app never opens a connection at all. There
is no telemetry, no update check, and no analytics.

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

`swift build` compiles the code but does not produce a runnable Mac app — see
[Building the app from source](#building-the-app-from-source) below for that.

## Installing

**No release has been published yet.** Until one is, building from source (below) is the
only way to get the app. When releases begin, they will be `.dmg` files on the
[Releases](../../releases) page.

Open the `.dmg` and drag **ADIF Editor** onto the **Applications** shortcut beside it.

### First launch: macOS will block it

It will. This is expected, and it is not a sign that anything is wrong with the download.

ADIF Editor is **ad-hoc signed and not notarized**. Notarizing requires a paid Apple
Developer account, which this project does not have. macOS therefore treats the app as
coming from an unidentified developer and refuses to open it the first time.

You have three ways past it. Pick one.

**1. Open Anyway** (no Terminal required)

1. Double-click ADIF Editor. macOS blocks it — dismiss the warning.
2. Open **System Settings › Privacy & Security**.
3. Scroll to the **Security** section. A message names ADIF Editor as having been
   blocked, with an **Open Anyway** button. Click it.
4. Confirm, and authenticate if asked.

You only do this once. On macOS 14 you can instead control-click the app and choose
**Open**; that shortcut was removed in macOS 15, which is why the route above is the one
documented here.

**2. Remove the quarantine flag** (one command)

```sh
xattr -dr com.apple.quarantine "/Applications/ADIF Editor.app"
```

Then open it normally.

**3. Build it yourself**

If you would rather not run a binary you did not build — a reasonable position, and the
intended answer to the signing question — see below. The app you build locally is not
quarantined, so none of this applies to it.

### Building the app from source

`swift build` alone produces a bare executable, which is not a Mac app: the document type
associations live in `Info.plist`, and Apple Silicon refuses to run an unsigned arm64
binary at all. `Scripts/bundle.sh` assembles the bundle and ad-hoc signs it.

```sh
Scripts/bundle.sh            # debug, your architecture — for development
Scripts/bundle.sh release    # universal arm64 + x86_64, plus the .dmg
```

Both land in `.build/`. Either can be dragged to `/Applications`.

## License

MIT. See [LICENSE](LICENSE).

This is a clean-room implementation written against the public ADIF specification at
[adif.org](https://adif.org). It is not derived from, affiliated with, or endorsed by
any other ADIF editing tool.
