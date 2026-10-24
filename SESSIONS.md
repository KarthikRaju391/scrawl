# Session recording (test build)

The test app (`build/Trackpad Draw Predict.app`) records every session it's used for, automatically:
`data/session-<time>.jsonl` next to the stroke log. It holds every trackpad frame in draw mode (125/s,
finger positions on the pad), every change of the visible page area with its cause (auto-pan, new
line, pinch, scroll, page), and every action (undo/redo/clear, stroke begin/commit/erase, tool and
mode changes). Only this app's own state: no screen capture. About 10 MB per 15 minutes.

- `build/replay <session> <strokes> <out> [--undos | --from s --to s]`: rebuilds what was on screen
  (page area, ink, the stroke in progress, a dot per finger, action labels) as PNG frames + mp4.
  Undo/redo/clear/eraser follow the app's own undo model; checked against scripted sessions.
- `tools/session_analysis.py <session> <strokes>`: per stroke, did the view change since the last lift
  (and why), did the finger land nearer where the previous ink now is (following the screen) or
  where it physically lifted (habit), and was the stroke undone. Checked on a simulated writer that
  follows the screen: after auto-pans it lands 5 mm from the ink vs 39 mm from the lift.
- `checks/session_report.sh`: both, for every recorded session.

To record: quit the main app (both use ⌃⌥D), open the test app, write as usual (with and without
auto-pan; undo whenever something lands wrong), quit. Then run `checks/session_report.sh`.
