# Fixtures

Test corpus for the ADIFKit round-trip suite (DESIGN.md §11).

**Nothing in here is ever edited to make a test pass.** A fixture is a statement about
what the world actually contains. If a fixture breaks the parser, the parser is wrong.

## `real/`

Genuine logger output, committed unmodified — original filename, original extension,
callsigns intact (these are public log data, per §11).

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
| `truncated.adi` | Final record has no `<EOR>` | Keep the partial record, warn (decision 7) |
| `truncated-tag.adi` | File ends mid-tag | Keep what parsed, warn |
| `unparseable-length.adi` | `<CALL:x>` — the LENGTH is not a number | Keep the field, recover the value, warn `unparseableLength`. Dropping the tag leaves a QSO with no callsign |
| `huge-length.adi` | `<CALL:9223372036854775807>` — a LENGTH near `Int.max` | Recover, warn `lengthMismatch`. The addition used to overflow and kill the process on SIGTRAP (§6.4) |
| `stray-bracket.adi` | `<<MODE:3>` — a doubled bracket | Warn `resynchronized`, then read `MODE` normally. Scanning past the second `<` used to yield a field named `<MODE`, silently |
| `html-error-page.adi` | Not ADIF at all: the HTML page a failed log download returns (§6.4's own example) | Open, warn, invent no fields. `<a href="http://…">` must not become a column named `a href="http`. Round-trips byte-identical |

### Fatal — the only error that refuses to open

| File | Defect |
|---|---|
| `invalid-utf8.adi` | A `0xFF` byte, illegal in UTF-8 anywhere. Must report the byte offset and refuse (decision 6) — lossy decoding would violate 6.2a |
