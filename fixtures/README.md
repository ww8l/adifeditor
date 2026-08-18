# Fixtures

Test corpus for the ADIFKit round-trip suite (DESIGN.md §11).

**Nothing in here is ever edited to make a test pass.** A fixture is a statement about
what the world actually contains. If a fixture breaks the parser, the parser is wrong.

## `real/`

Genuine logger output, committed unmodified — original filename, original extension,
callsigns intact (these are public log data, per §11).

**The digits in the FT8CN filename are not an identifier of anything.** FT8CN exports
through `File.createTempFile("FT8CN", ".txt", …)` (`GeneralVariables.getTempFile`), and
Java names a temp file by appending `Math.abs(random.nextLong())` to the prefix. So the
19 digits are a fresh random 63-bit number per export, carrying nothing about the phone,
the operator or the time. Checked because a long opaque number in a filename that is about
to be published is worth being sure of; recorded so nobody has to check twice.

| File | Source | Notable |
|---|---|---|
| `FT8CN6469053684847039306.txt` | FT8CN | 66 QSOs, 1056 fields, all lengths correct. Lowercase `<eoh>`/`<eor>`; field-name casing mixed *within* a record (`<call:4>` beside `<QSL_RCVD:1>`); bare `FT8CN ADIF Export<eoh>` header with no `ADIF_VER` or `PROGRAMID`; exactly one space after every field. No `MY_SIG_INFO`. Written to `.txt`, not `.adi`. |

Still wanted: WSJT-X, MSHV, N1MM (§11 names all three).

## `synthetic/`

Hand-built hostile cases. The malformed ones are the only files expected to differ on
write, and only at the site of the defect.

### Well-formed — must round-trip **byte-identical**

| File | Tests |
|---|---|
| `minimal.adi` | Baseline: header, two records |
| `no-header.adi` | Starts with `<`, so no header (§8). Must *stay* headerless — no synthesized header |
| `empty.adi` | Zero bytes. No records, no crash |
| `header-only.adi` | Header, no records |
| `bare-eor.adi` | `<EOR>` with no fields — an empty record is still a record |
| `zero-length-field.adi` | `<COMMENT:0>` survives the trip (decision 2) |
| `utf8-comment.adi` | Multibyte data with an honest character count |
| `crlf.adi` | CRLF stays CRLF (decision 4) |
| `bom.adi` | UTF-8 BOM preserved, not stripped (decision 4) |
| `userdef-and-app.adi` | `USERDEF` declarations, `APP_*` fields, unknown field names |
| `mixed-case.adi` | Mixed field-name casing, as FT8CN writes it (decision 3) |
| `type-indicators.adi` | `<NAME:LENGTH:TYPE>` preserved |
| `newline-in-value.adi` | A value containing literal newlines (decision 8) |
| `angle-bracket-in-value.adi` | A value containing `<`, which must not confuse the scanner |
| `no-trailing-newline.adi` | File ends immediately after `<EOR>` |
| `odd-tag-spellings.adi` | `<CALL:005>`, `<CALL:+3>`, `<QSO_DATE:8:DATE>`, `<MODE:3:S:X>`, `<BAND:3:>` — LENGTH and TYPE spelled in ways that normalize away. All five used to be rewritten silently (§6.2a) |
| `varying-field-order.adi` | Records whose field order disagrees with each other |
| `sparse-fields.adi` | Fields present on some records only (§9 column union) |

### Malformed — parse must succeed, record a warning, and lose no field

| File | Defect | Expected recovery |
|---|---|---|
| `bad-length-short.adi` | `<CALL:3>W1ABC` — declared 3, actual 5 | Recover the full value, warn |
| `bad-length-long.adi` | `<CALL:9>W1ABC` — length overruns into the next tag | Recover, warn |
| `length-as-bytes.adi` | `<COMMENT:7>Grüße` — 5 characters, 7 bytes; a byte-counting writer | Re-read as bytes, warn `lengthInterpretedAsBytes` |
| `text-between-fields.adi` | Stray text between two fields | Keep both fields, warn `unexpectedTextBetweenFields` |
| `separator-between-fields.adi` | `<CALL:5>W1ABC,<GRIDSQUARE:4>DN70,` — honest lengths, a comma between fields | Keep every declared length and carry the commas, warn `unexpectedTextBetweenFields`. Round-trips byte-identical. The lengths used to be overridden and the comma glued onto the value, so the file was written back as `<CALL:6>W1ABC,` |
| `tag-inside-value.adi` | `<COMMENT:3>a<b>c ` — a value holding what looks like a tag | **One** record. `<b>` carries no LENGTH but is not `<EOR>` or `<EOH>`, and taking it for a terminator produced two QSOs out of one `<EOR>` |
| `truncated.adi` | Final record has no `<EOR>` | Keep the partial record, warn (decision 7) |
| `truncated-tag.adi` | File ends mid-tag | Keep what parsed, warn |
| `truncated-terminator.adi` | `…W1ABC<EOR` — the file ends one byte inside its last terminator | Complete it. Carrying the partial *and* synthesizing the terminator wrote the file back ending `<EOR><EOR`, which then warned on every open for ever |
| `duplicate-field.adi` | One record carrying `CALL` twice | Both copies kept and written back — round-trips byte-identical — with a `duplicateFieldInRecord` warning, since only the first is visible in the grid |
| `unparseable-length.adi` | `<CALL:x>` — the LENGTH is not a number | Keep the field, recover the value, warn `unparseableLength`. Dropping the tag leaves a QSO with no callsign |
| `huge-length.adi` | `<CALL:9223372036854775807>` — a LENGTH near `Int.max` | Recover, warn `lengthMismatch`. The addition used to overflow and kill the process on SIGTRAP (§6.4) |
| `stray-bracket.adi` | `<<MODE:3>` — a doubled bracket | Warn `resynchronized`, then read `MODE` normally. Scanning past the second `<` used to yield a field named `<MODE`, silently |
| `html-error-page.adi` | Not ADIF at all: the HTML page a failed log download returns (§6.4's own example) | Open, warn, invent no fields. `<a href="http://…">` must not become a column named `a href="http`. Round-trips byte-identical |

### Fatal — the only error that refuses to open

| File | Defect |
|---|---|
| `invalid-utf8.adi` | A `0xFF` byte, illegal in UTF-8 anywhere. Must report the byte offset and refuse (decision 6) — lossy decoding would violate 6.2a |
