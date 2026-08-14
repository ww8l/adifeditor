# ADIF Editor — working context

A native macOS ADIF log editor for amateur radio, with POTA-specific tools.
`DESIGN.md` is the specification and the authority. This file exists so the
non-negotiable parts stay in context across sessions.

## Build

No Xcode on this machine — Command Line Tools only. That is a deliberate choice, not
a gap to fix (see "Decisions taken" below).

```
swift build                     compile
Scripts/test.sh                 run the suite
Scripts/bundle.sh               build .build/ADIF Editor.app and launch it from there
Scripts/bundle.sh release       universal arm64 + x86_64, what ships
```

`swift build` alone produces a bare executable, which is not a Mac app: the document
types live in `Info.plist`, and Apple Silicon kills an unsigned arm64 binary outright
rather than warning (§12). `Scripts/bundle.sh` assembles the bundle and ad-hoc signs it.

`Scripts/test.sh` rather than plain `swift test`: without Xcode.app, SwiftPM doesn't
wire up the search paths for `Testing.framework`, so the framework needs pointing at
explicitly. The script does that and is a no-op difference under a full Xcode install.

## Where things stand

*Last updated 2026-08-13.*

**ADIFKit is done and the §11 gate is met.** 33 tests over 25 fixtures, all green:
byte-identity on the 19 unedited well-formed files, parse-stability and writer
idempotence on all 24 that open, a required warning on each of the 6 irregular ones,
and invalid UTF-8 refused with a byte offset. The suite was mutation-checked, not just
observed green — uppercasing field names on write fails 4 assertions, dropping
empty-valued fields fails 13.

Built so far:

```
Sources/ADIFKit/   ADIFField, ADIFRecord, ADIFDocument, ADIFScanner, ADIFParser, ADIFWriter
Sources/ADIFEditor/ main, AppDelegate, MainMenu, Model/LogDocument,
                   UI/LogWindowController, UI/GridViewController, UI/ParseWarningText
Support/           Info.plist, ADIFEditor.entitlements
Scripts/           test.sh (the suite), bundle.sh (builds ADIF Editor.app)
Tests/ADIFKitTests/ RoundTripTests (the §11 gate), ParserTests (semantics), Fixtures
fixtures/real/     FT8CN6469053684847039306.txt — the owner's log, 66 QSOs, unmodified
fixtures/synthetic/ 24 hand-built cases; see fixtures/README.md for what each one tests
```

**The app opens and displays a log, read-only.** `Scripts/bundle.sh` builds, bundles and
ad-hoc signs `.build/ADIF Editor.app`; it opens the FT8CN fixture and shows 66 QSOs in an
`NSTableView`, one column per field name, with a titlebar banner when the parser
recovered from something. Verified running against the real log, not just compiled.

**Next, in order: cell editing, header sort, save, row select/delete** (decision 11),
then POTA stamp and split. That completes M1 — stop there and let the owner use it
before touching M2.

Each of the remaining pieces needs an undo story, which is why the grid is read-only
now rather than half-editable: `NSDocument` supplies `NSUndoManager`, and every mutation
has to register with it or Save silently disagrees with what is on screen.

Still not built, deliberately: no CI workflow (§12's GitHub Actions pipeline is M4), no
app icon, no preferences.

**Open items:**

- **The repo is local only.** No remote, nothing pushed. `gh` is authenticated as
  `ww8l`. The owner was asked whether to create `adif-editor` public or private and
  hasn't decided; do not push without an answer. Public means the FT8CN fixture's real
  callsigns go public, which §11 sanctions but is his call.
- **`fixtures/real/` holds one file.** §11 names WSJT-X, MSHV, and N1MM; none are in
  hand, so the synthetic hostile cases are educated guesses at what those programs do
  wrong. Adding real ones is the cheapest coverage available.
- **DESIGN.md has not been amended.** The thirteen decisions below still live only in
  this file, so the spec and the code disagree on paper. The owner was offered a fold-in
  and hasn't said yes.

## Core principles (DESIGN.md §6) — invariants

If an implementation decision conflicts with one of these, **the principle wins and
the decision changes**. Stop and raise it rather than working around it.

**6.1 — Never modify the source file.** Every operation that produces output writes a
new file. The original the user opened is not touched unless they explicitly invoke
Save on it. The POTA split always writes new files.

**6.2 — Lossless round-trip.** A file parsed and written back without edits must
preserve every field it contained, including `APP_*` vendor fields, `USERDEF` fields,
fields not in the ADIF spec, and header content. The app must never silently drop data
it does not understand.

**6.2a — If the user didn't edit it, don't change it.** *(Amended 2026-08-13, owner's
ruling. Stronger than §6.2 as originally written; supersedes parts of §8 and §9 — see
"Decisions taken".)* An unedited file written back out is **byte-identical** to what
came in. Not merely field-preserving — identical. This covers zero-length fields,
field-name casing, type indicators, per-record field order, header bytes, BOM, and
line endings.

The sole exception is the specific site of a recovered parse error: a wrong `LENGTH`
value is written back correct, because reproducing it would be preserving corruption
rather than preserving data. Every such case records a warning.

**6.3 — Additive, never destructive.** The app creates columns and fills empty cells.
It does not overwrite existing values in bulk. If a field already has a value, an
automated tool leaves it alone. Corrections are made by the user, by hand, in the grid.

The n-fer split is the one permitted collision: deriving per-park files necessarily
writes a different `MY_SIG_INFO` into each. Permitted because the outputs are new
derived files and the source is untouched (6.1) — but never silent. If the column
already holds values, prompt: *"N rows already have park references. Replace them in
the split output?"* Fill empty cells without comment.

**6.4 — Never crash, never corrupt.** The app will meet ADIF from loggers neither the
author nor the spec anticipated, hand-edited files, and truncated downloads. A
malformed file produces a clear diagnostic naming the problem and the byte or line
offset. It does not produce a stack trace, and it does not produce a silently mangled
log.

**6.5 — No network.** Not "no network by default." No network. The sandbox
entitlements must not include any network client or server capability.

## Non-goals (DESIGN.md §3) — do not build, do not leave hooks for

- **Any format other than ADI.** No ADX, Cabrillo, TR, CT, eQSL, CSV, or JSON import
  or export. One format in, one format out.
- **Logging.** This is not a logger. It edits files produced by loggers. No radio
  control, no callsign lookup, no clock, no QSO entry form, no persistent logbook.
- **Uploading.** No network access whatsoever. The user uploads to POTA themselves.
- **Telemetry, analytics, crash reporting, update checks.** The app makes no network
  connections of any kind. It should be possible to run it with the network off and
  notice nothing.
- **SOTA, WWFF, IOTA, or contest-specific features.** POTA only, for now.

Also out of scope by §4: nothing may be derived from ADIF Master's binary, source,
icons, or branding, and nothing may be named to suggest affiliation with it.

## Working agreements

- **Tests before UI, always.** Parser correctness is the whole ballgame. No UI code
  until the §11 round-trip tests pass against every file in `fixtures/`.
- **Ask before deviating from the spec.** If the spec is wrong, say so and change the
  spec — don't silently build something different from what it says.
- **Small commits with clear messages.**
- **Stop at each milestone** and let the owner actually use it before moving on.

## Decisions taken (amendments to DESIGN.md, owner-approved 2026-08-13)

1. **Byte-identity replaces "canonical form."** §11's "byte-identical for files
   already in canonical form" was untestable — canonical form was never defined. The
   test is now: parse → write → compare bytes → expect equality, for every well-formed
   fixture, no special category. Malformed fixtures get parse-equality plus an asserted
   warning instead.

2. **Zero-length fields are preserved.** §9's "writing a record omits fields whose
   value is empty" contradicted §11's bar ("loses no field present in the input").
   `<COMMENT:0>` in, `<COMMENT:0>` out. A cell the *user* clears in the grid is
   genuinely removed — that is an edit. §9 is amended.

3. **Field-name casing preservation is mandatory,** not "if cheap" (§8). Store the
   literal spelling per field occurrence; key lookups on the uppercased form.

4. **BOM, line endings, and missing headers are preserved, not normalized.** §8 said
   strip the BOM and "write a minimal one" when no header is present. Both are changes
   to a file the user didn't edit, so both reverse under 6.2a. A headerless file stays
   headerless; a CRLF file stays CRLF. Headers are synthesized only for files this app
   creates from scratch, such as split outputs. §8 is amended.

5. **Resync algorithm is stronger than §8 describes.** §8's rule ("read LENGTH
   characters, verify the next non-whitespace character is `<`") discards correctly
   parsed fields on files with legal inter-field text, and mis-resyncs on the very
   byte-vs-character case it was written to solve. Actual order: read LENGTH as
   characters and accept if only whitespace precedes the next `<`; else re-read LENGTH
   as UTF-8 bytes and re-check, warning `lengthInterpretedAsBytes`; else treat the run
   as ignorable inter-field text if the next `<` opens a well-formed tag, warning
   `unexpectedTextBetweenFields`; else scan forward, warning `resynchronized(offset:)`.
   Never discards a field it successfully read.

6. **Invalid UTF-8 is fatal, loudly.** Strict decode; on failure refuse to open and
   report the byte offset of the first invalid sequence. Lossy decoding would violate
   6.2a. This is the only fatal parse error.

7. **A truncated final record is kept,** with a warning. Discarding it would lose data.

8. **Values containing literal newlines are written literally.** §8's "one QSO per
   line" cannot hold for `NOTES`/`COMMENT`/`ADDRESS` fields containing newlines, and
   escaping them would be destructive. The rule is one QSO per line *except* where a
   value itself contains a newline.

9. **No Xcode; SwiftPM plus a bundle script.** CLT ships the macOS SDK including
   AppKit, so the app can be compiled, bundled, `Info.plist`-configured, entitled, and
   ad-hoc signed from the terminal. A hand-written `.pbxproj` was rejected because it
   could not be compiled or verified on this machine. Revisit at M2, where §14 asks for
   an Instruments measurement of `NSTableView` with 100k QSOs. ADIFKit is a SwiftPM
   package either way, so nothing moves if Xcode arrives later.

10. **swift-testing, not XCTest** — forced, not preferred. XCTest ships with Xcode.app
    and is genuinely absent from Command Line Tools (only a private `XCTestSupport.tbd`
    stub is present). `Testing.framework` *is* in CLT. Given decision 9, swift-testing
    is the only framework that runs here. Reversed from an earlier XCTest decision after
    the skeleton failed to build.

11. **M1 includes sort, row selection, and delete rows** (pulled forward from M2). Real
    logs accumulate multiple sessions — the owner's FT8CN fixture holds 66 QSOs across
    nine dates — so trimming rows is part of prepping an activation log, not a later
    nicety. §13's M1 is amended.

12. **Don't infer intent from data. Give the operator manual control.** The output
    filename date stays exactly as §10.2 says — earliest `QSO_DATE`, no inference, no
    disambiguation prompt — because the user trims the rows first. More generally:
    before building smart handling for a messy-data case, check whether a sort and a
    delete already solve it. The only automatic data changes in the whole app are the
    POTA `MY_SIG_INFO` fill and the output filenames. Everything else the user edits by
    hand. (Same stance the spec already takes on lenient park-reference validation.)

13. **File extensions are not authoritative.** FT8CN writes ADIF content to `.txt`. The
    app judges by content and opens what it's given; fixtures keep their original names.

14. **Column order is merged from every record, not taken from the first.** §9's "fields
    in the order first encountered" makes the grid's whole layout hostage to record 1:
    clear one cell there and that field is not encountered until record 2, behind
    everything record 1 carries, so the column jumps to the far right. Found by the owner
    within minutes of cell editing existing. The rule is now that a field takes the place
    it holds in the first record that carries it — inserted after whichever known field
    precedes it there — and columns already placed never move. Relatedly, a field added
    back to a record is *inserted* where the other records keep it rather than appended,
    since appending to record 1 relocates the column by the same mechanism. §9 is amended.

## Identity

- Bundle identifier: `com.ww8l.adifeditor`
- Copyright: Tim Annable, 2026, MIT
- The app name "ADIF Editor" is intentionally generic (§4).
