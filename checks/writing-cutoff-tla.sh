#!/bin/bash
# TLC on docs/writing-cutoff.tla (the cutoff spec, docs/writing-cutoff-spec.md): every property on the unmutated model,
# then each seeded bug against the property that targets it. Needs Java; TLA2TOOLS defaults to ~/.cache/tla/tla2tools.jar.
#   checks/writing-cutoff-tla.sh [MaxSteps=7] [Rule=B]
cd "$(dirname "$0")/.."
JAR=${TLA2TOOLS:-$HOME/.cache/tla/tla2tools.jar}
N=${1:-7}; RULE=${2:-B}
D=$(mktemp -d /tmp/wc-tla.XXXX); cp docs/writing-cutoff.tla "$D/WritingCutoff.tla"
run() {  # mut, invariants, properties
  printf 'SPECIFICATION Spec\nCONSTANTS Rule = "%s"\n          Mut = "%s"\n          MaxSteps = %s\nINVARIANTS TypeOK %s\nPROPERTIES %s\n' "$RULE" "$1" "$N" "$2" "$3" > "$D/WritingCutoff.cfg"
  (cd "$D" && java -XX:+UseParallelGC -Xmx6g -cp "$JAR" tlc2.TLC -workers ${WORKERS:-4} -deadlock -nowarning -config WritingCutoff.cfg WritingCutoff.tla 2>&1) > "$D/out-$1.txt"
}
summary() { grep -E "distinct states found|Error: Invariant|Error: Action property|is violated|Model checking completed|Error:" "$D/out-$1.txt" | grep -v "^Error: The behavior" | head -4 | tr '\n' ' '; echo; }
trace() { grep -E "^State [0-9]+:|^/\\\\ (act|bs|m0|gm0|zoom|camX|lineR|lineL|pending|age|held|quiet|dropped|counted|moved|w) " "$D/out-$1.txt" | tr '\n' ' ' | sed 's/State /\n    State /g' | head -${2:-20}; echo; }
echo "== rule $RULE, unmutated, MaxSteps $N: P1 P2 P5Decided P6 P8 (invariants), P1Stable P3 P4 P7 (action properties)"
run none "P1 P2 P5Decided P6 P8" "P1Stable P3 P4 P7"; summary none; grep -q "is violated" "$D/out-none.txt" && trace none 40
echo "== rule $RULE, unmutated: strict P5, one blocking cause at a time"
for c in held hand touch undo width never; do
  run none "P5$c" ""; mv "$D/out-none.txt" "$D/out-p5$c.txt"; printf '  P5%-6s ' $c; summary p5$c
  grep -q "is violated" "$D/out-p5$c.txt" && trace p5$c 12
done
echo "== mutants (MaxSteps $N): each against the property it targets"
while IFS='|' read -r mut inv prop what; do
  run "$mut" "$inv" "$prop"
  printf '  %-16s %-34s %s\n' "$mut" "($what)" "$(grep -oE "Invariant [A-Za-z0-9]+ is violated|Action property [A-Za-z0-9]+ is violated|No error has been found" "$D/out-$mut.txt" | head -1)"
done <<'MUT'
lineLeft|P1|P1Stable|limit from the line's left, not the block start
zoomRemeasure|P1|P1Stable|a pinch re-measures the block
followRemeasure|P1|P1Stable|a follow re-measures (to the new view's edge)
appMoveReset|P1|P3|the next-line move resets the block start
panMeasure|P1|P1Stable|the visible width taken after a hand pan/pinch
palmCancels|P1|P7|an edge contact cancels the move
nearMarker0|P1|P4|no near-marker zone
wait0|P1|P4|the move at the lift (no pause)
visibleWidth|P1 P2||the view's width when the block starts (rule A)
currentZoom|P1 P2||the view's width at the current zoom
viewport|P2||Karthik: the share of the view left of the start
guideAlways|P6||the guide shown whatever the ink
MUT
echo "(work dir $D)"
