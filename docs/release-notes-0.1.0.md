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

The app asks for no permissions. Your pages stay on your Mac, and the only network request is
**Check for Updates**, when you choose it.

## What's in 0.1.0

- The paper fills the window at any shape, and in full screen (⌃⌘F). The trackpad maps without distortion to
  the largest trackpad-shaped area, outlined in draw mode.
- Writing mode: a new line goes back to the left margin (also by hand with Return).
- Edge guard: a palm or thumb resting on the trackpad's edge no longer draws, pans or zooms.
- Every mode key toggles: press it again to turn the mode off.
- Pages overview (G): thumbnails of every page; a page grows into view when you open it.
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
380d6720975920b8e8103210487be79a37b212c4c5a17f45ea3dbf514479034b  Scrawl-0.1.0.dmg
93d9d8c10a8f30d403164043991842bec7fb7ad7f5aa5a391e5d6be63b284762  Scrawl-0.1.0.zip
```
