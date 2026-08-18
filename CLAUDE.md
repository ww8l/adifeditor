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
Scripts/ci-local.sh             build + test, what the pre-push hook runs
Scripts/bundle.sh               build .build/ADIF Editor.app and launch it from there
Scripts/bundle.sh release       universal arm64 + x86_64, plus the .dmg — what ships
MARKETING_VERSION=26.8.16 Scripts/bundle.sh release    stamp a version (CI sets this)
```

`swift build` alone produces a bare executable, which is not a Mac app: the document
types live in `Info.plist`, and Apple Silicon kills an unsigned arm64 binary outright
rather than warning (§12). `Scripts/bundle.sh` assembles the bundle, generates the
`.icns` from `Support/Icon/AppIcon-1024.png`, and ad-hoc signs it.

`Scripts/test.sh` rather than plain `swift test`: without Xcode.app, SwiftPM doesn't
wire up the search paths for `Testing.framework`, so the framework needs pointing at
explicitly. Under a full Xcode install — which is what the CI runner has — the framework
lives elsewhere and SwiftPM finds it unaided, so the script falls through to plain
`swift test`. That fallback is not hypothetical tidiness: as originally written the
script treated the missing directory as fatal and would have failed the first CI run on
its first step.

A pre-push hook runs `Scripts/ci-local.sh` on every push. It is enabled per-clone and is
already set here; a fresh clone needs `git config core.hooksPath .githooks`.

## Where things stand

*Last updated 2026-08-18.*

**M1 is complete, the owner has used it, and it has now shipped.** The QRZ lookup (§10.4)
landed after M1, on the owner's request, and is the reason this app can reach the network
at all. **The live QRZ lookup has run against the real service, on the owner's
subscription, and worked** (2026-08-15) — the fake-transport-only caveat that stood here
is retired. Find (⌘F) followed. 237 tests, all green and all mutation-checked rather than
merely observed passing.

**`v26.8.16` is built, verified and sitting as a draft release** (2026-08-16). Universal,
icon, signed, 879K `.dmg`, produced by GitHub Actions rather than by hand. It was
downloaded, mounted and inspected — not merely reported green by the runner.

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
Support/           Info.plist, ADIFEditor.entitlements,
                   Icon/{AppIcon-1024.png (the source of truth), AppIcon.svg,
                   build_icon.py (provenance, not a build step)}
Scripts/           test.sh (the suite), ci-local.sh (the pre-push gate),
                   bundle.sh (builds, icons and signs ADIF Editor.app)
.github/workflows/ ci.yml (dormant — PR and manual only), release.yml (tags and manual)
.githooks/         pre-push — runs ci-local.sh, skips tags and branch deletions
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

§12's GitHub Actions pipeline and the app icon — both M4 — landed on 2026-08-16. Still not
built: no replace, no save-selection-as-new-file (M2/M3). **Column filters are not
coming** — see decision 18.

**The icon** is the owner's design, authored in Claude Desktop and handed over as an SVG,
a 1024 PNG and the generator that produced them. A navy superellipse holding a cream log
card, three rows of ADIF's own `<field>` syntax as chevrons and bars, one row picked out
in amber. Two things about it are load-bearing and easy to break. Its body occupies 80% of
the canvas — measured 820/1024 with even 102px margins, against Apple's 824/1024 grid —
and that padding is *baked into the art* because macOS, unlike iOS, does not mask app
icons: what is in the PNG is what lands in the Dock. And the `.icns` is generated by
`bundle.sh` rather than committed, so the PNG stays the single source of truth. `sips` and
`iconutil` are both in `/usr/bin` rather than inside Xcode.app, so this holds under
decision 9 and runs headless on a runner. Verified through `NSWorkspace` on the built
bundle: macOS resolves 32 representations and applies its own Dock shadow, which is what
it does for a real app icon rather than a generic fallback.

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
  carefully it was written. **This bit a third time on 2026-08-16**: `Scripts/test.sh`
  claimed in its own comment to be "a no-op difference under a full Xcode install" and in
  fact exited with an error there, because the CLT framework directory it probes does not
  exist under Xcode. Nobody had ever run it on such a machine. It would have failed the
  first CI run on its first step. Assume the same of anything else here whose only
  evidence is that it reads correctly.
- **Actions bills in quota-minutes, and the multiplier is the whole story.** Wall clock
  times a runner multiplier: Linux 1x, Windows 2x, **macOS 10x**. Private repos get
  2,000/month; public repos are unmetered on every platform, which is why going public
  makes this entire concern evaporate. Local runs cost nothing ever — GitHub bills for its
  own rented machines, not yours.
- **The default job timeout is 6 hours, which at 10x is 3,600 quota-minutes** — nearly
  double the monthly allowance, from a single run that hangs and never finishes. Every job
  here carries `timeout-minutes`. It is the highest-value line in either workflow and it
  has nothing to do with how long the work actually takes.
- **Estimates of CI cost were three times too pessimistic.** The real numbers, measured:
  a full universal build with `.dmg` takes ~71s locally and ~90s on a runner, so a release
  costs ~15 quota-minutes, not the ~55 that was assumed while designing around it. Having
  zero dependencies is why. Design for the multiplier, but measure before treating the
  budget as tight.
- **A YAML parser validating a workflow proves nothing about Actions.** It proves the file
  is well-formed YAML. The `${{ }}` expressions, `github.ref_type`, and step outputs are
  only checked by GitHub's runner. Prove a workflow with `workflow_dispatch` before the
  first tag; a workflow debugged by pushing tags costs a billed run and a spent version
  number per mistake.
- **`right-click → Open` no longer bypasses Gatekeeper.** Apple removed it in macOS 15 for
  apps Gatekeeper blocks; the route is System Settings › Privacy & Security › **Open
  Anyway**. README.md already had this right; the release notes did not, having been
  copied from an older project of the author's whose README was never corrected. Text
  reused from elsewhere carries that elsewhere's stale facts with it.

**Open items:**

- **The repo is on GitHub, private, and going public later.**
  `https://github.com/ww8l/adifeditor`, created 2026-08-16, `main` tracking `origin/main`,
  everything pushed. The flip to public is the owner's call and his timing; don't run
  `gh repo edit --visibility public` without being asked. See `CLAUDE.local.md` for what
  is still outstanding on it.

  Private does not restrict anything about building or releasing. A draft release and its
  `.dmg` are downloadable by the owner either way. Private bites only when handing the
  `.dmg` to someone else.

  **The history scan is the gate on that flip, and it has not been re-run since
  2026-08-15.** Private means a leaked credential is still recoverable by rewriting
  history; public means it is not. So the scan is owed *before* the visibility change, not
  before the push. Two things follow. First, **history is published too** — a
  credential committed today is still in the log after it is deleted tomorrow, and
  rewriting history is far worse than never committing it. The history was scanned on
  2026-08-15 and is clean: every `password`/`sessionKey` hit is a parameter name, and the
  one key-shaped hex string in `QRZFakes.swift` is invented, not captured. Re-check before
  going public, especially if the QRZ fixtures have been replaced with real captures by
  then.

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
- **Both workflows have now been proven by running.** `release.yml` twice, and `ci.yml`
  once by dispatch on 2026-08-18 — green first time, 1m13s, ~12 quota-minutes. `ci.yml`
  still fires only on `pull_request` and `workflow_dispatch`, which is deliberate
  (decision 19): the pre-push hook is the routine gate. Its value is what that run
  confirmed — the runner carries Xcode 26.6 and Swift 6.3.3 against this machine's CLT, so
  it exercises `Scripts/test.sh`'s Xcode fallback, the branch that was silently broken
  until 2026-08-16.
- **DESIGN.md is amended but still behind.** §6.5, §10.4, §3, §5, §7, §11, §13 and §14
  were brought up to date when QRZ landed; §12 was amended on 2026-08-15 for the `.dmg`
  and the xcbuild collision, and describes a pipeline whose triggers decision 19 has since
  narrowed. The nineteen decisions below still live only in this file,
  and five of them (2, 14, 15, 16, 18) contradict what §9, §10.1 and §10.2 say in plain
  words — a reader of DESIGN.md alone would build the wrong app, and decision 18 now means
  they would build a whole feature that was rejected. It also does not mention dedupe or
  find.
- **README is current as of 2026-08-15** and is the one document safe to hand a stranger.
  Install section written, feature list matches what exists, and the byte-identity
  guarantee is stated with its one exception. Its first-launch instructions are correct
  for macOS 15+, which the release notes initially were not. It had claimed "no network
  connections of any kind" for a day after QRZ landed — worth re-reading it whenever a
  capability changes, since it is the file that goes public first and the easiest one to
  forget. Its "no release has been published yet" line is **still accurate** — `v26.8.16`
  is a draft, and a draft is not published. Revisit that sentence when one is, not before.

**Where to pick up (2026-08-18).** A five-agent code review ran on 2026-08-17 and filed
issues #1–#40. **All forty are closed**, two of them without a code change: #7 was not a
bug, and #27's suggested fix measured slower than the code it replaced, so it got a
different one. The backlog is empty. Working tree clean, `main` tracking `origin/main`.
Session-by-session detail lives in `CLAUDE.local.md` rather than here.

The app layer has no test suite (§11 exempts it), so the fixes that landed there were
proved with headless harnesses over the real controllers — `swiftc` across every app
source but `main.swift`, linked against `-emit-library` builds of the three kits. They
live in the scratchpad rather than the repo, which is a gap worth closing if that layer
keeps changing.

If a built bundle is left running, quit it before rebuilding — and ask rather than using
`osascript ... to quit`, which once parked the app on a save-changes sheet and blocked
Apple Events until it was answered by hand.

The open build choices, roughly in order of how much they are worth:

- **The DESIGN.md fold-in.** The most valuable thing outstanding, and it grows more
  expensive each session: decision 18 means DESIGN.md describes a feature that was built
  and rejected, and §12 describes a pipeline whose triggers decision 19 narrowed.
- **Save selection as a new file** — the last of M2 — and **M3's replace**.
- **Bump `actions/checkout` and `actions/upload-artifact` to `@v5`.** Both target Node 20,
  which GitHub has deprecated; runs are being forced onto Node 24 and warn each time.
  Nothing is broken.
- **A document icon** for `.adi` files — the app mark on a page shape. Purely cosmetic and
  the owner has not asked for it.

Two things about the icon at small sizes, recorded so they are not rediscovered: at 32px
it is fully legible, rows and all, and at 16px the amber bar survives as a distinct mark
so there is still a signature — but the three rows blur into vertical banding, making the
card read as columns rather than rows. `iconutil` accepts hand-drawn art per size if that
ever matters. The owner has seen it rendered and is happy with it; do not "improve" it
unasked.

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
   as ignorable inter-field text if the next `<` opens a well-formed tag **and the run
   holds no letters or digits**, warning `unexpectedTextBetweenFields`; else scan
   forward, warning `resynchronized(offset:)`. Never discards a field it successfully
   read.

   *(Rung 3's qualification added 2026-08-18, when the rung was implemented — it had been
   written as "the scalar after the length is whitespace", which missed every separator
   that is not a space, and the helper for the real test sat uncalled. The rung as
   originally worded is too generous on its own: `<CALL:3>W1ABC<MODE:3>FT8` also has a
   well-formed tag after its run, and there the run is the rest of the callsign. A comma
   or a pipe between fields is a separator; `BC` is data.)*

   Related, same session: **only `<EOR>` and `<EOH>` end a record.** ADIF has two
   terminators, and any other LENGTH-less tag was being taken for one, so
   `<COMMENT:3>a<b>c <CALL:5>W1ABC<EOR>` produced two QSOs from one `<EOR>`. Such a tag
   is now carried as stray text with a warning.

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
    operation in the app. The owner rejected it on sight as far more complexity than he
    had asked for, and asked for ⌘F instead. All of it was deleted; `ADIFFind` is about
    seventy lines and hides nothing.

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

19. **CI is dormant; the pre-push hook is the gate. Releases are CalVer drafts.**
    *(2026-08-16, owner's direction — "don't burn any actions".)* §12 asks for a GitHub
    Actions pipeline and now has one, but with triggers narrower than a reader of §12 would
    expect, and the narrowing is deliberate rather than unfinished work.

    `ci.yml` fires only on `pull_request` and `workflow_dispatch`. It has no push trigger,
    so ordinary work costs nothing. `release.yml` fires on a `vYY.M.D` tag or a dispatch.
    Everything routine runs on this machine through `.githooks/pre-push` →
    `Scripts/ci-local.sh`, free and unlimited.

    The reasoning is borrowed from another project of the author's, inverted. There, macOS
    was dropped from CI because Linux and Windows covered what a Mac laptop cannot check
    locally. Here the app is macOS-only, so there is no cheap leg to keep and every hosted
    run bills at 10x — but the same premise cuts deeper in our favour: the development
    machine *is* the target platform, so the free local check tests the real thing rather
    than a stand-in. The rented Mac earns its multiplier on exactly two jobs: building what
    ships, and giving a clean-checkout second opinion with the full Xcode this machine
    lacks (decision 9).

    Versions are CalVer, matching that same project: `vYY.M.D`, no zero padding —
    `v26.8.3`, `v26.8.13`. The tag is the single source of truth; `MARKETING_VERSION`
    stamps it into the bundled plist at build time and never back into `Support/Info.plist`.
    Two releases in one day collide, and the escape hatch is a fourth component
    (`v26.8.16.1`), which **works today and needs no change to the workflow**. This file
    said it "would need the tag glob widened" and that was wrong: GitHub's `*` matches any
    character except `/`, so `release.yml`'s `'v*.*.*'` already matches `v26.8.16.1` —
    the third `*` absorbs `16.1`. Worth being right about, because the moment anyone needs
    it is the moment they are trying to ship a same-day second release, and widening an
    already-wide glob would cost a billed run to discover.

    The same permissiveness cuts the other way: `v-test.a.b` matches too, and
    `version="${GITHUB_REF_NAME#v}"` would put its name on a draft release.
    `'v[0-9]*.[0-9]*.[0-9]*'` would refuse that while still accepting the fourth
    component. Left alone deliberately — the only person who pushes tags here is the
    owner, a trigger change cannot be proven without spending a tag and a billed run on
    it, and the current glob errs towards firing rather than towards not firing.

    Releases are **drafts** and stay that way unless the owner publishes one, which is
    enough for an author installing his own build. Nothing is notarized and
    nothing will be: no paid Apple Developer account, ad-hoc signing only, with the
    Gatekeeper bypass documented in the README and the release notes. A pleasant
    consequence worth protecting: **there are no secrets in this repo and no reason to add
    any** — no certificates, no API keys, nothing to leak when it goes public.

## Identity

- Bundle identifier: `com.ww8l.adifeditor`
- Copyright: Tim Annable, 2026. **GPL-3.0-or-later** (changed from MIT on 2026-08-18,
  owner's ruling, before the repository went public — see DESIGN.md §4). The MIT file was
  a skeleton default nobody had chosen; asked directly, he chose copyleft.
- **Relicensing depends on sole authorship.** He can publish under other terms whenever he
  likes because he owns all of it. Merging an outside contribution ends that unless the
  contributor agrees their work may be relicensed — worth asking in the PR thread, since
  it is the difference between keeping a Mac App Store build possible and not.
- The app name "ADIF Editor" is intentionally generic (§4).
