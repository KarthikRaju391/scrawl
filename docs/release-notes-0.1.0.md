Write and sketch with a finger on your Mac's trackpad: Keep-style tools, infinite pages, and a writing
mode that pans along your line.

**Requires macOS 14 Sonoma or later and a trackpad.** Built for Apple silicon and Intel (Intel is untested).

## Install

1. Download `Scrawl-0.1.0.dmg` below, open it, and drag **Scrawl** into **Applications**.
2. This build isn't notarized by Apple, so macOS asks before the first open:
   - **macOS 14:** Control-click the app in Applications, choose **Open**, then **Open** again.
   - **macOS 15 and later:** open it once, then go to **System Settings › Privacy & Security**,
     click **Open Anyway** next to "Scrawl was blocked", and confirm.
3. Press **⌃⌥D** to start drawing and **Esc** to get the pointer back.

The app asks for no permissions. Your pages stay on your Mac. Scrawl keeps anonymous usage counts (which
features you use; never your ink or text) in a local log; Settings › Share anonymous usage counts turns
them off ([what's counted](https://github.com/KarthikRaju391/trackpad-draw/blob/main/docs/analytics.md)).
The only other network request is **Check for Updates**, when you choose it.

## What's in 0.1.0

New in this build:

- **Fix a word without the eraser:** scratch it out with a quick zig-zag, or double-tap with two fingers,
  hold the second tap and slide to scrub back through your strokes.
- **Writing flow:** after a pan your last two or three words stay on screen, the page never jumps more than
  half a view, a new line sits low enough to keep the lines above in sight, and panning right by hand to
  keep writing no longer sends you back to the margin. A page map shows where you are while you move around when zoomed in, then gets out of the way.
- **Pick up where you left off:** draw mode starts at the end of your last word, at the zoom you wrote at.
- **Quieter draw mode:** a short note that fades, a small capsule with the tool and modes, a thin frame
  that says you're drawing.
- **Toolbar:** Draw first and labelled, grouped by what you do, a tooltip with the shortcut on every button;
  the tuning sliders moved to Settings (⌘,). Every tool and mode toggles the same way from keys, toolbar
  and menus.
- **Help when you need it:** short tips (each at most twice) and a 30-second practice page.
- **Feedback:** a haptic tick when an undo lands or a line ends, a hint while the page is about to move,
  and undone strokes fade out.
- **Delete pages** from the overview (Delete, or right-click) or Edit › Delete Page (⌥⌘⌫), with ⌘Z to undo.
- **Zoom you can see and reuse:** the zoom in the toolbar and in draw mode, presets and a typed zoom; pinches
  land on clean values like 300%.
- **Find and share:** thumbnails show your ink, titled with the first handwritten line; ⌘F searches your
  handwriting; ⌘C copies a page as an image; File › Share Page.

Also:

- The paper fills the window at any shape, and in full screen (⌃⌘F). The trackpad maps without distortion to
  the largest trackpad-shaped area, outlined in draw mode.
- Writing mode: a new line goes back to the left margin (also by hand with Return).
- Edge guard: a palm or thumb resting on the trackpad's edge no longer draws, pans or zooms.
- Every mode key toggles: press it again to turn the mode off.
- Pages overview (G): thumbnails of every page, each with its date; a page grows into view when you open it.
- In draw mode: two-finger double tap = undo, three-finger double tap = redo.
- Arrow keys pan the page (Shift: a screen) and move the selection in the overview; Return, Space or G opens it.
- Picking a tool (P, M, H, E) outside draw mode starts drawing with it straight away.
- The page's edges are obvious: off-page space is a grey desk.
- Finger drawing with pressure. A public-API fallback keeps drawing working if the private touch
  framework is unavailable.
- Pen, marker, highlighter and eraser, with backgrounds.
- Infinite pages, writing mode (the page never moves mid-word), zoom lock.
- Autosave of every page, view and undo history. It survives crashes and force quits.
- PDF export of all pages, PNG export of one page.
- Built-in trackpad or Magic Trackpad. Multiple displays.

Full list: [CHANGELOG.md](https://github.com/KarthikRaju391/trackpad-draw/blob/main/CHANGELOG.md).

## Checksums (SHA-256)

```
1acfea1f0ca00d919296a1e5b8a632c5eeb3e6a1b5ea91aeefcb450238498349  Scrawl-0.1.0.dmg
ffcc8085f1fca635bf8040bfa070ef1a089759dcfda5427cde4a316407e2c5cd  Scrawl-0.1.0.zip
```

## Tested

Every automated check passes ([what they cover](https://github.com/KarthikRaju391/trackpad-draw/blob/main/DEVELOPMENT.md#tests)),
including a robot user that drives the real app like a person: it writes, scratches out, scrubs, pans,
searches and shares, and checks what's on screen
([results and screenshots](https://github.com/KarthikRaju391/trackpad-draw/blob/main/docs/robot-report.md)).
