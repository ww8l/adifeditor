# How the manual's screenshots were made

Every figure in `manual.html` is a real capture of a real build. This file is the recipe
for each one, so any of them can be retaken when the app changes without having to work
out the staging again. `Scripts/manual.sh` refuses to render if a figure named by the
HTML is missing from `images/`, so a retake is never optional-by-accident.

## Setup, before any shot

1. **Build the app** and run it from the bundle, not from `swift build`:

   ```sh
   MARKETING_VERSION=26.8.18 Scripts/bundle.sh
   open -a ".build/ADIF Editor.app" <log>
   ```

2. **Force light appearance for the app only.** The shots are light-mode because a manual
   full of dark plates prints badly. This changes nothing on the rest of the machine:

   ```sh
   defaults write com.ww8l.adifeditor NSRequiresAquaSystemAppearance -bool YES
   defaults delete com.ww8l.adifeditor NSRequiresAquaSystemAppearance    # afterwards
   ```

3. **Size the window to 1000×520 points**, positioned at (200, 200). This is the single
   most important setting here. The first set was taken at the app's usual 1556×944, and
   at that size the grid's 9pt type comes out around **three points** once the figure is
   scaled to the width of a page — legible on screen, unreadable on paper. 1000×520 shows
   21 QSOs and the columns out to `TIME_OFF`, which is enough for every point the manual
   makes.

   The window's frame is autosaved and shared between logs, so put it back afterwards:

   ```sh
   defaults write com.ww8l.adifeditor "NSWindow Frame LogWindow" \
       "735 350 1556 878 0 0 3008 1662"
   ```

## The logs

Copy the fixtures somewhere scratch first — never shoot against `fixtures/`, and never
against a log that matters, since the POTA command is one confirmation away from writing
files.

| Log | Made from |
|---|---|
| `FT8CN6469053684847039306.txt` | `fixtures/real/`, unmodified — 66 QSOs |
| `recovered.adi` | the same log with one length made short, so the parser has something to recover: `sed '2s|<call:4>W9AV|<call:3>W9AV|'` |
| `session-with-repeats.adi` | the same log with records 2 and 6 duplicated: `awk 'NR==2\|\|NR==6 {print; print} NR!=2&&NR!=6 {print}'` |
| `already-stamped.adi` | the same log with a park reference on every QSO: `sed 's\|<eor>\|<MY_SIG_INFO:7>US-1234 <eor>\|'` |

## The shots

| File | Log | How to stage it |
|---|---|---|
| `01-window.png` | FT8CN | Nothing selected, nothing sorted. Clear any selection first. |
| `02-banner.png` | `recovered.adi` | Just open it — the banner appears by itself. |
| `03-editing.png` | FT8CN | Click the `GRIDSQUARE` cell on row 3 twice to open it for editing, capture the window, then crop to the detail (1200×400 px around the cell, including the column headers). Full width is far too small to see an open cell. |
| `04-sorted.png` | FT8CN | Click the `CALL` header to sort, then select rows 5–12. |
| `05-find.png` | FT8CN | Sort on `CALL`, ⌘F, type `KN6KI` — two matches, so the bar reads "1 of 2" — and leave the replace field empty so its placeholder shows. **Rendered rather than captured** (2026-11-27, for issue #41's replace field); see "When neither permission is available" below. |
| `06-dedupe-fields.png` | `session-with-repeats.adi` | Edit ▸ Find Duplicates… |
| `07-dedupe-review.png` | `session-with-repeats.adi` | …then **Find Duplicates**. Two repeats, which is what the manual quotes. |
| `08-pota-parks.png` | FT8CN | POTA ▸ Stamp Park Reference…, type `US-1234`. |
| `10-pota-filenames.png` | FT8CN | …then **Continue**, choose a folder named `Activations`, so the sheet reads naturally and no real directory is named. |
| `11-pota-nfer.png` | FT8CN | The same, with `US-1234, US-5678, US-9012`. |
| `12-existing-refs.png` | `already-stamped.adi` | POTA ▸ Stamp Park Reference…, `US-5678`, **Continue**. |
| `13-qrz-confirm.png` | FT8CN | Select five QSOs, then Edit ▸ Fill from QRZ…. Credentials must be stored or this is the "no credentials" alert instead. **This sheet appears before any request is made** — capturing it costs nothing at QRZ. |
| `16-settings.png` | — | ⌘, then click its title bar so the window draws active. |

There is deliberately **no shot of the folder chooser**: it is a stock macOS panel that
would show the sidebar of whoever took the picture.

## Capturing

The window has to be **key**, not merely frontmost, or it draws with grey traffic lights
and a dimmed toolbar and looks like a mistake. Activating the app is not enough when
another of its windows is key — click the window's own title bar first.

Three things about the capture itself, each of which cost an hour to learn:

- **Use ScreenCaptureKit**, through a small `swiftc` helper: `SCShareableContent`,
  `SCContentFilter(desktopIndependentWindow:)`, `SCScreenshotManager.captureImage`. It
  captures a window's own content whether or not anything is in front of it, and it
  composites a **sheet together with its parent window** — so a sheet shot needs no
  compositing, just capture the document window. The helper must touch
  `NSApplication.shared` before calling SCK or the process aborts in `CGS_REQUIRE_INIT`.
- **`screencapture -l` refuses an occluded window** ("could not create image from
  window"), and `CGWindowListCreateImage` is unavailable on the current SDK.
- **Never `screencapture -R`.** A region capture photographs the screen, so it picks up
  whatever else is in front — during this run, a video call.

Two more traps if the run is scripted:

- `CGWindowListCopyWindowInfo` with `.optionOnScreenOnly` **omits occluded windows**, and
  the app's accessibility tree reports *no windows at all* unless it is frontmost. Both
  look exactly like the app having closed its window.
- **System Events' `click at` cannot drive the grid.** It selects a row, but a second
  click never begins editing and shift-click never extends a selection — AppKit's
  click-to-edit path depends on mouse-up timing and click count that a synthesized
  accessibility click does not carry. Post real `CGEvent`s instead, or set the selection
  through accessibility (`set selected of row N`, then shift-arrow keys).

## When neither permission is available

On 2026-11-27 this machine had neither Accessibility nor Screen Recording permission
for the terminal (`osascript is not allowed assistive access`; ScreenCaptureKit failed
with `-3801`, "declined TCCs"), so the app could be neither driven nor captured.
`05-find.png` was made another way, and it is the one figure here that is not a capture
of the running app:

- A `swiftc` program compiled across every app source but `main.swift`, linked against
  `-emit-library` builds of the three kits — the same harness the app layer's fixes are
  proved with. It opens the log with `LogDocument(contentsOf:ofType:)`, calls
  `makeWindowControllers()` and `showWindow`, sets the frame to 1000×520 at (200, 200),
  sets `NSApp.appearance` to aqua, and activates so the window is key. The window,
  toolbar and find bar are the shipping code, on screen.
- The state is set in code: `sortRecords(byColumn: "CALL", ascending: true)`,
  `showFind(nil)`, then `insertText("KN6KI")` into the search field's editor and its
  action sent.
- The image is AppKit drawing the window's frame view into a bitmap
  (`bitmapImageRepForCachingDisplay` / `cacheDisplay` on `contentView.superview`),
  which needs no permission. At 2× that is 2000×1040; downscale as below.
- **The column header is translucent**, blurring the rows scrolled beneath it, and a
  bitmap render has no blur — the rows show through as ghost text. The program puts an
  opaque `controlBackgroundColor` view behind the header for the render, which is how the
  blur over white rows reads on screen anyway.
- Two visible differences from a capture: no document icon beside the title, and no
  scroll bar (overlay scrollers are hidden at rest). Neither is something the manual
  points at.

Prefer a real capture whenever the permissions are back. This is the fallback, not the
method.

## Afterwards

Downscale to 1400 px wide, which is about 200 dpi at the figure size the manual uses:

```sh
sips -Z 1400 shot.png --out docs/manual/images/<name>.png
```

`16-settings.png` is left at its native 920 px — it is a small window, and the manual
renders it at 78% width (`figure.narrow`, which every sheet shot also uses).

Then **look at every image at full size before committing it.** The FT8CN log's
callsigns, grids, dates and reports are already public through LoTW, PSK Reporter and
POTA spots, and `CLAUDE.md` has cleared that fixture for publication — but a folder
chooser, a Settings window, or anything with a real QRZ credential in it is not, and a
screenshot is the easiest way in this project to publish something nobody meant to.
