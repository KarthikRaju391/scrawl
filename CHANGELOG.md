# Changelog

## 1.0.0 (unreleased, 2026-10-25)

First public release. Scrawl was called Trackpad Draw during development. On first launch it moves the
old pages and settings over.

### Drawing
- Finger drawing on the trackpad with pressure, from MultitouchSupport. The public macOS touch API is
  the fallback.
- Keep-style tools: pen, marker, highlighter, eraser, and none / square / dot / ruled backgrounds.
- Smoothing and Prediction sliders. Every stroke ends exactly where the finger lifts.
- Aim first (A): touch lightly to aim, press to ink.

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
