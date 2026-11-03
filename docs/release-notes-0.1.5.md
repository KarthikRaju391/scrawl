Write and sketch with a finger on your Mac's trackpad: Keep-style tools, infinite pages, and a writing
mode that takes you to the next line when you reach the end of one.

**Requires macOS 14 Sonoma or later and a trackpad.** Built for Apple silicon and Intel (Intel is untested).

## Install

1. Download `Scrawl-0.1.5.dmg` below, open it, and drag **Scrawl** into **Applications** (replace the old copy).
2. This build isn't notarized by Apple, so macOS asks before the first open:
   - **macOS 14:** Control-click the app in Applications, choose **Open**, then **Open** again.
   - **macOS 15 and later:** open it once, then go to **System Settings › Privacy & Security**,
     click **Open Anyway** next to "Scrawl was blocked", and confirm.
3. Press **⌃⌥D** to start drawing and **Esc** to get the pointer back.

## What's new in 0.1.5

- **Export a page as PNG or SVG, at any size:** File › Export Page… (⇧⌘E) picks the format, a scale from 1× to 4×
  or any size from 50% to 800%, the whole page or just what's on screen, and paper, white or a transparent
  background. SVG opens in Figma, Illustrator, Inkscape and browsers.
- **Select part of a page:** the Select tool (S) lets you drag a box with the pointer, then **Copy** it as an
  image (⌘C) or **Export** it (⌥⌘E) with the same options.
- **Overview previews that match long pages:** a long page's tile now shows it from the top, as it opens, and
  fades out at the bottom.
- **Fixes:** exporting long highlighter strokes is quick, and the saved file always has the right
  extension.

Scrawl sends anonymous usage counts (never your ink, pages or text); **Settings › Share anonymous usage counts**
turns them off. [What's counted](https://github.com/KarthikRaju391/scrawl/blob/main/docs/analytics.md).

Full list: [CHANGELOG.md](https://github.com/KarthikRaju391/scrawl/blob/main/CHANGELOG.md).
