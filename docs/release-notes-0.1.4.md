Write and sketch with a finger on your Mac's trackpad: Keep-style tools, infinite pages, and a writing
mode that takes you to the next line when you reach the end of one.

**Requires macOS 14 Sonoma or later and a trackpad.** Built for Apple silicon and Intel (Intel is untested).

## Install

1. Download `Scrawl-0.1.4.dmg` below, open it, and drag **Scrawl** into **Applications** (replace the old copy).
2. This build isn't notarized by Apple, so macOS asks before the first open:
   - **macOS 14:** Control-click the app in Applications, choose **Open**, then **Open** again.
   - **macOS 15 and later:** open it once, then go to **System Settings › Privacy & Security**,
     click **Open Anyway** next to "Scrawl was blocked", and confirm.
3. Press **⌃⌥D** to start drawing and **Esc** to get the pointer back.

## What's new in 0.1.4

- **A cleaner Pages overview header:** the hint line next to the title is gone. The header is the title and
  the search field.
- **Choose how long writing mode waits before the next line:** it moves to the next line after a short pause
  (0.4 s by default, as before); **Settings › Wait before next line** sets it from 0.2 s to 1 s.
- **Scratch-out catches more of your scratches:** a quick zig-zag over a word erases it more reliably, even a
  short one or one that runs past the word's ends.
- **Undo and redo taps keep the page still:** a two- or three-finger double tap no longer nudges the view.

Scrawl sends anonymous usage counts (never your ink, pages or text); **Settings › Share anonymous usage counts**
turns them off. [What's counted](https://github.com/KarthikRaju391/scrawl/blob/main/docs/analytics.md).

Full list: [CHANGELOG.md](https://github.com/KarthikRaju391/scrawl/blob/main/CHANGELOG.md).
