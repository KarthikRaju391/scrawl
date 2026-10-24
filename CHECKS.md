# Acceptance checks

Status as of 2026-10-24, after the end-to-end fixes. Without a finger, the app is now tested by
replaying Karthik's recorded strokes (`data/strokes-20261024-161939.jsonl`, 27 strokes) through
the same callback the trackpad driver calls, with the window in front and the cursor really locked
(`checks/e2e.sh`). Not covered: the sensor and driver before that callback, and macOS's resting-touch
flags, which need real touches.

## 1. OCR: ≥90% character accuracy on the zoomed-in sentences, using Vision

**Not measured.** Needs Karthik's handwriting. The script itself is validated: a synthetic page
in the Bradley Hand font scores 100%, and a one-word mismatch scores 93% as expected.

1. Open the app and press ⌃⌥D. At normal zoom (⌘0), write *The quick brown fox jumps over the
   lazy dog* 5 times. Press Esc, then ⇧⌘E to export `data/page-*.png`.
2. Clear the page (⌘⌫). Press ⌃⌥D, pinch to about 5× zoom (spreading two fingers about 5×
   apart), and write the sentence 5 times, panning with two fingers between lines. Press Esc,
   then ⇧⌘E.
3. Run on each export: `swiftc -O -o build/ocr_check checks/ocr_check.swift && ./build/ocr_check data/page-<time>.png`.
   It prints results with language correction off and on. The pass bar is ≥90% on the zoomed-in page.

## 2. Latency: finger to ink under ~50 ms on average, from 240 fps video

**Partly measured.** From input arrival at the app to the frame being presented on the display
(Metal `presentedTime`), in the replayed sessions: p50 21–26 ms, p95 30–33 ms, max 57 ms. Across
runs that's 220–907 samples, and 1018 of 1019 frames were presented. Two things aren't counted: the
trackpad's scan and driver time before the callback (input arrives every 8 ms), and the panel's
pixel response. Adding those, the total is plausibly near the ~50 ms target, but only the video
can show it. Per-frame logging: `python3 -I checks/latency_report.py data/strokes-*.jsonl`.

To film it:
1. Set the phone to slow-mo at 240 fps. Prop it so both the trackpad and the canvas are in frame,
   with the display bright and the room lit.
2. In draw mode, draw a fast straight stroke (about 3 cm in 0.2 s), then stop dead and hold.
   Do 10 strokes.
3. Step through the video frame by frame. For each stroke, count the frames from the one where
   the finger stops to the one where the ink stops growing.
4. Run `python3 -I checks/latency_report.py --frames <n1> <n2> ...`. Each frame is 4.17 ms.
   Prediction (`predictMs` 16) can overshoot slightly. If the ink "stops" before the finger,
   count 0, or rerun with `defaults write local.trackpad-draw predictMs 0` to measure without it.

## 3. Jitter: a finger held still for 2 s draws <1 px of spread at 100% zoom

**Modeled, not measured.** Phase 1 passive data had no still windows. In the model, Gaussian
sensor noise on a still finger (σ) goes through the app's filter at the default window size,
where 1 px ≈ 0.046 mm of finger travel:

| σ (mm) | raw spread (px) | drawn p50 (px) | drawn max (px) |
|---|---|---|---|
| 0.01 | 1.3 | 0.17 | 0.28 |
| 0.02 | 2.6 | 0.34 | 0.42 |
| 0.03 | 3.8 | 0.58 | 0.81 |
| 0.05 | 6.6 | 0.86 | 1.06 |
| 0.10 | 12.8 | 1.72 | 2.18 |

So the check passes if real sensor noise is ≲0.03–0.04 mm, and fails above that unless
`oneEuroMinCutoff` is lowered, which adds lag. Real finger tremor counts too. To measure: in
draw mode at ⌘0, touch one finger, hold it perfectly still for 3 s, and lift. Repeat 3×. Then
run `python3 -I checks/jitter_check.py data/strokes-*.jsonl`. The guided probe's `hold_still`
step also gives the raw sensor noise.

## 4. Kill mid-stroke: the system cursor keeps working

**Mostly measured.** With the cursor really locked mid-stroke, `kill -9`: the cursor reported
hidden while locked and visible right after the kill (`CGCursorIsVisible`), and the watchdog
logged `locked=true; re-associated mouse and showed cursor`. Not proven: that physical trackpad
movement moves the cursor again. Mouse/cursor association can't be read back, so that needs a
person.
Run `checks/kill_test.sh`. It launches the app, counts down while you press ⌃⌥D and draw, sends
SIGKILL, and asks whether the cursor works. The result goes to `data/checks.log`.

If the cursor is ever stuck: open the app and press ⌃⌥D twice.
