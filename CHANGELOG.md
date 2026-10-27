# Changelog

## Unreleased

- Writing mode no longer pans sideways along the line (Karthik: distracting). The page moves only for the
  next line, when the line reaches its width; a faint vertical line in the canvas marks where (not in exports,
  thumbnails or the page map). The writing panel's pan choices (No pan / Centre / Left) are gone.
- Lines no longer break early (28-32% of the page) when a capital or descender made the line's ink tall.
- Click to draw: hard quick taps with tap-to-click no longer start drawing.

## 0.1.1 (2026-10-27, build 3)

- Click to draw (Settings, off by default): a touch shows a blue aim mark under your finger; a firm press
  (a real click, not a tap-to-click tap) starts the ink at the mark. Let go of the click and keep drawing;
  lift and touch again for more strokes with no clicks until you stop for 3 s (0-5 s in Settings; 0 means a
  click for every stroke). Two-finger pan, pinch, arrow keys and the eraser work exactly as with it off.
- Settings › Start draw mode where I last wrote (on by default).
- Writing mode never moves a word you've written: the line break is decided at the gap before the next word,
  and a word started near the edge finishes on its line. ½- and ¾-page lines end at about half and three
  quarters of the page.
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
