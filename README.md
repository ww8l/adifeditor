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

ADIF Editor makes that one button press — one park or ten, the same command, always
writing new files and never touching the log that came off the radio.

Around that it does the editing a log actually needs:

- **Grid editing.** Every field of every QSO in a spreadsheet, with full undo. Columns
  sort on any header.
- **Row selection and deletion.** Real logs accumulate several sessions; trimming to the
  contacts that were part of the activation is part of preparing the upload. Cut, copy
  and paste move whole QSOs, as ADIF text.
- **Find duplicates.** QSOs that repeat, every one shown before any is removed.
- **Fill from QRZ.** Name, location and zone fields for callsigns you would otherwise
  type by hand. Empty cells only — it never overwrites something you entered.
- **Find (⌘F).** Across every column at once.

And underneath all of it, the guarantee the parser is built around: **a file opened and
saved without edits is byte-identical to the one that came in.** Not merely
field-preserving — identical, down to field-name casing, zero-length fields, line
endings and header bytes. Vendor extensions and fields the app has never heard of
survive untouched, because nothing it does not understand is ever rewritten.

The single exception is a field whose declared length is wrong: that gets written back
correct, and the app tells you it did. Reproducing it faithfully would be preserving
corruption rather than preserving data.

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

Download the latest `.dmg` from the [Releases](../../releases) page. It is a universal
build — Apple Silicon and Intel — and needs macOS 14 or later.

Open the `.dmg` and drag **ADIF Editor** onto the **Applications** shortcut beside it.

Building from source works too and is described [below](#building-the-app-from-source);
the only thing it needs is Swift, since the project has no dependencies.

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

Both land in `.build/`. Either can be dragged to `/Applications`. The app you build
yourself is not quarantined, so none of the first-launch steps above apply to it.

The icon is generated during the bundle step from `Support/Icon/AppIcon-1024.png` using
`sips` and `iconutil`, both of which ship with macOS. There is no committed `.icns`, so
the PNG is the only thing to change if you want a different icon.

If you are working on the project rather than just building it once, enable the pre-push
hook:

```sh
git config core.hooksPath .githooks
```

It runs `Scripts/ci-local.sh` — a build and the full test suite — before every push. This
is the project's primary check. Continuous integration deliberately does not run on
pushes to `main`, so nothing on the server will catch what the hook misses until a release
is built.

## License

GNU General Public License v3.0 or later. See [LICENSE](LICENSE).

In short: you may use, study, modify and share this program freely. If you distribute a
modified version, you have to make your source available under the same terms — so this
stays open for whoever comes after you. And, as with any licence of this kind, the
program comes with **no warranty of any kind**; you use it at your own risk (GPL §§15–17).

Copyright © 2026 Tim Annable.

This is a clean-room implementation written against the public ADIF specification at
[adif.org](https://adif.org). It is not derived from, affiliated with, or endorsed by
any other ADIF editing tool.
