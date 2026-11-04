Write and sketch with a finger on your Mac's trackpad: Keep-style tools, infinite pages, and a writing
mode that takes you to the next line when you reach the end of one.

**Requires macOS 14 Sonoma or later and a trackpad.** Built for Apple silicon and Intel (Intel is untested).

## Install

1. Download `Scrawl-0.1.6.dmg` below, open it, and drag **Scrawl** into **Applications** (replace the old copy).
2. This build isn't notarized by Apple, so macOS asks before the first open:
   - **macOS 14:** Control-click the app in Applications, choose **Open**, then **Open** again.
   - **macOS 15 and later:** open it once, then go to **System Settings › Privacy & Security**,
     click **Open Anyway** next to "Scrawl was blocked", and confirm.
3. Press **⌃⌥D** to start drawing and **Esc** to get the pointer back.

## What's new in 0.1.6

- **Pictures on a page:** paste an image (⌘V), drop one on the page, or use File › Insert Image… (⇧⌘I). With the
  Select tool you can move it, resize it, delete it, bring it forward or send it back. It sits under your ink, and
  every change can be undone.
- **Pages from pictures:** File › New Page from Image… (⇧⌘N), or drop or paste pictures in the pages overview.
  Each becomes a new page you can write on with every tool. PNG, JPEG, HEIC, TIFF, GIF, PDF (first page) and
  screenshots, kept at full resolution and sharp as you zoom in.
- Exports and Copy as Image include the pictures under the ink.
- Pictures are stored next to your notebook, unchanged. Older versions of Scrawl open the notebook without them.

Scrawl sends anonymous usage counts (never your ink, pages or text); **Settings › Share anonymous usage counts**
turns them off. [What's counted](https://github.com/KarthikRaju391/scrawl/blob/main/docs/analytics.md).

Full list: [CHANGELOG.md](https://github.com/KarthikRaju391/scrawl/blob/main/CHANGELOG.md).
