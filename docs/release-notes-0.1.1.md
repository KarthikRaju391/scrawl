Write and sketch with a finger on your Mac's trackpad: Keep-style tools, infinite pages, and a writing
mode that pans along your line.

**Requires macOS 14 Sonoma or later and a trackpad.** Built for Apple silicon and Intel (Intel is untested).

## Install

1. Download `Scrawl-0.1.1.dmg` below, open it, and drag **Scrawl** into **Applications**.
2. This build isn't notarized by Apple, so macOS asks before the first open:
   - **macOS 14:** Control-click the app in Applications, choose **Open**, then **Open** again.
   - **macOS 15 and later:** open it once, then go to **System Settings › Privacy & Security**,
     click **Open Anyway** next to "Scrawl was blocked", and confirm.
3. Press **⌃⌥D** to start drawing and **Esc** to get the pointer back.

The app asks for no permissions. Your pages stay on your Mac. Scrawl keeps anonymous usage counts (which
features you use; never your ink or text) in a local log; Settings › Share anonymous usage counts turns
them off ([what's counted](https://github.com/KarthikRaju391/scrawl/blob/main/docs/analytics.md)).
The only other network request is **Check for Updates**, when you choose it.

## What's new in 0.1.1

- **Click to draw** (Settings, off by default): a touch shows a blue aim mark under your finger, and a press
  starts the ink right at it. Let go of the click and keep drawing; lift and touch again for more strokes,
  with no more clicks, until you stop for 3 seconds (0-5 s in Settings; 0 means a click for every stroke).
  Taps with tap-to-click don't start drawing, and panning, zooming, the arrow keys and the eraser work
  exactly as before.
- **Start draw mode where I last wrote** is now a setting (on by default).
- **Writing never moves a word you've written:** the line break is decided in the gap before the next word,
  and a word started near the edge finishes on its line. ½- and ¾-page lines end where they should.
- **Pages overview:** every thumbnail shows at once (later pages used to stay blank for seconds).
- **Settings** window tidied: nothing cut off, the click-to-draw time sits under its switch.

Everything from 0.1.0 is still here: see its notes and the full list in
[CHANGELOG.md](https://github.com/KarthikRaju391/scrawl/blob/main/CHANGELOG.md).

## Checksums (SHA-256)

```
94516d540af0726a587a8765a87e5c3060dc5d5a0732cb11a87fa4ba4f346ecd  Scrawl-0.1.1.dmg
6b9a7279cc1f234a5d166542f26a45be3458392155d5458ea7e186423c78f535  Scrawl-0.1.1.zip
```
## Tested

Every automated check passes ([what they cover](https://github.com/KarthikRaju391/scrawl/blob/main/DEVELOPMENT.md#tests)),
including a robot user that drives the real app like a person: it writes, scratches out, scrubs, pans,
searches and shares, and checks what's on screen ([how it works](https://github.com/KarthikRaju391/scrawl/blob/main/robot/README.md)).
