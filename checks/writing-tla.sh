#!/bin/bash
# TLC on docs/writing-mode.tla: the next-line timing for waits of 200, 400 and 1000 ms, on this branch (scroll and
# magnify drop a waiting move) and on main before the fix. Needs Java; TLA2TOOLS defaults to ~/.cache/tla/tla2tools.jar.
cd "$(dirname "$0")/.."
JAR=${TLA2TOOLS:-$HOME/.cache/tla/tla2tools.jar}
D=$(mktemp -d /tmp/wv-tla.XXXX); cp docs/writing-mode.tla "$D/WritingMode.tla"
for fix in TRUE FALSE; do for w in 4 8 20; do
  cat > "$D/WritingMode.cfg" <<CFG
SPECIFICATION Spec
CONSTANTS Wait = $w
          ScrollCancels = $fix
INVARIANTS TypeOK NeverMidWord NotOverdue NoFireAfterHandMove OnlyInDrawMode
PROPERTIES TouchCancels EdgeGuard EventuallyDone
CFG
  echo "== wait $((w * 50)) ms, scroll cancels: $fix"
  (cd "$D" && java -XX:+UseParallelGC -cp "$JAR" tlc2.TLC -workers 2 -deadlock -config WritingMode.cfg WritingMode.tla 2>&1) \
    > "$D/out.txt"
  grep -E "states generated|Model checking completed|No error|is violated|were violated" "$D/out.txt"
  grep -q "^State [0-9]*:" "$D/out.txt" && { echo "  counterexample (last states):"; grep -E "^State [0-9]+:" "$D/out.txt" | sed 's/ line.*//' | tail -6 | tr '\n' ' '; echo; }
done; done
# Mutants (wait 400 ms, this branch): each must break the property it targets.
echo "== mutants (wait 400 ms)"
while IFS='|' read -r name prop from to; do
  sed "s/$from/$to/" docs/writing-mode.tla > "$D/WritingMode.tla"
  cmp -s docs/writing-mode.tla "$D/WritingMode.tla" && { echo "  $name (targets $prop): PATTERN NOT FOUND"; continue; }
  printf 'SPECIFICATION Spec\nCONSTANTS Wait = 8\n          ScrollCancels = TRUE\nINVARIANTS TypeOK NeverMidWord NotOverdue NoFireAfterHandMove OnlyInDrawMode\nPROPERTIES TouchCancels EdgeGuard EventuallyDone\n' > "$D/WritingMode.cfg"
  res=$(cd "$D" && java -cp "$JAR" tlc2.TLC -workers 2 -deadlock -config WritingMode.cfg WritingMode.tla 2>&1 | grep -oE "Invariant [A-Za-z]+ is violated|Action property [A-Za-z]+ is violated|Temporal properties were violated|No error has been found" | head -1)
  echo "  $name (targets $prop): $res"
done <<'MUT'
halfWait|P1 NeverMidWord|age' >= Wait$|age' >= Wait \\div 2
touchKeeps|P1 TouchCancels|seen' = fingers + 1 \/\\ pending' = FALSE|seen' = fingers + 1 \/\\ pending' = pending
frameKeeps|P8a NotOverdue (a resting finger holds the move past its time)|^Cancel(p) == FALSE|Cancel(p) == p
edgeCancels|P7 EdgeGuard|^EdgeEffect(p) == p|EdgeEffect(p) == FALSE
neverFires|P8 EventuallyDone|IF p1 \/\\ s1 = 0 \/\\ age' >= Wait|IF p1 \/\\ s1 = 0 \/\\ age' > Wait
staleCount|P8 EventuallyDone (main before the fix)|ELSE \/\\ seen' = 0 \/\\ pending' = (pending \/\\ ~drawMode)|ELSE UNCHANGED <<seen, pending>>
exitKeeps|0.1.6.1 OnlyInDrawMode (Esc or G kept the move)|pending' = (pending \/\\ ~drawMode)|pending' = pending
scrollKeeps|P8b NoFireAfterHandMove; since 0.1.6.1 no error is right: no move waits outside draw mode, where scrolling is|pending' = IF ScrollCancels THEN FALSE ELSE pending|pending' = pending
MUT

rm -rf "$D"
