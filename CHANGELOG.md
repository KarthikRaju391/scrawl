# Changelog

## Unreleased

## 0.1.5.2 (2026-11-04, build 10)

- **Updates inside the app:** Check for Updates shows what's new and offers **Download and Install**. The download is
  checked (its checksum, Scrawl's signature, the app inside it) before anything changes; **Restart to Update** then
  quits normally, swaps in the new version and opens it, and puts the old one back if the new one doesn't start.
  Works when Scrawl is in your Applications folder; otherwise it opens the release page. Versions before 0.1.5.2
  need one manual download of 0.1.5.2.

## 0.1.5.1 (2026-11-03, build 9)

- Scrawl keeps backups of your notebook: a copy each day (the last 7 days) in the Backups folder next to it, and a
  copy before any save that would remove more than half of your pages or writing.
- Safer saving: only the Scrawl app you open saves your notebook; development and test builds keep their own.

## 0.1.5 (2026-11-03, build 8)

- Pages overview: a long page's tile shows the page from its top, as it reads and as it usually opens, fading out at
  the bottom when there's more below. It showed a slice from the middle of the ink, so the tile didn't match the
  page you'd open. Short pages keep the tight crop.

- **File › Export Page…** (⇧⌘E, replacing Export Page as PNG…): one sheet with the options under the file browser.
  - **Format:** PNG or SVG. SVG is vector: one path per stroke, the same shapes as the PDF, highlighter at 35%,
    paper patterns as lines and dots. It opens in Figma, Illustrator, Inkscape and browsers.
  - **Scale:** 1×–4× or a custom 50–800%, with the size shown as you change it. Very large sizes are scaled down
    to 16,384 px a side and 64 megapixels, and the sheet says so.
  - **Area:** the page (its full width, from the top to just below the ink), or exactly what's on screen at the
    current zoom.
  - **Background:** Paper (the page with its grid, dots or lines, as on screen), White or Transparent.
  - It remembers your last choices. Export All Pages as PDF… (⌘E) is unchanged.
- **Select tool** (S, the dashed-rectangle button, Tools › Select): click and drag a box with the pointer. Picking it
  leaves draw mode, so the pointer is yours; S again (or the pen) goes back to drawing. The box stays on the page as
  you pan and zoom; a new drag replaces it; Esc, another tool or another page clears it. Selecting never changes the
  page or its undo.
  - **Copy as Image** (⌘C with a selection, or Copy on the small bar next to it): the rectangle, with strokes cut at
    its edges, at 2×, on the paper you last exported with (never transparent). Apps get a PNG, a vector PDF and SVG.
  - **Export Selection…** (⌥⌘E, or Export… on the bar): the export sheet with Area set to Selection.
- Export stays quick with long highlighter strokes, and the saved file always has the extension of the format you
  chose.

## 0.1.4 (2026-11-01, build 7)

- Pages overview: a cleaner header. The hint line next to the title is gone; the header is the title and the
  search field.
- Writing mode: the pause before the page moves to the next line is a setting, **Settings › Wait before next
  line**, from 0.2 s to 1 s (0.4 s by default, as before). A change applies from your next lift.
- A two-finger double tap (undo) or three-finger double tap (redo) no longer nudges the page: two fingers pan or
  zoom only once they've moved about 2 mm.
- Scratch-out is easier to trigger: a quick zig-zag with three long strokes counts, and it only has to lie partly
  over the word (it can overshoot the ends). Still pen and marker only, and one undo brings the word back.
- Writing mode is more reliable (found by model checking, TLA+ and fuzzing against its rules): after going back to
  finish a line, the next line comes again as usual (it could stop coming until an undo, Return or page change);
  a word you erase or scratch out no longer counts toward the line; scrolling or zooming during the pause cancels
  the move instead of yanking the page; changing the line width keeps your place in the block; a page switch right
  as the page moves opens the right page; one arrow press counts as a move by hand.

## 0.1.3 (2026-10-31, build 6)

- Pages overview: the "+ New page" tile comes first, then your pages, the one you changed most recently first
  (writing, erasing, scratching out, undoing; just looking at a page doesn't count). Tiles show when each page
  last changed. Page numbers and ⌘[ / ⌘] keep the notebook's order.
- The welcome window fits a 13-inch screen (its Start Drawing button used to be below the screen), and Start
  Drawing starts drawing. Help scrolls when it's taller than the screen.
- A held key does one thing: holding N no longer adds a page per key repeat, and D, W, L and the tool keys
  no longer flicker their mode.
- VoiceOver reaches every toolbar button, with its name, whether it's on, and its shortcut.
- With Reduce Motion on, opening and closing the pages overview fades instead of zooming.
- Edit menu: Cut, Copy, Paste and Select All work in the search, zoom and export-name fields (Copy copies the
  text there, not the page). View › Enter Full Screen is listed once.
- The window can't get narrower than the toolbar (the Draw button used to be cut off).
- Anonymous usage counts are now sent (release builds), not only kept in the local log: which features you
  use and how long you write, never your ink, pages or text. Settings › Share anonymous usage counts turns
  them off. What's counted: docs/analytics.md.

## 0.1.2 (2026-10-30, build 5)

- Writing mode: a word that ends just inside the guide line (no room for another) brings the next line at the
  same 400 ms word gap as crossing it. Ink that stops well before the line still doesn't.
- Pages overview: pressing G to open a page and G to go back, quickly and over and over, is one clean move each
  time: no flash of the previous page at the end of an opening, no overview showing alone for a frame, no
  blurry upscaled picture while a page grows from its tile, and no jump in the first frames. The toolbar stays
  on screen and fades with the page.
- A held G (or Return / Space / Esc in the overview) does one thing per press instead of repeating.

## 0.1.1 (2026-10-30, build 4)

Build 3 (27 Oct) was held as a draft and never published; build 4 replaces it.

- Writing mode, the next line: when a line's ink crosses the width marker, the next line comes at the next
  word gap (400 ms after you lift; a touch before then cancels it). The longer 650 ms / 1.5 s waits are gone,
  and there's no look-ahead break before you reach the marker. Ink that stops at 93-95% of the page, with the
  marker at the page's edge, brings the next line at the same 400 ms.
- Writing mode, blocks: the next line goes back to where the block you're writing began. It no longer drifts
  or jumps to the page's edge after a hand pan, a pinch, an undo, or going back to finish the previous line;
  panning right by hand to carry a zoomed-in line on keeps the block.
- The width marker is capped at 95% of the page (reachable inside the pad's edge band), and widths are 50% /
  75% / 100% counted from the block's start. 100% is the default (a saved choice is kept).
- Width panel: a click on the page closes it and keeps writing mode on.
- The "filled a screen" note doesn't come back for a page you chose to keep writing on.
- Writing mode no longer pans sideways along the line (Karthik: distracting). The page moves only for the
  next line, when the line reaches its width; a faint vertical line fades in there as the line's ink
  gets within 15% of the line width of it, and fades out after the new line (not in exports, thumbnails or
  the page map). The writing panel's pan choices (No pan / Centre / Left) are gone.
- Lines no longer break early (28-32% of the page) when a capital or descender made the line's ink tall.
- Click to draw: hard quick taps with tap-to-click no longer start drawing.
- Click to draw (Settings, off by default): a touch shows a blue aim mark under your finger; a firm press
  (a real click, not a tap-to-click tap) starts the ink at the mark. Let go of the click and keep drawing;
  lift and touch again for more strokes with no clicks until you stop for 3 s (0-5 s in Settings; 0 means a
  click for every stroke). Two-finger pan, pinch, arrow keys and the eraser work exactly as with it off.
- Settings › Start draw mode where I last wrote (on by default).
- Writing mode never moves a word you've written: the line break is decided at the gap before the next word,
  and a word started near the edge finishes on its line.
- The pages overview shows every thumbnail at once (they used to stay blank for seconds on later pages).
- Settings window: nothing cut off; the click-to-draw time sits under its switch.

## 0.1.0 (unreleased, 2026-10-26, build 2)

Licensed under the MIT License.

First public release. Scrawl was called Trackpad Draw during development. On first launch it moves the
old pages and settings over.

### Build 2 (2026-10-26)
- Scratch-out: a quick zig-zag over a word erases it (pen or marker; one undo brings it back).
- Undo scrub: two-finger double tap, hold the second tap and slide.
- Writing flow: the last 2-3 words stay on screen after a pan, pans move at most half the view, a new line
  sits below the middle, a hand pan right is respected (no jump back to the margin), no early new line at
  the page's end. Page map when zoomed in past 1.5x (View › Page Map).
- Draw mode starts where you last wrote. Quiet draw mode: short note that fades (it used to stay all
  session), status capsule, accent frame.
- One rule set for tools and modes from keys, toolbar, menu and hotkey; every one toggles. Tools menu; Zoom
  Lock menu item; checkmarks. Toolbar regrouped with Draw first and tooltips; sliders moved to Settings (⌘,).
- Tips in context (each at most twice) and Help › Practice Page.
- Haptic ticks, a chevron while the page waits to move, undo fade.
- Overview: thumbnails cropped to the ink, handwriting titles (on-device OCR), ⌘F search, ⌘C copy page,
  File › Share Page.
- Anonymous usage counts (local log; to PostHog only with a configured project token; off in Settings).
- Delete a page (overview Delete key or right-click, Edit › Delete Page ⌥⌘⌫), undone with ⌘Z.
- The page map shows only while you move the page by hand and covers ink past the page's edges.
- Zoom percentage in the toolbar and capsule, a badge while pinching, snapping to clean presets, a preset
  menu with a field to type any zoom.

### Drawing
- Finger drawing on the trackpad with pressure, from MultitouchSupport. The public macOS touch API is
  the fallback.
- Keep-style tools: pen, marker, highlighter, eraser, and none / square / dot / ruled backgrounds.
- Smoothing and Prediction sliders. Every stroke ends exactly where the finger lifts.
- The paper fills the whole window, at any window shape (tall beside another app, wide, full screen with
  the green button or ⌃⌘F). The trackpad maps without distortion to the largest trackpad-shaped area in
  the window, centred and outlined in draw mode. Pan to reach the paper around it.
- Return in writing mode starts the next line.
- The page arrows dim when there's no page that way: Prev on the first page, Next on the last. ⌘[ and ⌘]
  do nothing then too.
- Page dates: each page stores when it was created and last edited. The created date shows on its
  overview tile and on the open page, in the system's date format.
- Pages overview (G or the toolbar's grid button): thumbnails of every page, growing into the page when
  opened and shrinking back into the grid with G.
- The page's bounds are obvious. Anything off the page (beside it, above its top) is a plain grey desk with a
  shadowed page edge and no lines. In a tall window the page top sits at the window top.
- Edge guard: touches that start within 5% of the trackpad's edges are ignored, so a resting palm or
  thumb no longer draws, pans or zooms. The inner 90% covers the whole writing area. You can change it
  under ⚙︎ › Edge guard, and 0 turns it off.
- Arrow keys pan the page (Shift: a screen at a time) and move the selection in the pages overview, where
  one blue ring follows the arrows and the pointer; Return, Space or G opens it, Esc goes back.
- Fix: shortcut letters typed into a text field (e.g. the export save panel's file name) no longer act as
  shortcuts.
- Two-finger double tap = undo, three-finger double tap = redo (draw mode, also in writing mode), with a
  short "Undo" / "Redo" notice. The toolbar's undo / redo dim when there's nothing to undo / redo.
- Fix: with the eraser, a two-finger pan or pinch that started on ink could erase a bit of it.
- Picking a tool (P, M, H, E, or a toolbar tool) outside draw mode turns draw mode on with that tool.
- Every mode key toggles: D, W, L/Z on and off; M/H/E pressed again return to the pen; P on the pen
  goes back to the last other tool.

### Pages and writing
- Pages are infinite downwards, and each keeps its own view.
- Writing mode pans along the line and goes to the next line when it's full. It waits until the
  finger has been up 0.4 s, so the page never moves mid-word.
- Zoom lock.

### Reliability
- Pages, views and undo/redo history are saved automatically and survive a crash, kill -9 or quit.
- The pointer comes back however draw mode ends, including a crash, kill -9, display sleep,
  switching users or displays changing.
- Works with the built-in trackpad and Magic Trackpads, whichever one you touch.

### Release
- Export every page to one vector PDF, or the current page to PNG.
- First-run welcome, Help with every shortcut, About box, Check for Updates (GitHub releases).
- No network use except Check for Updates. Logs stay on this Mac.
- Universal app with the hardened runtime and no entitlements. Requires macOS 14 or later.

### Fixes
- Writing no longer stutters as the notebook grows: autosave encoded the whole notebook on the main
  thread (about 100 ms per save on a 4.5 MB notebook, every half second while writing). It now does that in
  the background.
- Settings panel controls were invisible in dark mode.
