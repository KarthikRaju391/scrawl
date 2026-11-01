| mutant | targets | change | model checker (depth 4, waits 200/400/1000) | real canvas (fuzz 300x40, targeted) | differential (app mutated, model not) |
|---|---|---|---|---|---|
| `baseline` | all | main before the fixes | P4, P6, P8b | P4, P6, P8b, arrow, slide, staleCount | caught |
| `wait0` | P1 | no wait: the move comes at the lift | P1, P4, P5 | P1, slide, staleCount | caught |
| `halfWait` | P1 | the move comes after half the wait | P1 | P1 | caught |
| `touchKeeps` | P1 | a touch-down doesn't cancel the waiting move | P1, P5, P8b | P1, P4, P8b | caught |
| `inkMoves` | P2 | a move carries the last stroke down (the old 'move the crossing word' rule) | P2 | P2 | caught |
| `rightCap97` | P3 | rightCap 0.97 | P3 | P3 | - |
| `limitFromEdge` | P3 | the limit counts from the page's edge, not the block's start | P3, P4 | P3 | - |
| `nearMarker0` | P4 | nearMarker 0 (only a crossing brings the next line) | P4, P8c | P4 | - |
| `noNearEdge` | P4 | no 93% rule when the limit is at the page's edge | P4, P8c | P4 | - |
| `idotCancels` | P4 | only the last stroke's end counts (an i-dot cancels the move) | P4 | P4 | - |
| `unclamped` | P5 | the unclamped target is remembered (29 Oct bug 2) | P5, P6 | P5 | caught |
| `toMargin` | P5 | the next line goes to the page's margin, not the block's start | P5 | P5 | caught |
| `noInset` | P5 | the block's start lands at the view's very left (no 5% inset) | P5 | P5 | - |
| `runNotReset` | P6 | the block start isn't reset by a page change or writing mode off | P6 | P6 | caught |
| `drift` | P6 | no '10% of the page from the block's start' guard (29 Oct bug 3: lines drifted) | P6 | P6 | caught |
| `ownMoveIsHand` | P6 | the app's own move counts as a hand move (handRef not updated) | P5, P6 | P5 | caught |
| `undoResets` | P6 | undo ends the block | P6 | P6 | caught |
| `edgeCancels` | P7 | an edge-band contact cancels the waiting move | P7 | P7 | caught |
| `edgeHolds` | P7 | an edge-band contact holds the move back | P8a, P8c | P8a | caught |
| `doubleWait` | P8a | the move comes after twice the wait (ms/s mix-up) | P8a | P8a, slide | caught |
| `staleKept` | P8b | ending the line (undo, page, writing off) keeps the waiting move | P4, P5, P8b | P4, P8b | caught |
| `heldForever` | P8c | a line you went back to finish stays held (no move ever after) | P8c | P8c | caught |
| `slideRace` | slide | goToPage / newPage don't finish the slide (the bug fixed here) | not caught | slide | - |
| `staleCount` | P8 | the touch count isn't reset when draw mode changes (TLC's counterexample) | not caught | staleCount | - |
| `heldAbsorbs` | P8c | a held line takes the line written under it (main) | P6 | not caught | - |
| `heldEmpty` | P8c | an emptied line stays held (this branch's first scratch-out fix) | not caught | not caught | - |
