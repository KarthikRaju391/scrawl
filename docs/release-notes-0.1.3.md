Write and sketch with a finger on your Mac's trackpad: Keep-style tools, infinite pages, and a writing
mode that takes you to the next line when you reach the end of one.

**Requires macOS 14 Sonoma or later and a trackpad.** Built for Apple silicon and Intel (Intel is untested).

## Install

1. Download `Scrawl-0.1.3.dmg` below, open it, and drag **Scrawl** into **Applications** (replace the old copy).
2. This build isn't notarized by Apple, so macOS asks before the first open:
   - **macOS 14:** Control-click the app in Applications, choose **Open**, then **Open** again.
   - **macOS 15 and later:** open it once, then go to **System Settings › Privacy & Security**,
     click **Open Anyway** next to "Scrawl was blocked", and confirm.
3. Press **⌃⌥D** to start drawing and **Esc** to get the pointer back.

## What's new in 0.1.3

- **Pages overview, most recent first:** the "+ New page" tile comes first, then your pages, the one you changed
  last first. Tiles show when each page last changed.
- **The welcome window fits small screens,** and **Start Drawing** starts drawing.
- **Held keys act once:** holding N adds one page, and D, W, L and the tool keys don't flicker.
- **VoiceOver** reaches every toolbar button, with its name, state and shortcut.
- **Reduce Motion:** the pages overview fades instead of zooming.
- **Edit menu:** Cut, Copy, Paste and Select All work in text fields (search, zoom, export name).

## Usage counts

Scrawl now sends anonymous usage counts: which features you use and how long you write, with a random ID
that isn't tied to you. Never your ink, pages, text or file names. **Settings › Share anonymous usage counts**
turns them off. [What's counted](https://github.com/KarthikRaju391/scrawl/blob/main/docs/analytics.md).
The only other network request is **Check for Updates**, when you choose it.

Full list: [CHANGELOG.md](https://github.com/KarthikRaju391/scrawl/blob/main/CHANGELOG.md).
