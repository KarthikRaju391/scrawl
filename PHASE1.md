# Phase 1: what the trackpad gives for stroke width

Machine: MacBook Pro Mac15,6 (M3 Pro 14"), macOS 26.6.2, built-in Force Touch trackpad
(MultitouchSupport family 0x6d, sensor grid 24×18, surface 124.8 × 76.8 mm).

## Measured so far (passive capture, 60 s of normal use, `data/passive-1.jsonl`)

Private `MultitouchSupport.framework`, loaded with dlopen from a plain CLI process. It needed
no Input Monitoring or Accessibility prompt. MTTouch stride is 96 bytes, which matches the
OpenMultitouchSupport layout.

| Signal | Not clicked (1,944 finger-samples) | Clicked (23) |
|---|---|---|
| `pressure` (per finger) | 0–123, p50 17, p95 40; **>0 in 97% of samples** | 55–140, p50 117 |
| `total` (contact capacitance ≈ size) | 0.12–0.83, p50 0.48 | 0.72–0.84 |
| `density` | 0.29–1.61, p50 1.12 | 1.29–1.37 |
| major / minor axis | 6.5–8.9 / 5.5–8.1 | ~8.2 / ~7.3 |

- **Pressure is per finger, and it works without a click.** In 216 multi-finger frames the
  fingers' pressure differed by p50 6 and up to 25 units in the same frame.
- Pressure moves with contact size (corr(pressure, total) = 0.70). So it's at least partly an
  area signal, not pure force. Pressing harder without clicking still has to show pressure
  rising while `total` stays flat. The guided run checks that.
- Speed tells you almost nothing about the other two (corr(speed, total) = −0.17,
  corr(speed, pressure) = −0.08), so speed would be a separate, synthetic width model.
- Frame rate: **~125 Hz** (8.0 ms between frames). That is the floor on input latency, and it's
  well under the 50 ms budget.
- Absolute position comes in mm (x ≈ −24…22, y ≈ 31…71 in this sample), which is good for the
  jitter check.

## Not measured yet (needs fingers: one-minute guided run)

- **Public NSEvent `pressure`/`stage`.** Apple documents it as one value per event, not per
  finger, delivered only between mouseDown and mouseUp (stage 1 = click, stage 2 = force click).
  It reaches only the window under the cursor, so passive capture can't see it.
  The guided run logs it next to MT data in steps `click_deep` and `press_noclick`.
- **Public NSTouch.** It has no pressure or size field at all: just normalizedPosition,
  isResting and deviceSize. The guided run records how much isResting catches a palm
  (`palm_plus_finger`).
- Whether MT `pressure` tracks force once contact size is held fixed (`press_noclick`,
  `two_fingers`), and fingertip vs flat finger (`flat_vs_tip`).
- Jitter of a still finger in mm (`hold_still`).

Run it (~1 min, keep the window in front, Space to start, Esc aborts):

    ~/code/trackpad-draw/probe/run-guided.sh

The script writes `data/guided-<time>.jsonl` and a summary `.txt`.

## Width model: preliminary recommendation

1. **MT per-finger `pressure`, no click needed (recommended, pending the guided run).** It's the
   only signal that's per finger, continuous and click-free. Map it through a smoothed curve
   and clamp it. Normalize `pressure / total` if the guided run shows that pressure is mostly
   area. Cost: private API, so personal use only, and it could break on a macOS update. Keep a
   speed fallback.
2. **Force-while-clicked (public NSEvent).** Drawing with the pad held down through a click is
   tiring and clicks fire haptics. You'd also get only one global value. Not recommended for
   drawing.
3. **Contact size (`total` / major axis).** Also private. Its range is narrow (major axis
   6.5–8.9) and it's already folded into `pressure`.
4. **Speed-based (public, perfect-freehand's `thinning`).** Always works and looks like ink,
   but the user doesn't control it. Use it as the fallback when MT isn't available.

The final pick depends on `press_noclick`: if pressure rises clearly while `total` stays flat,
go with 1. If not, the choice is between 1-as-contact-size and 4.
