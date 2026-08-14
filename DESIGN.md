# ADIF Editor — Design Document

A native macOS editor for amateur radio ADIF log files, with purpose-built tools for
Parks on the Air (POTA) activation logs.

Status: pre-implementation. This document is the specification. It should be kept
current as decisions change.

---

## 1. Problem

POTA activators log with contest and digital-mode software — WSJT-X, MSHV, N1MM —
none of which know anything about POTA. The `.adi` files they produce are valid ADIF
but lack the `MY_SIG_INFO` field carrying the park reference, which POTA's uploader
needs. Every activation therefore requires the same manual edit: add a column, fill it
with the park reference on every row, save under a specific filename. Activations from
multiple parks at once ("n-fers") require that once per park, into separate files.

On Windows, the tool for this is ADIF Master (DXShell.com), a closed-source freeware
grid editor. There is no Mac equivalent. Mac users either run Windows in a VM, use
Wine, or hand-edit ADIF in a text editor.

## 2. Goals

- Open, edit, and save `.adi` / `.adif` files in a spreadsheet-style grid
- Make the POTA stamp-and-split workflow two button presses
- Never damage a log file
- Run on any modern Mac without the user installing a toolchain

## 3. Non-goals

Explicitly out of scope. Do not build these, do not add "just in case" hooks for them:

- **Any format other than ADI.** No ADX, Cabrillo, TR, CT, eQSL, CSV, or JSON import
  or export. One format in, one format out.
- **Logging.** This is not a logger. It edits files produced by loggers. No radio
  control, no clock, no QSO entry form, no persistent logbook. Callsign lookup is the
  one exception, added 2026-08-14 — see §6.5 and §10.4.
- **Uploading.** The app never transmits log data anywhere. The user uploads to POTA
  themselves. The QRZ lookup of §10.4 sends callsigns and receives station details; it
  does not send QSOs, files, or anything else the log contains.
- **Telemetry, analytics, crash reporting, update checks.** The app phones home for
  nothing and checks for nothing. The only network traffic it ever originates is a
  lookup the user asked for by name, against credentials the user supplied.
- **SOTA, WWFF, IOTA, or contest-specific features.** POTA only, for now.

## 4. Legal and provenance

This is a clean-room implementation. ADIF Master is proprietary; its license forbids
redistribution and embedding. Nothing in this project may be derived from its binary,
its source, its icons, or its branding. Feature parity is fine — copying is not.

The ADIF specification itself is public (adif.org). Implement against the spec.

The name "ADIF Editor" is intentionally generic and descriptive. Do not name the app,
its bundle, its repository, or its documentation in any way that suggests affiliation
with or derivation from ADIF Master.

License: open source, permissive (MIT unless the owner decides otherwise).

## 5. Platform and stack

| Decision | Value | Rationale |
|---|---|---|
| Language | Swift | Native, no runtime to ship |
| UI framework | AppKit | `NSDocument` and `NSTableView` provide most of what this app needs for free |
| Minimum OS | macOS 14 | Recent enough for modern Swift, old enough to cover most users |
| Architecture | Universal (arm64 + x86_64) | Intel Macs are still common in the hobby |
| Dependencies | None | No SPM packages. Foundation and AppKit only |
| Sandbox | Enabled | Required for credible public distribution; retrofitting is painful |
| Network | Client only, for §10.4 | The narrowest entitlement that allows a QRZ lookup. No server capability, ever |
| Signing | Ad-hoc only | See §12 |

**Why AppKit rather than SwiftUI.** `NSDocument` supplies multilevel undo/redo,
dirty-state tracking, Save / Save As / Revert, the Recent Files menu, autosave, and
document-type association for `.adi` and `.adif` — a large fraction of the feature list
with no code. `NSTableView` supplies column reordering, column resizing, header
click-to-sort, row selection semantics, and in-place cell editing. SwiftUI's `Table` is
a display control; cell-level editing in it is a fight. SwiftUI may be used for
auxiliary panels (validation results, statistics) via `NSHostingView` where convenient.

## 6. Core principles

These are invariants. If an implementation decision conflicts with one of these, the
principle wins and the decision changes.

**6.1 — Never modify the source file.** Every operation that produces output writes a
new file. The original the user opened is not touched unless they explicitly invoke
Save on it. The POTA split always writes new files.

**6.2 — Lossless round-trip.** A file parsed and written back without edits must
preserve every field it contained, including `APP_*` vendor fields, `USERDEF` fields,
fields not in the ADIF spec, and header content. The app must never silently drop data
it does not understand. Round-trip fidelity is enforced by tests (§11).

**6.3 — Additive, never destructive.** The app creates columns and fills empty cells.
It does not overwrite existing values in bulk. If a field already has a value, an
automated tool leaves it alone. Corrections are made by the user, by hand, in the grid.

The one place this collides with the feature set is the n-fer split: producing three
per-park files from a log that already carries `MY_SIG_INFO` necessarily writes a
different value into two of them. This is permitted, because the outputs are new
derived files and the source is untouched (6.1) — but it must not be silent. If the
column already contains values, prompt: *"N rows already have park references. Replace
them in the split output?"* Fill empty cells without comment.

**6.4 — Never crash, never corrupt.** The app will encounter ADIF from loggers neither
the author nor the spec anticipated, hand-edited files, and truncated downloads. A
malformed file produces a clear diagnostic naming the problem and the byte or line
offset. It does not produce a stack trace, and it does not produce a silently mangled
log.

**6.5 — One network destination, chosen by the user, or none.** *(Amended 2026-08-14,
owner's ruling. This weakens the principle; the original text is kept below because
what was given up matters.)*

> **Was:** No network. Not "no network by default." No network. The sandbox
> entitlements must not include any network client or server capability.

The app may make exactly one kind of outbound connection: a callsign lookup against
QRZ's XML service, using a subscription the user pays for and credentials the user
enters (§10.4). Everything else in the original rule stands, and the following are now
the invariants in its place:

- **No server capability.** `com.apple.security.network.server` must never appear in
  the entitlements. The client entitlement is the whole of the concession.
- **Offline is the default and the resting state.** A fresh install has no credentials
  and therefore opens no connections. The app must remain fully usable with the network
  off — every feature except the lookup itself works unchanged, and nothing blocks,
  retries in the background, or warns.
- **No log data leaves the machine.** A lookup sends one callsign. It does not send
  QSOs, files, headers, or anything identifying the user beyond the credentials the
  service requires to authenticate them.
- **No connection the user did not ask for.** No telemetry, no update check, no
  prefetch, no warming, no background refresh. Traffic happens when the user invokes
  the lookup command and at no other time.
- **Credentials live in the Keychain**, never in a preference file, never in the repo,
  never in a log or a crash report.

The reason this rule was absolute in the first place was that its absence from the
entitlements made it enforceable by the OS rather than by discipline. That protection
is gone and cannot be recovered while the client entitlement is present. What replaces
it is this list and the tests in §11 — weaker, and knowingly so.

## 7. Architecture

Four layers, built in this order. Each is independently testable.

```
ADIFEditor/
├── ADIFKit/              Pure Swift. No AppKit. No I/O beyond Data in/out.
│   ├── ADIFParser        Tokenizer + record assembly
│   ├── ADIFWriter        Serialization
│   ├── ADIFRecord        A single QSO
│   ├── ADIFDocument      Header + records + column order
│   └── ADIFField         Field name normalization, known-field registry
│
├── Model/                Document state, mutation, undo
│   ├── LogDocument       NSDocument subclass
│   ├── ColumnSet         Ordered visible columns, derived from data
│   └── FilterState       Active column filters
│
├── UI/
│   ├── LogWindowController
│   ├── GridViewController      NSTableView host
│   ├── FilterBar
│   └── Panels/                 Validation, statistics
│
├── POTA/
│   ├── ParkReference     Parsing and lenient validation
│   ├── StampOperation    Add + fill MY_SIG_INFO
│   ├── SplitOperation    N parks → N files
│   └── POTAFilename      Naming convention
│
└── QRZKit/               The only layer permitted to touch the network (§6.5)
    ├── QRZTransport      Protocol. The seam the tests substitute
    ├── QRZSession        Authenticate, hold the session key, re-authenticate
    ├── QRZCallsign       The parsed response for one callsign
    ├── QRZFieldMapping   QRZ's fields → ADIF's
    └── QRZLookup         Rows in, proposed fills out
```

`ADIFKit` must not import AppKit and must be usable from a command-line test harness.

`QRZKit` must not import AppKit either, and everything in it above `QRZTransport` must
be reachable in tests without a network connection. The live `URLSession` implementation
of that protocol is the only code in the project that opens a socket, and it is
deliberately thin enough to read in one sitting.

## 8. ADIF format handling

Implement against ADIF 3.1.6 (the current spec at time of writing). The `.adi` format
is simple but has sharp edges.

**Structure.** If the first non-whitespace character of the file is `<`, the file has
no header and records begin immediately. Otherwise, everything up to and including the
`<EOH>` tag is the header. Records follow, each terminated by `<EOR>`.

**Fields.** `<FIELDNAME:LENGTH>` or `<FIELDNAME:LENGTH:TYPE>`, followed by exactly
LENGTH characters of data. Field names are case-insensitive; normalize to uppercase
internally but remember the file's original casing for round-trip fidelity if it is
cheap to do so. Text appearing between fields is not part of any field and is ignored.

**The length hazard.** The spec's definition of LENGTH is ambiguous in practice for
non-ASCII data — some writers emit a byte count, some a character count. Do not trust
LENGTH blindly. Read LENGTH characters, then verify that the next non-whitespace
character is `<`. If it is not, the length was wrong: resynchronize by scanning forward
to the next `<` and record a warning. This single behavior will handle most real-world
malformed files.

**Preserve.** `USERDEF` definitions in the header. `APP_<PROGRAMID>_<FIELD>` fields.
Any field name not in the spec's field list. Header comment text.

**Output format.** One QSO per line, `<EOR>` at end of line. This makes ADI files
diffable and readable, and matches the convention most tools use. Preserve the header
if one was present; write a minimal one if not.

**Encoding.** UTF-8 in, UTF-8 out. Handle a UTF-8 BOM on input by stripping it.

## 9. Data model

A log is an ordered list of records; a record is an ordered map of field name to string
value. All values are strings — the app does not coerce types, because coercing and
re-emitting is how data gets damaged.

**Columns are the union of every field present anywhere in the file.** A log where only
some QSOs carry `RST_SENT` still shows an `RST_SENT` column, with empty cells where the
field is absent. An empty cell and an absent field are the same thing; writing a record
omits fields whose value is empty.

Column order on load: fields in the order first encountered in the file. The user can
reorder columns; that ordering is a view concern and does not change output order
unless the user has explicitly reordered, in which case output follows the view.

## 10. Features

### 10.1 Grid (the general editor)

- Click a column header to sort ascending / descending. Sorting is a view operation;
  it does not reorder the underlying records unless the user saves after sorting
- Edit any cell in place
- Select rows (single, shift-range, command-discontiguous)
- Delete selected rows
- Add a column with a user-supplied name
- Filter on any column by value — this is the primitive behind the Field Day workflow:
  filter on `OPERATOR`, select the rows that aren't yours, delete them
- Save selection as a new file
- Undo everything, via `NSUndoManager`

### 10.2 POTA tools

Two commands. Both live in a POTA menu and on a visible toolbar button.

**Stamp.** Prompt for one or more park references. Add a `MY_SIG_INFO` column if not
present, fill it on every row that does not already have a value (§6.3). If a single
park was given, the document is stamped in place (in memory; the file on disk is
unchanged until saved). If multiple parks were given, this becomes a Split.

**Split.** N park references produce N output files. Every QSO appears in every file —
being inside three parks means each contact counts for all three. The files differ only
in `MY_SIG_INFO`. The source document is not modified.

Output filenames follow POTA's convention, derived from data already in the log:

```
CALL@REFERENCE YYYYMMDD.adi
W1XYZ@US-1234 20260811.adi
```

Callsign comes from `STATION_CALLSIGN`, falling back to `OPERATOR`. Date comes from the
earliest `QSO_DATE` in the log. If neither callsign field is present, prompt once.
The user picks a destination folder; the app proposes the filenames and lets the user
confirm or edit before writing.

**`MY_SIG`.** POTA's uploader can generally infer the program from `MY_SIG_INFO`. A
preference controls whether to also write `MY_SIG` = `POTA`. Default: off.

**Park reference validation is lenient.** The format is a short alphanumeric prefix, a
hyphen, and four or five digits (`US-1234`, `VE-5093`). Warn on input that doesn't match
— do not reject it. POTA's own reference scheme has changed over time and will change
again; a validator that refuses a valid reference is worse than one that lets a typo
through to a grid the user is looking at anyway.

### 10.3 Validation panel

Non-blocking, advisory. Flags:

- Missing required fields: `CALL`, `QSO_DATE`, `TIME_ON`, `MODE`, `BAND`
- Missing `MY_SIG_INFO`
- Malformed dates or times
- `BAND` and `FREQ` disagreeing
- Fewer than 10 QSOs (POTA's threshold for a valid activation)
- `MODE` = `MFSK` with `SUBMODE` = `FT4`, and similar — POTA takes `SUBMODE` over
  `MODE`, and WSJT-X writes FT4 this way. Advisory note, not an auto-fix

### 10.4 QRZ callsign lookup

*(Added 2026-08-14. Requires the §6.5 amendment; read that first.)*

Fills station details the operator would otherwise type by hand, using the QRZ XML
subscription they already pay for. Off until credentials are entered.

**Credentials.** A QRZ username and password, entered in Preferences, stored in the
Keychain under the app's own service identifier. The password is never written to a
preference file, never logged, and never shown after entry. Removing them returns the
app to a state indistinguishable from a fresh install.

**Fields filled.** QRZ's response maps to `NAME`, `QTH`, `STATE`, `CNTY`,
`GRIDSQUARE`, `COUNTRY`, `DXCC`, `CQZ`, and `ITUZ`. A field QRZ does not return for a
given callsign is left alone; so is a field the log already has a value for (§6.3).

**Flow, following the dedupe shape.** Select rows, invoke the command, and the app
shows every proposed fill — row, field, and the value it would write — before writing
any of them. Each is individually untickable. Nothing reaches the grid until the sheet
is confirmed, and nothing reaches disk until Save (§6.1).

**Failure is quiet and complete.** No credentials, no network, a bad password, an
expired session, a rate limit, a callsign QRZ has never heard of: each produces a
diagnostic naming which callsigns could not be looked up and why, and leaves every row
untouched. A lookup that fails halfway does not half-fill the log — proposals are
collected first and applied as one undoable edit, or not at all (§6.4).

**Not built and not to be built:** automatic lookup on open, lookup on paste, lookup as
a background pass, or any cache that survives quitting the app. The operator asks, once,
by name (decision 12).

## 11. Testing

`ADIFKit` gets real unit tests. The UI does not need them.

**Round-trip tests are the priority.** For every fixture file: parse, write, parse
again, and assert the two parses are identical. Then assert the written bytes are
byte-identical to the input for files already in canonical form.

**Fixtures.** Real `.adi` files from WSJT-X, MSHV, and N1MM, committed to the repo
(with callsigns intact — these are public log data). Plus synthetic hostile cases: no
header, wrong LENGTH values, UTF-8 in comments, truncated final record, empty file,
`<EOR>` with no fields, unknown field names, `APP_` fields, `USERDEF` fields, CRLF line
endings, BOM.

**The bar:** no fixture, however malformed, may crash the parser or produce output that
loses a field present in the input.

**`QRZKit` is tested without a network.** Every test substitutes a fake `QRZTransport`
and asserts against canned XML, including the failure shapes: bad password, expired
session key, callsign not found, rate limit, truncated body, and XML that is not QRZ's
at all. The suite must never open a socket; a test that needs one is a test that belongs
to a code path §6.5 does not permit.

The canned responses are currently **built from QRZ's published format, not captured
from the live service** — the same standing as the synthetic hostile ADIF fixtures, and
the same weakness: they encode what the documentation says QRZ does, so a discrepancy
between the documentation and the service is invisible to them. Replacing them with
captured responses is worth doing the first time a real subscription is at hand.
Captured responses must have the session key scrubbed before they are committed.

Two of these are load-bearing rather than routine, because they are what the OS used to
guarantee for free: that a lookup proposes fills and never overwrites an existing value
(§6.3), and that a failure anywhere in a batch leaves every row untouched (§6.4).

## 12. Build and distribution

**CI:** GitHub Actions on macOS runners. Build universal, run tests, produce a zipped
`.app`, attach to a GitHub Release on tag.

**Signing:** ad-hoc only — `codesign --force --deep --sign -`. This is free and requires
no Apple Developer account. It is also **not optional**: Apple Silicon refuses to
execute arm64 binaries with no signature at all, killing the process rather than
warning. Ad-hoc signing satisfies that requirement while leaving the app unnotarized.

**What users will see:** Gatekeeper blocks the app as being from an unidentified
developer. On macOS 15 and later the old right-click-Open bypass no longer works; the
user must attempt to launch, get blocked, then go to System Settings › Privacy &
Security and click "Open Anyway." The README must document this prominently, including
the one-line alternative:

```
xattr -dr com.apple.quarantine /Applications/ADIF\ Editor.app
```

Because the project is open source, users who object to running an unsigned binary can
build it themselves. That is the intended answer to the signing question.

**Bundle identifier:** `com.<callsign>.adifeditor`.

## 13. Milestones

Sequenced so the app is useful for real activations as early as possible, rather than
reaching feature parity all at once.

**M1 — Usable.** `ADIFKit` parser and writer with round-trip tests. `NSDocument` app,
grid display, cell editing, header sort, save. POTA stamp and split. At the end of M1
the author can prep a real activation log with it.

**M2 — Field Day.** Column filters, row selection, delete rows, save selection as new
file. At the end of M2 the app handles both of the author's actual workflows.

**M3 — Comfortable.** Add column, find, replace within selection, column reorder,
validation panel, statistics.

**M4 — Polish.** App icon, README with screenshots, CI release pipeline, whatever parity
gaps have proven to matter in use.

**QRZ lookup (§10.4)** was asked for after M1 and does not belong to a milestone. It
brings Preferences with it — M4's item, pulled forward because credentials need
somewhere to live — which is also where `MY_SIG` finally becomes reachable without
editing a default by hand.

Do not begin a milestone before the previous one is working. In particular, do not
build UI before `ADIFKit`'s round-trip tests pass — parser bugs quietly corrupt logs,
and they are much harder to find through a grid.

## 14. Open questions

- ~~Preferences: what belongs there beyond `MY_SIG`? Defer until M4.~~ Answered by
  §10.4: QRZ credentials, which is what forced Preferences to exist at all.
- Should sorting the grid and then saving write records in sorted order, or preserve
  original order? Current assumption: sorted order, since the user asked for it.
- Very large logs (100k+ QSOs from a contest station): does `NSTableView` with a
  string-map backing store stay responsive? Measure in M2 before optimizing.
