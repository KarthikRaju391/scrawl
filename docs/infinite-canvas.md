# The infinite canvas (after 0.1.6)

The page's column (1,600 units wide, endless downwards) is a guide now, not a limit.

## The view
- It pans past the column's sides and above its top, up to 2 page widths (`Camera.reach`), so you can't get lost.
- It zooms out to 25% (`Camera.minZoom`): four page widths across, about the most at which handwriting written at 100%
  can still be told apart. Zoom presets now include 25% and 50%. Zoom to Whole Page (⌘0) is still 100%.
- Paper is everywhere (the paper pattern too). Nothing marks the column on screen (0.1.7: no edge lines, no dashed
  screen-height lines; Karthik: "keep it simple").
- Ink and pictures can go anywhere. Exports and Copy as Image use paper everywhere (no desk). The "Page" area is the
  column (top to the lowest content), grown on any side where content goes past it. Tiles and the page map frame all
  the content; a page whose content stays inside the column looks exactly as before.

## Writing mode
- A block's lines are as long as the width setting (50 / 75 / 100%) of the **view's width when the block started**,
  measured from where its first stroke landed. Fixed for the block: zooming while you write it doesn't change it; the
  next block takes the zoom at that moment.
- The 95% cap and the 93% "near the page's edge" rule are gone. The only early trigger is ink within 3% of the line
  before its end.
- The limit line shows only as the ink nears it (within 15% of the line's length), as in 0.1.6.
- A line longer than the view (a block started near the view's right side, or a wide setting): once its ink is within
  12% of the view's right side, at the usual word-gap pause, the view slides right so the ink's end sits in the middle
  of the view, never past the line's end. The camera only: ink never moves, the line stays open.
- Next line: back to the block's start (which may be left of the page), one line down.
- `--column-bound` restores the rules before (for replaying old sessions side by side).

## Proof
- `checks/writing-verify.sh`: the model checker and the fuzzer of the real canvas check the new properties. P3: the
  limit is the block's start + the width of its starting view, through zooms. P4: the zone is 3% of that line. P9: the
  follow. The same checks fail on the old rule (P3, P4, model) and on a build without the follow (P9).
- `bench`: `blockWidthChecks` (WritingLayout unit checks) and the camera's reach and 25%.
- Karthik's 20 writing-mode sessions replayed under both rules: every session's first move differs. Mainly a next line
  comes after one view width instead of the page's width. Some blocks also start left of the page, because the view no
  longer stops at the page's edge. Later moves aren't comparable, since a replay feeds the same touches into a view that
  has diverged.
