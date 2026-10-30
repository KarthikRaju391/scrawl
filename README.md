# Scrawl

Write and sketch with a finger on your Mac's trackpad. The tools follow Google Keep's drawing screen:
pen, marker, highlighter, eraser, backgrounds. Pages scroll down forever, and a writing mode takes
you to the next line when a line is full.

![Scrawl](examples/porsche-window.png)

## Requirements

- macOS 14 Sonoma or later.
- A trackpad: the built-in one, or a Magic Trackpad.
- Apple silicon. The download also runs on Intel Macs, but nobody has tested it there yet.

## Installing

1. Download `Scrawl-<version>.dmg` from the
   [Releases](https://github.com/KarthikRaju391/trackpad-draw/releases) page. Check it against
   `SHA256SUMS.txt` if you like: `shasum -a 256 Scrawl-*.dmg`.
2. Open the DMG and drag **Scrawl** into **Applications**.
3. Open it. The app isn't notarized by Apple yet, so macOS stops it the first time:
   - **macOS 14:** Control-click (or right-click) Scrawl in Applications, choose **Open**, then
     **Open** again.
   - **macOS 15 and later:** open it once. macOS says it can't check Scrawl for malware: click
     **Done** (not Move to Trash). Then go to **System Settings › Privacy & Security**, scroll down
     to "Scrawl was blocked", click **Open Anyway** and confirm with your password. (The button
     only shows for a while after the blocked try; if it's gone, open Scrawl once more.)

   After that it opens normally. If you prefer Terminal:
   `xattr -dr com.apple.quarantine "/Applications/Scrawl.app"`.

The app needs no special permissions: no Accessibility, Input Monitoring or Screen Recording.

## Using it

- **⌃⌥D** (or **D** when the app is in front, or the welcome window's Start Drawing) starts drawing, and pressing it again stops. Drawing
  starts where you last wrote on the page, at the zoom you wrote at (a quick glide there), unless you've
  zoomed in somewhere else yourself.
  The paper fills the window, whatever its shape, and full screen works too (the green button, or View › Enter Full Screen). The
  trackpad (apart from a thin edge band, below) maps without distortion to the largest trackpad-shaped area
  in the window, centred. In draw mode a faint outline shows that area, and you pan to reach the rest. The pointer freezes and hides,
  a thin blue frame marks the window, and a small capsule at the bottom shows the tool, writing mode, the
  zoom lock and the page. **Esc** gives the pointer back. So do ⌃⌥D,
  switching apps, the display sleeping, and quitting.
- **One finger** draws. **Two fingers** pan, and pinching zooms. In draw mode, a **two-finger double
  tap** undoes and a **three-finger double tap** redoes (a short "Undo" / "Redo" shows). Keep the second
  tap down and **slide**: left steps back through your strokes, right brings them back, live; lift to keep
  what you see.
- **Scratch out** a mistake: a quick zig-zag over a word (pen or marker) erases it, and the zig-zag goes
  too. One undo brings it all back. A zig-zag on blank paper stays as ink, and a highlighter never erases. Outside draw mode
  a two-finger tap stays your normal right-click. Blue rings show where your fingers
  are, since there's no pointer.
- **Tools:** M marker, H highlighter, E eraser; press the same key again to go back to the pen.
  Picking a tool outside draw mode (key, toolbar or the Tools menu) turns draw mode on, so you can use it
  straight away. P picks the pen, and on the pen it goes back to the last other tool. 1–5 set the size.
- **Everything toggles, the same way everywhere:** D, W and L (or Z), the tool keys, their toolbar buttons and
  their menu items turn a mode or tool on, and the same key, click or menu item again turns it off. The toolbar
  and the menu checkmarks show what's on; in draw mode, where the toolbar is hidden, a short note says what
  changed ("Eraser off · Pen"). The small ⌃ chevron on a tool or the writing button (or a right-click on it)
  opens its sizes and colours or the writing settings.
- **Edge guard:** touches that start within 5% of the trackpad's edges are ignored, so a resting palm
  or thumb doesn't draw, pan or zoom. A stroke that starts inside can still run to the edge. Change
  it in **Settings (⌘,)** › Edge guard (0 turns it off), along with smoothing and prediction, and the
  switches for scratch-out and the page map.
- **Toolbar:** Draw first, then the tools and paper, writing and zoom lock, undo and redo, and pages.
  Hover over any button for what it does and its shortcut.
- **Writing mode (W):** the page stays put while you write along a line (pan with two fingers if you need
  room). When the line reaches its width, 50%, 75% or 100% of the page counted from where the block you're
  writing began (capped near the page's right edge), the page moves to the next line once your finger has
  been up for 0.4 s, so it never moves in the middle of a word; touching again sooner cancels it. A word
  that ends just short of the width counts too. The next line starts back where the block's first line
  began, so a block started mid-page stays mid-page, and it sits a little below the middle so the lines you
  just wrote stay in sight (Return does it by hand). Moving somewhere new by hand, a page change or
  switching writing mode on starts a new block. As a line nears its width a faint vertical guide line fades
  in where the next line comes. Nothing you've written ever moves. Pick the width with the small ⌃ chevron
  on the writing button.
- **Page map:** zoomed in past 1.5×, a small map of the page appears in the top-right corner while you
  move the page yourself (two fingers, pinch, arrow keys, scrolling) and fades out a second after you stop;
  writing never shows it. Point at it to keep it, then click or drag to move there (outside draw mode).
  View › Page Map turns it off.
- **Start draw mode where I last wrote** (Settings, on by default): draw mode opens on your last word, at the
  zoom you wrote it at. Turn it off to stay on the view you left.
- **Click to draw** (Settings, off by default): touching the trackpad only shows the blue aim mark: it appears
  where your finger lands, follows it while it's down and goes when you lift. Press to click and the stroke
  starts at the mark; let go of the click and keep drawing, lift and touch again for more strokes, with no more
  clicks. 3 s after your last stroke (0–5 s in Settings; 0 means a click for every stroke) it turns off.
  Taps don't turn it on, even with tap-to-click: only a real press does. The eraser works the same way;
  two- and three-finger gestures never draw, and panning works exactly as with the switch off.
- **Zoom lock (L)** keeps the zoom fixed while two fingers still pan.
- **Zoom percentage:** 100% is the page's width filling the view. The toolbar (and the capsule in draw mode)
  always shows it, a badge shows it while you pinch, and a pinch that ends within 4% of 100, 150, 200, 250,
  300, 400, 500, 600 or 800% lands on it exactly. Click the toolbar's zoom for those presets, the whole page,
  or to type any zoom. Each page keeps its zoom, also after a relaunch.
- **Arrow keys** pan the page by a tenth of the view, and Shift+arrows by a whole screen. They stop at the
  page's sides and top; at zoom 1, where the page already fills the width, ← → do nothing and ↑ ↓ scroll.
  In the pages overview the arrows move the blue selection ring. ⌘[ and ⌘] still change pages.
- **Pages:** N or ⌘N adds a page, ⌘[ and ⌘] move between them. Each page keeps its own view. The arrows dim
  (and ⌘[ / ⌘] do nothing) when there's no page that way; Next never adds a page, + does.
- **Pages overview (G, or the grid button):** every page as a thumbnail. The "+ New page" tile comes
  first, then your pages, the one you changed most recently first (writing, erasing, scratching out or
  undoing counts; just looking at a page doesn't). Page numbers and ⌘[ / ⌘] keep the notebook's order.
  The blue ring is your selection: it starts on the page you came from (marked with a small dot), and the
  arrow keys or the pointer move it. Return, Space, G or a click opens it: the page grows from its spot to
  fill the window (with Reduce Motion on, it fades in). Esc goes back to the page you came from. Opening
  the overview leaves draw mode, and opening a page puts you back in it.
- **Find and share:** tiles show each page's ink, titled with its first handwritten line (read on this
  Mac, never uploaded). **⌘F** searches your handwriting across pages; Return opens the match. **⌘C**
  copies the page as an image, and **File › Share Page…** sends it to Messages, Notes, Mail and the rest.
- **Delete a page:** Delete on the highlighted tile in the overview, right-click a tile › Delete Page, or
  Edit › Delete Page (⌥⌘⌫) for the open page. There's no confirm dialog: ⌘Z brings it back. Deleting the
  last page leaves a blank one.
- **Page dates:** every page remembers when it was created (shown in the small label at the top of the
  open page) and when it was last changed (shown under its tile in the overview). Pages from before
  0.1.0 show "date unknown" and come last in the overview.
- **Export:** ⌘E saves every page as one PDF (vector, sharp at any size), and ⇧⌘E saves the current
  page as a PNG.
- **Help › Scrawl Help** (⌘?) lists every shortcut, and **Help › Practice Page** walks you through the
  gestures in 30 seconds. Short tips appear when they'd help (each at most twice; Settings › Tips turns
  them off).

If you used it under its development name, Trackpad Draw, the first launch moves your pages and
settings over.

Everything is saved automatically, half a second after each change and when you quit. That covers
every page, its view, and undo/redo history. If the app is killed or crashes, at most the last half
second of ink is lost.

## Your data and privacy

- Pages are saved only on this Mac, in `~/Library/Application Support/Scrawl/Notebook.tdnb`.
- Your ink and pages are never uploaded. Scrawl keeps **anonymous usage counts**: which features you use
  (draw mode, undo, scratch-out, the overview…) and how long, with a random ID that isn't tied to you,
  never ink, page images, handwriting, search text or file names. They're written to
  `~/Library/Logs/Scrawl/events.jsonl`, and a release built with a PostHog project token also sends them
  there in the background every 30 s (anonymously: no person profiles, no location). The first launch says so; **Settings › Share anonymous usage
  counts** turns it all off. [docs/analytics.md](docs/analytics.md) lists every event.
- The only other network request is **Check for Updates**, which runs only when you choose it. It asks
  GitHub for the latest release and opens the release page if there's a newer one. Nothing connects at
  launch.
- Local logs live in `~/Library/Logs/Scrawl`. They note when the pointer was given back, and when
  a session ended without quitting. Touch diagnostics (raw touch data, for tuning) are off unless
  you turn on **Help › Record Touch Diagnostics**. They also stay on this Mac.
- If the app crashes, macOS's own crash reporter may offer to send a report to Apple, according to
  your Analytics settings in System Settings. Scrawl sends nothing itself.

## How the touch input works

For finger pressure, Scrawl reads the trackpad through **MultitouchSupport**, a private
macOS framework. That's why it can't be sold on the Mac App Store, and a future macOS update could
break it. If that framework is turned off or stops sending touches, the app switches to macOS's
public touch events and keeps working. Drawing still works there, but there's no pressure: line
width follows your speed. You can choose this yourself with **View › Use
Basic Touch Input**.

## If the pointer seems stuck

Press **Esc**, or ⌃⌥D. A small watchdog process also gives the pointer back if the app is killed or
crashes. As a last resort, quit the app from the Dock or Activity Monitor.

## Uninstalling

Delete **Scrawl** from Applications. To remove your pages and settings too, delete
`~/Library/Application Support/Scrawl` and `~/Library/Logs/Scrawl`, then run
`defaults delete com.karthikraju.scrawl`.

## Building from source

See [DEVELOPMENT.md](DEVELOPMENT.md). You need only the Command Line Tools, not Xcode: run
`./build.sh`, then `open "build/Scrawl.app"`.

## License

MIT. See [LICENSE](LICENSE). Copyright 2026 Karthik Raju.
