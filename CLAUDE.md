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
Scripts/bundle.sh release       universal arm64 + x86_64, plus the .dmg — what ships
```

`swift build` alone produces a bare executable, which is not a Mac app: the document
types live in `Info.plist`, and Apple Silicon kills an unsigned arm64 binary outright
rather than warning (§12). `Scripts/bundle.sh` assembles the bundle and ad-hoc signs it.

`Scripts/test.sh` rather than plain `swift test`: without Xcode.app, SwiftPM doesn't
wire up the search paths for `Testing.framework`, so the framework needs pointing at
explicitly. The script does that and is a no-op difference under a full Xcode install.

## Where things stand

*Last updated 2026-08-15.*

**M1 is complete and the owner has used it.** The QRZ lookup (§10.4) landed after it,
on the owner's request, and is the reason this app can now reach the network at all.
**The live QRZ lookup has now run against the real service, on the owner's subscription,
and worked** (2026-08-15) — the fake-transport-only caveat that stood here is retired.
Find (⌘F) followed. 183 tests, all green and all mutation-checked rather than merely
observed passing.

```
Sources/ADIFKit/   ADIFField, ADIFRecord, ADIFDocument, ADIFScanner, ADIFParser,
                   ADIFWriter, ADIFEditing (what an edit means), ADIFDuplicates,
                   ADIFFind (matching and wrapping)
Sources/POTAKit/   ParkReference, POTAStamp, POTAFilename
Sources/QRZKit/    QRZTransport (the seam), QRZSession, QRZCallsign, QRZResponseParser,
                   QRZFieldMapping, QRZLookup, QRZBatch, QRZError
Sources/ADIFEditor/ main, AppDelegate, MainMenu,
                   Model/{LogDocument, Preferences, Keychain},
                   UI/{LogWindowController, GridViewController, GridClipboard,
                   POTACommands, DedupeCommand, QRZCommand, QRZProgressSheet,
                   PreferencesWindowController, SheetLayout, ParseWarningText,
                   FindBar}
Support/           Info.plist, ADIFEditor.entitlements
Scripts/           test.sh (the suite), bundle.sh (builds and signs ADIF Editor.app)
Tests/             ADIFKitTests (round trip, parser, editing, duplicates, find),
                   POTAKitTests, QRZKitTests (responses, session, lookup, batch)
fixtures/real/     FT8CN6469053684847039306.txt — the owner's log, 66 QSOs, unmodified
fixtures/synthetic/ 24 hand-built cases; see fixtures/README.md for what each one tests
```

The app opens a log, edits cells, sorts on any header, selects/cuts/copies/pastes/deletes
rows, stamps POTA references into new files, finds duplicates, finds text (⌘F), and fills
station details from QRZ. A titlebar banner reports anything the parser had to recover
from. All of it verified running against the owner's real log, not just compiled — the
live QRZ request included, as of 2026-08-15.

**Nothing in the app ever writes to the file that was opened** except Save. The POTA
commands write new files only (decision 15), autosave-in-place is off and must stay off,
and every other change is an undoable in-memory edit.

**Where the layers sit, and why.** ADIFKit owns the format *and* what an edit means to
the data — clearing a cell removing a field, where a re-added field goes, sort order,
duplicate matching. Those look like UI questions and are not: get them wrong and a saved
file quietly differs from the one opened, so they live where §11's suite can reach them.
The app layer is left with undo, dirty state, redisplay and panels, which §11 exempts
from tests. Follow that split for anything new.

QRZKit follows the same split for the same reason, and the reason is now sharper: with
the OS no longer enforcing §6.5, everything above `QRZTransport` is a pure function of
already-fetched data so that "fills empty cells, never overwrites" is provable without a
socket. Nothing in `Tests/QRZKitTests` opens a connection, and nothing there references
`URLSessionTransport`. Keep it that way.

**Beyond the spec, then folded in:** dedupe (toolbar and Edit ▸ Find Duplicates) is still
not in DESIGN.md — the owner asked for it after using M1. Closest to §10.3's validation
panel in spirit, but it deletes rather than advises, so it shows every row before removing
any. The QRZ lookup *was* written into DESIGN.md as §10.4 when it was built.

Still not built, deliberately: no CI workflow (§12's GitHub Actions pipeline is M4), no
app icon, no replace, no save-selection-as-new-file (M2/M3). **Column filters are not
coming** — see decision 18.

**Things learned the hard way, worth not relearning:**

- **`setFrameUsingName` returning `true` means it found a saved frame, not that it applied
  one.** A frame saved against a display that later changes size is declined, and the
  window falls back to its content view's size — which for an `NSScrollView` is nothing,
  so it clamps to `minSize`. The autosave then writes the clamped frame back and it
  compounds every launch. `LogWindowController` now judges the restore by its result.
- **AppKit re-derives a window's size from its content view controller on the first
  layout pass**, after `init` and before `showWindow`, not only when the controller is
  assigned. `GridViewController.preferredWindowContentSize` gives it a real answer and the
  frame is re-asserted once in `showWindow`.
- **The Keychain works under sandbox + ad-hoc signing**, but only inside a bundle — a bare
  signed executable with the sandbox entitlement is killed at launch. Test Keychain
  changes with a real `.app`, not a command-line binary.
- **`log` is shadowed in this zsh.** Use `/usr/bin/log` for unified-logging queries. The
  sandbox also blocks `/tmp`, so an app-side debug sink has to write into the container.
- **SwiftPM's `--arch arm64 --arch x86_64` needs Xcode and cannot work here.** It shells
  out to `xcbuild`, which lives inside Xcode.app; under CLT it fails with "xcbuild
  executable ... does not exist". §5's universal requirement and decision 9's no-Xcode
  ruling were quietly incompatible from M1 until this was found on 2026-08-15 — the
  release path had been written, documented as "what ships", and never once run. Two
  `--triple` builds joined with `lipo` get there instead; cross-compiling to x86_64 is
  fine under CLT. Sign *after* lipo, never before: joining two signed slices invalidates
  both signatures.
- **A whole documented command can be dead.** The lesson generalises past this one bug: if
  a script path has never been executed, it does not work until proven otherwise, however
  carefully it was written.

**Open items:**

- **The repo is local only, and going public later.** No remote, nothing pushed. `gh` is
  authenticated as `ww8l`. The owner ruled on 2026-08-15: **public, but not yet.** Timing
  is his; do not create the remote or push without being asked.

  Two things follow from "later, but public". First, **history is published too** — a
  credential committed today is still in the log after it is deleted tomorrow, and
  rewriting history is far worse than never committing it. The history was scanned on
  2026-08-15 and is clean: every `password`/`sessionKey` hit is a parameter name, and the
  one key-shaped hex string in `QRZFakes.swift` is invented, not captured. Re-check before
  pushing, especially if the QRZ fixtures have been replaced with real captures by then.

  Second, the FT8CN fixture is fine to publish. It holds callsigns, four-character grid
  squares, dates, signal reports and FT8CN's own distance comments — no names, addresses
  or emails, and all of it is already public through LoTW, PSK Reporter and POTA spots.
- **The QRZ fixtures are still synthetic**, even though the live path now works. The canned
  XML is built from QRZ's published format, not captured from the service, so any drift
  between their documentation and their behaviour remains invisible to the suite. The
  lookup running successfully once says the happy path is right; it says nothing about the
  error and edge responses. Capture real ones next time a lookup is being made, and scrub
  the session key before committing them.
- **`fixtures/real/` holds one file.** §11 names WSJT-X, MSHV, and N1MM; none are in
  hand, so the synthetic hostile cases are educated guesses at what those programs do
  wrong. Adding real ones is the cheapest coverage available.
- **DESIGN.md is amended but still behind.** §6.5, §10.4, §3, §5, §7, §11, §13 and §14
  were brought up to date when QRZ landed. The eighteen decisions below still live only
  in this file, and five of them (2, 14, 15, 16, 18) contradict what §9, §10.1 and §10.2
  say in plain words — a reader of DESIGN.md alone would build the wrong app, and decision
  18 now means they would build a whole feature that was rejected. It also does not mention
  dedupe or find. The owner has been offered a fold-in three times and hasn't said yes.

**Where to pick up (paused 2026-08-15).** Working tree clean, everything committed,
nothing pushed. The build is current and `.build/ADIF Editor.app` is signed with the
network entitlement.

Nothing is waiting on the owner. The live QRZ lookup was made and worked, and ⌘F find
landed after it and he has used it.

The open build choices: what remains of M2 (save selection as a new file — column filters
are dropped, decision 18), M3's replace, the DESIGN.md fold-in, or the repo's
public/private question.

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

**6.5 — One network destination, chosen by the user, or none.** *(Amended 2026-08-14,
owner's ruling. Weakens the principle — the only amendment so far that does. Was: "No
network. Not 'no network by default.' No network.")*

One outbound connection is permitted: a QRZ callsign lookup, on a subscription the user
pays for, with credentials the user enters (§10.4). In its place:

- **No server entitlement**, ever. `com.apple.security.network.client` is the whole of
  the concession.
- **Offline is the resting state.** No credentials means no connections. Every feature
  but the lookup works with the network off, with nothing blocking or retrying.
- **No log data leaves the machine.** One callsign goes out. Not QSOs, not files.
- **No connection the user did not ask for.** No telemetry, update check, prefetch, or
  background refresh.
- **Credentials in the Keychain only** — never a plist, never the repo, never a log.

What made this rule strong was that the OS enforced it. That is gone and cannot come
back while the client entitlement is present; this list and §11's tests are what remain.

## Non-goals (DESIGN.md §3) — do not build, do not leave hooks for

- **Any format other than ADI.** No ADX, Cabrillo, TR, CT, eQSL, CSV, or JSON import
  or export. One format in, one format out.
- **Logging.** This is not a logger. It edits files produced by loggers. No radio
  control, no clock, no QSO entry form, no persistent logbook. Callsign lookup is the
  one exception (§10.4, added 2026-08-14).
- **Uploading.** The app never transmits log data. The user uploads to POTA themselves.
- **Telemetry, analytics, crash reporting, update checks.** The app phones home for
  nothing. The only traffic it ever originates is a lookup the user invoked by name.
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

15. **Stamping writes a new file, exactly like the split.** §10.2 had a single park
    stamped into the open document in memory, with only a multi-park split writing files.
    The owner asked for one workflow after using both: a stamp exists to produce the file
    to upload under POTA's name for it, and writing a new file means the log that came off
    the radio is never touched at all (§6.1) rather than merely not-yet-saved. One park and
    ten now take the identical path — destination, proposed names, write. §10.2 is amended.

16. **One POTA button, not two.** With decision 15 making stamp and split one code path,
    the two toolbar buttons behaved identically and differed only in how many references
    the operator happened to type. The Split button and menu item are gone; the remaining
    button is labelled "POTA". The park count already says which operation was meant, so
    it is not a choice worth putting in front of the operator. §10.2's "two commands" is
    amended to one.

17. **QRZ lookup, and §6.5 struck.** *(2026-08-14, separate from the sixteen above —
    those were approved together.)* The owner asked for a QRZ XML lookup to fill station
    details he would otherwise type by hand. Granted; §6.5 amended above and §10.4 added
    to DESIGN.md. Unlike every other decision here, this one *removes* a guarantee
    rather than sharpening one: the network entitlement means the OS no longer enforces
    anything about connections, and that protection cannot be recovered while the
    entitlement is present. It was raised as a one-way door and the owner ruled with
    that in front of him. The conditions in §6.5's replacement list are not negotiable
    individually — collectively they are what was traded for it. Anything wanting a
    *second* network destination is a new decision needing the same conversation, not an
    extension of this one.

18. **Find, not filters. §10.1's column filters are dropped.** *(2026-08-15, owner's
    ruling.)* A filter bar was built first — per-column conditions, a value picker, tokens
    for active terms, and the row-to-record mapping that hiding rows forces on every
    operation in the app. The owner's verdict on seeing it: *"I don't need all that
    filtering, you're making it more complex than I asked."* He asked for ⌘F instead. All
    of it was deleted; `ADIFFind` is about seventy lines and hides nothing.

    What this gives up is real and should not be discovered at a Field Day. §10.1 names
    filtering as the primitive behind "filter on `OPERATOR`, select the rows that aren't
    yours, delete them", and find cannot do that — it moves the selection to one row at a
    time, so there is nothing to ⌘A and delete. If that workflow ever actually comes up,
    the answer is *not* to rebuild the filter bar: sort on `OPERATOR`, which the grid
    already does, and the rows that aren't yours are contiguous and selectable in one
    drag. That is decision 12's stance applied to the case decision 12 was written for.

    The general lesson, which is the more useful half: the spec asking for a feature is not
    a reason to build the largest version of it. §10.1 said "filter on any column by value"
    and got a multi-column conjunctive query builder. Build the small thing, show it, and
    let him ask for more.

## Identity

- Bundle identifier: `com.ww8l.adifeditor`
- Copyright: Tim Annable, 2026, MIT
- The app name "ADIF Editor" is intentionally generic (§4).
