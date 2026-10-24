# Page moves wait for a pause; aim first (test build, proven on Karthik's recordings)

## (1) No page move until the finger has been up 400 ms

Why 400 ms: Karthik's lift→touch gaps in 5 writing sessions (n=691): 77% under 300 ms (median
116 ms), almost nothing at 300–600 ms, a long tail past 600 ms. The page move (auto-pan or new line)
is decided at each lift but only runs after 400 ms with no touch; a touch cancels it and it's
re-decided at the next lift. The pan trigger moved from 85% to 70% of the view so the next word
starts with room (at 85%, words started near the edge ran off the pad, 1.04 of its width).

Proof: every recorded session (math + 5 writing) re-run through the app with a virtual clock
(`checks/cf_all.sh`, `tools/cf_compare.py`).
- Fidelity: replayed with the old behaviour, all six reproduce what happened: the same page-move
  counts (22/22, 36/36, 17/17, 0/0…) and stroke starts within p50 0.02–1.1 pt.
- New behaviour vs what happened:

| | original | new |
|---|---|---|
| strokes right after a mid-word page move | 24 | **0** |
| within-word pairs (< 300 ms) split by a page move | 24 / 988 | **0 / 988** (so mid-word letters still join exactly as written) |
| strokes Karthik undid that followed a mid-word move | 15 | **0 still exposed** |
| page moves | 75 | 60 (they wait for word breaks) |

- Undo rates in the recordings: no page move before the stroke 14% (n=1,416), a move after a pause
  42% (n=24), a move mid-word 62% (n=24). Modelled undos 225 → 215 (actual 225). Modelled, not
  observed: what Karthik would undo with the new behaviour needs a new session.
- What this doesn't fix: most undos (≈198 of 225) happen with no page move at all; and a move after
  a pause still costs (42%).

## (2) Aim first (A, or the ⚙︎ checkbox)

A light touch shows an orange aim ring and draws nothing; pressing past 15 starts the ink, with the
press ramp (the last ≤ 1.5 mm) filled in. From the recordings, writing normally with it on: strokes
that never press past 15: math 0.4%, writing 1.3% (dots: 3/67, 8/114); press reached only after
1.5 mm of movement: 1.3% / 0.9%. `checks/aim.sh`: aim-then-press starts at the press (aim path
ink-free), a quick press starts exactly at touch-down (fill-in; the test fails without it), a light
tap draws nothing, aim off inks a light stroke at once. Whether it helps math placement is untested
(needs Karthik).
