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
- Back to page (`app/BackToPage.swift`): outside draw mode, a pill ("Back to page  ⇧⌘0", bottom right above the
  toolbar) shows once the view's centre is more than 20% of the view's width outside the column, or the view's top
  more than 10% of its height above the page's top; it hides only once back within 10% / 5% (no flicker while
  panning at the threshold). Below the ink isn't "away": the page goes on down. Never in draw mode or the overview.
  It and ⇧⌘0 slide the view back: the column centred, the zoom kept; above the page's top, its top at the view's top;
  with no ink or picture in view, to the nearest. ⌘0 (Actual Size (100%)) zooms to 100% about the view's centre.
- Pinching outside draw mode (magnify) zooms to 25% like draw mode's pinches; scrolling reaches the same places.
- The page map (top right) shows on any move you make yourself (pan, pinch, arrow keys, scrolling) at any zoom, 100%
  and below too (0.1.7; before, only zoomed in past 1.5x), framing all the content, and fades 1.2 s after the move.

## Writing mode
- A block's lines are as long as the width setting (50 / 75 / 100%) of the **screen's full width at 100%**, which is
  the page's width (1,600 units: the page fills the window's width at 100%), measured from where its first stroke
  landed. The same length on paper at every zoom: at 250% a 50% line is 1.25 screens, and the view follows it.
  (Karthik, 6 Nov: "It should not consider the viewport ... calculate the full screen width and then take the
  percentage off of it." The 0.1.6 drafts used the view's width when the block started, which made a 50% line at 250%
  half the screen; `WritingLayout.measureFromView` keeps that rule one switch away.)
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
  limit is the block's start + the setting x 1,600 units, through zooms. P4: the zone is 3% of that line. P9: the
  follow. The same checks fail on the old rule (P3, P4, model) and on a build without the follow (P9).
- `bench`: `blockWidthChecks` (WritingLayout unit checks), `lineWidthRuleChecks` (the real canvas: limit - start = the
  setting x 1,600 at 50-400% zoom; the same start at the screen's left edge, middle or right; through hand pans, follows
  and a pinch mid-block; a redo after the block ended; Karthik's 6 Nov block, which ends at -256, not -736), and the
  camera's reach and 25%. They fail on the 0.1.6 drafts' rule (6 of 7 cases) and without the redo fix.
- Karthik's 20 writing-mode sessions replayed under both rules: every session's first move differs. Mainly a next line
  comes after one view width instead of the page's width. Some blocks also start left of the page, because the view no
  longer stops at the page's edge. Later moves aren't comparable, since a replay feeds the same touches into a view that
  has diverged.
