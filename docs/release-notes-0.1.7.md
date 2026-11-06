Write and sketch with a finger on your Mac's trackpad: Keep-style tools, an infinite canvas around your pages,
pictures, and a writing mode that takes you to the next line when you reach the end of one.

**Requires macOS 14 Sonoma or later and a trackpad.** Built for Apple silicon and Intel (Intel is untested).

## Install

- **From Scrawl 0.1.5.2 or later:** Scrawl › Check for Updates…, then **Download and Install**.
- **Otherwise:** download `Scrawl-0.1.7.dmg` below, open it, and drag **Scrawl** into **Applications** (replace
  the old copy). This build isn't notarized by Apple, so macOS asks before the first open:
  - **macOS 14:** Control-click the app in Applications, choose **Open**, then **Open** again.
  - **macOS 15 and later:** open it once, then go to **System Settings › Privacy & Security**,
    click **Open Anyway** next to "Scrawl was blocked", and confirm.

## What's new in 0.1.7

- **Room around the page.** Pan past the page's sides and above its top, and zoom out to 25%. Write and put
  pictures anywhere. No lines mark the page's edges any more (nor the dashed screen-height lines): just paper.
- **Writing mode: lines measured from where you start.** A block's lines are the width you chose (50, 75 or 100%)
  of your screen's full width, measured from where you start writing, anywhere on the canvas. They're the same length
  at every zoom. The guide line fades in as you near a line's end, as before.
- **Long lines carry the view along.** When a line is longer than the screen, the view slides right at the next
  word gap as you reach its edge. Your writing never moves.
- **The page map shows whenever you pan or pinch**, at any zoom, and covers everything on the canvas.
- **Back to page.** Panned off the page? A small "Back to page" pill brings you back (or ⇧⌘0). ⌘0 is Actual Size
  (100%), where you are.
- Pinching outside draw mode zooms out to 25% too.
- Two- and three-finger double taps (undo / redo) work with a finger near the trackpad's edge.
- Exports, Copy as Image and the pages overview include everything on the canvas, beside the page too.

## Also fixed

- **Clicking Draw or a tool no longer leaves a mark.** The finger that clicked is ignored until it lifts, so it no
  longer draws a dot (or erases under it, with the Eraser). With click to draw on, a resting finger still aims.
- **Two-finger pans no longer zoom.** A two-finger gesture is a pan or a pinch, decided once until you lift.
- **Draw mode never starts behind the pages overview.** ⌃⌥D there closes the overview first.
- **The "next line coming" arrow is always right**, and Esc or G stop the page moving after you've left.
- **Undo, then redo, of a line's last word** brings the next line again.
- **The overview never shows a deleted page's picture on a new page.**
- **Updates:** closing the update sheet when it's ready removes the downloaded copy; Check for Updates never opens
  a second sheet.
- No more "NSLayoutConstraint" warning at launch (from the Select tool's bar).

## Older versions

Scrawl 0.1.6 and older open a 0.1.7 notebook as before. They show the page's column only, so writing beside the page
or above it isn't in view there, but it stays in the notebook.

Scrawl sends anonymous usage counts (never your ink, pages or text); **Settings › Share anonymous usage counts**
turns them off. [What's counted](https://github.com/KarthikRaju391/scrawl/blob/main/docs/analytics.md).

Full list: [CHANGELOG.md](https://github.com/KarthikRaju391/scrawl/blob/main/CHANGELOG.md).
