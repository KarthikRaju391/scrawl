# Rejoin snap: the "keyboard hit-target" idea for handwriting (test build)

Branch `predict`, worktree `~/code/trackpad-draw-predict`, app `build/Trackpad Draw Predict.app`
(own bundle id `local.trackpad-draw.predict`, own settings and `data/` folder; the main app is not touched).

## What the data says (Karthik's 5 sessions, 2026-10-24, `tools/landing_analysis.py`)

| Context (lift -> next touch-down) | n | dx (mm) | dy (mm) |
|---|---|---|---|
| continue (within 4 mm) | 125 | +0.54 ± 1.91 | −0.13 ± 1.95 |
| next letter/word ("other") | 469 | +1.04 ± 9.05 | +1.82 ± 3.33 |
| dot (stroke < 3 mm) | 227 | −2.42 ± 14.88 | +5.27 ± 9.54 |
| above/below (> 6 mm) | 447 | +1.49 ± 11.47 | +9.61 ± 10.73 |
| return (> 15% left) | 139 | −32.9 ± 17.6 | +8.6 ± 13.6 |

- No consistent offset worth correcting (+0.5 / −0.1 mm; per-session means vary by ~1 mm).
- Landing scatter ≈ 1.9 mm per axis (upper bound).
- The "where will the next stroke start" prior is only sharp in two places: a quick re-touch next to
  the lift (a rejoin), and the carriage return (already handled by writing mode). Everywhere else
  it's ±9–15 mm: too broad for a keyboard-style correction to help.

## What was tried (simulated hand with known intent, `checks/hand.sh`, 5 seeds)

Hershey cursive + print, mixed per word, cursive words often lifted and rejoined mid-word; every
touch-down lands with Karthik's scatter (1.9 mm, +0.5 mm drift). OCR vs the known text:

| Rule | mean OCR | per-seed change vs off |
|---|---|---|
| off | 42.8% | — |
| **snap to the lift if a touch-down is < 3.5 mm from it and < 250 ms after** | **48.1%** | +2.3 … +11.5 (all 5 better) |
| same, 2.5 mm | 46.2% | −4.6 … +13.8 |
| same, 5 mm | 48.1% | −2.3 … +12.6 |
| snap only if the new stroke continues the previous direction | 43.9% | dropped: at handwriting size a 1.5 mm direction window straddles loop turns |

Cost: print strokes that start within 3.5 mm of the previous lift get pulled onto it (relative
placement of in-word strokes 3.26 → 3.51 mm). Limits: the simulation's landing-error model and letter
size (5 mm at zoom 1) are assumptions; it says nothing about feel. The real test is the blind A/B.

## Blind A/B for Karthik

1. Quit the main app (both register ⌃⌥D). `defaults write local.trackpad-draw.predict rejoinMode ab`
2. Open `build/Trackpad Draw Predict.app` (each launch secretly picks snap on or off, logged only).
3. Write "The quick brown fox jumps over the lazy dog" 5 times, ⇧⌘E to export, quit. Repeat 4–6 launches.
4. `python3 -I checks/ab_score.py ~/code/trackpad-draw-predict/data`
Pass: OCR ≥ 5 points higher with snap on, fewer undos/erasers per 100 strokes, and Karthik prefers it.
