# Changelog

## 0.1.0 (unreleased, 2026-10-25)

Licensed under the MIT License.

First public release. Scrawl was called Trackpad Draw during development. On first launch it moves the
old pages and settings over.

### Drawing
- Finger drawing on the trackpad with pressure, from MultitouchSupport. The public macOS touch API is
  the fallback.
- Keep-style tools: pen, marker, highlighter, eraser, and none / square / dot / ruled backgrounds.
- Smoothing and Prediction sliders. Every stroke ends exactly where the finger lifts.
- The paper fills the whole window, at any window shape (tall beside another app, wide, full screen with
  the green button or ⌃⌘F). The trackpad maps without distortion to the largest trackpad-shaped area in
  the window, centred and outlined in draw mode. Pan to reach the paper around it.
- Return in writing mode starts the next line.
- The page's bounds are obvious. Anything off the page (beside it, above its top) is a plain grey desk with a
  shadowed page edge and no lines. In a tall window the page top sits at the window top.
- Edge guard: touches that start within 5% of the trackpad's edges are ignored, so a resting palm or
  thumb no longer draws, pans or zooms. The inner 90% covers the whole writing area. You can change it
  under ⚙︎ › Edge guard, and 0 turns it off.
- Every mode key toggles: D, W, L/Z on and off; M/H/E pressed again return to the pen; P on the pen
  goes back to the last other tool.

### Pages and writing
- Pages are infinite downwards, and each keeps its own view.
- Writing mode pans along the line and goes to the next line when it's full. It waits until the
  finger has been up 0.4 s, so the page never moves mid-word.
- Zoom lock.

### Reliability
- Pages, views and undo/redo history are saved automatically and survive a crash, kill -9 or quit.
- The pointer comes back however draw mode ends, including a crash, kill -9, display sleep,
  switching users or displays changing.
- Works with the built-in trackpad and Magic Trackpads, whichever one you touch.

### Release
- Export every page to one vector PDF, or the current page to PNG.
- First-run welcome, Help with every shortcut, About box, Check for Updates (GitHub releases).
- No network use except Check for Updates. Logs stay on this Mac.
- Universal app with the hardened runtime and no entitlements. Requires macOS 14 or later.

### Fixes
- Settings panel controls were invisible in dark mode.
