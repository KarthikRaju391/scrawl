Write and sketch with a finger on your Mac's trackpad: Keep-style tools, infinite pages, pictures, and a writing
mode that takes you to the next line when you reach the end of one.

**Requires macOS 14 Sonoma or later and a trackpad.** Built for Apple silicon and Intel (Intel is untested).

## Install

- **From Scrawl 0.1.5.2 or later:** Scrawl › Check for Updates…, then **Download and Install**.
- **Otherwise:** download `Scrawl-0.1.6.1.dmg` below, open it, and drag **Scrawl** into **Applications** (replace
  the old copy). This build isn't notarized by Apple, so macOS asks before the first open:
  - **macOS 14:** Control-click the app in Applications, choose **Open**, then **Open** again.
  - **macOS 15 and later:** open it once, then go to **System Settings › Privacy & Security**,
    click **Open Anyway** next to "Scrawl was blocked", and confirm.

## What's fixed in 0.1.6.1

- **Clicking Draw or a tool no longer leaves a mark.** The finger that clicked is ignored until it lifts, so it no
  longer draws a dot (or erases under it, with the Eraser). With click to draw on, a resting finger still aims.
- **Two-finger pans no longer zoom.** A two-finger gesture is a pan or a pinch, decided once until you lift.
- **Draw mode never starts behind the pages overview.** ⌃⌥D there closes the overview first.
- **The "next line coming" arrow is always right**, and Esc or G stop the page moving after you've left.
- **Undo, then redo, of a line's last word** brings the next line again.
- **The overview never shows a deleted page's picture on a new page.**
- **Updates:** closing the update sheet when it's ready removes the downloaded copy; Check for Updates never opens
  a second sheet.

Scrawl sends anonymous usage counts (never your ink, pages or text); **Settings › Share anonymous usage counts**
turns them off. [What's counted](https://github.com/KarthikRaju391/scrawl/blob/main/docs/analytics.md).

Full list: [CHANGELOG.md](https://github.com/KarthikRaju391/scrawl/blob/main/CHANGELOG.md).
