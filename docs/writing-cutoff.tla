-------------------------------- MODULE WritingCutoff --------------------------------
\* The writing-mode cutoff state machine (docs/writing-cutoff-spec.md), for TLC. The implementation's rules (CanvasView's
\* endStroke / decideMove / applyMove / advanceClock / undo / redo / hand moves, WritingLayout.after) on an integer grid,
\* with the spec's own ghost variables (gm0: the measure the spec says the block has; quiet: the pause since the line
\* was due) and the last action's name (act) for the action properties. Mut selects a seeded bug (checks/writing-cutoff-tla.sh).
\*
\* Units: the page is W = 400 wide (1,600 in the app; every rule here is a ratio of it or of the view). Zooms 50, 100,
\* 250%: the view is Vw = W * 100 / zoom wide (800, 400, 160). A word is Vw/8 wide (handwriting is screen-sized). Rows
\* are lines, top to bottom (row - 1 is the next line). Time: Tick is half the wait (Wait = 2 ticks).
EXTENDS Integers, Sequences

CONSTANTS Rule,      \* "B" (the spec: the setting x the page width) or "A" (the setting x the view's width at the block's start)
          Mut,       \* "none" or a seeded bug (see Mutants below)
          MaxSteps   \* the bound: event sequences of at most this many events

W == 400
Nil == -1000000
Zooms == {50, 100, 250}
Widths == {50, 75, 100}
Wait == IF Mut = "wait0" THEN 0 ELSE 2
SpecWait == 2
NearMarker == IF Mut = "nearMarker0" THEN 0 ELSE 3      \* percent of the line
ShowWithin == 15                                        \* percent of the line
Vw(z) == (W * 100) \div z
Word(z) == Vw(z) \div 8
Gap(z) == Vw(z) \div 40
Abs(x) == IF x < 0 THEN -x ELSE x
\* The camera's reach (Camera.clamp): its centre at most 2 page widths past the page's right side, so the view's left edge at most this.
ReachCenter == 3 * W
ClampX(x, z) == IF x + Vw(z) \div 2 > ReachCenter THEN ReachCenter - Vw(z) \div 2 ELSE x
\* The proposed fix: the cutoff never past the furthest ink can go at any zoom (the reach + half the most zoomed-in view).
CapX == ReachCenter + (Vw(zoom) * 45) \div 100
Capped(x, b, bw) == IF Mut = "reachCap" /\ x > CapX THEN Max(CapX, b + bw \div 10) ELSE x
Max(a, b) == IF a > b THEN a ELSE b
Min(a, b) == IF a < b THEN a ELSE b

VARIABLES writing, w, zoom, camX, camRow,   \* the setting, the view (left edge, the row it shows for writing)
          bs, m0,                          \* the block's start and the measure the app keeps for it (blockViewWidth)
          lineL, lineR, lineRow, hist,     \* the open line: left, right ink, row; hist = its right after each stroke (undo)
          redo, held, prevL, prevR, prevRow, \* redo stack (rights), a held line (written on after its move), the line a move left
          pending, age, ftarget,           \* "none" | "nl" | "follow", ticks since its lift, the follow's target
          counted, edge, handPan,          \* a counted finger down, an edge contact down, hand moves since the last stroke
          gm0, quiet, dropped, act, moved, steps  \* ghosts: the spec's measure, the pause, what dropped the move, last action, its move

vars == <<writing, w, zoom, camX, camRow, bs, m0, lineL, lineR, lineRow, hist, redo, held, prevL, prevR, prevRow,
          pending, age, ftarget, counted, edge, handPan, gm0, quiet, dropped, act, moved, steps>>

V == Vw(zoom)
\* The measure a block starting now gets: the app's, and the spec's.
ImplMeasure == IF Rule = "A" \/ Mut = "visibleWidth" THEN V ELSE W
SpecMeasure == IF Rule = "A" THEN V ELSE W
\* The app's cutoff (lineLimitX / WritingLayout.lineEnd) and the spec's.
BW == (w * m0) \div 100
Cut == Capped(CASE Mut = "lineLeft" -> lineL + BW
                 [] Mut = "currentZoom" -> bs + (w * V) \div 100
                 [] OTHER -> bs + BW, bs, BW)
SBW == (w * gm0) \div 100
SCut == IF Mut = "reachCap" THEN Capped(bs + SBW, bs, SBW) ELSE bs + SBW   \* (the amendment, with the fix)
\* Due: the line's ink at or past cutoff - 3% of the line (scaled by 100: no fractions).
ImplDue == lineR # Nil /\ 100 * lineR >= 100 * Cut - NearMarker * BW
SpecDue == lineR # Nil /\ bs # Nil /\ 100 * lineR >= 100 * SCut - 3 * SBW
GuideShown == writing /\ bs # Nil /\ lineR # Nil /\ (Mut = "guideAlways" \/ 100 * (Cut - lineR) < ShowWithin * BW)
SpecGuide == writing /\ bs # Nil /\ lineR # Nil /\ 100 * (SCut - lineR) < ShowWithin * SBW

Init ==
    /\ writing = TRUE /\ w \in Widths /\ zoom \in Zooms
    /\ camX \in {-W - Vw(zoom) \div 2, 0, W - Vw(zoom) \div 2 + W \div 2, ReachCenter - Vw(zoom) \div 2}   \* left of the page, at its left, past its middle, at the reach
    /\ camRow = 0
    /\ bs = Nil /\ m0 = Nil /\ lineL = Nil /\ lineR = Nil /\ lineRow = 0 /\ hist = << >> /\ redo = << >>
    /\ held = FALSE /\ prevL = Nil /\ prevR = Nil /\ prevRow = 0
    /\ pending = "none" /\ age = 0 /\ ftarget = 0 /\ counted = 0 /\ edge = 0 /\ handPan = 0
    /\ gm0 = Nil /\ quiet = 0 /\ dropped = "" /\ act = "init" /\ moved = "" /\ steps = 0

\* ---- decideMove: after a commit or a redo (line ink in l, r on row; block start b; hold h) --------------------------------
\* Returns the pending move and the follow target as a record.
Decide(b, m, l, r, h, cx) ==
    LET bw == (w * m) \div 100
        cut == Capped(CASE Mut = "lineLeft" -> l + bw [] Mut = "currentZoom" -> b + (w * V) \div 100 [] OTHER -> b + bw, b, bw)
        due == 100 * r >= 100 * cut - NearMarker * bw
        tx == ClampX(Min(r - V \div 2, cut + V \div 20 - V), zoom)
        fol == 100 * r > 100 * (cx + V) - 12 * V /\ tx > cx
    IN IF h THEN [p |-> "none", t |-> 0]
       ELSE IF due THEN [p |-> "nl", t |-> 0]
       ELSE IF fol THEN [p |-> "follow", t |-> tx]
       ELSE [p |-> "none", t |-> 0]

\* ---- a stroke from x0 to x1 on row y, committed at its lift (endStroke, writing mode) --------------------------------------
Commit(x0, x1, y, name) ==
    LET cont == lineR = Nil /\ prevR # Nil /\ y = prevRow /\ x0 >= prevR - Gap(zoom)        \* finishing the line a move left
        L1 == IF cont THEN prevL ELSE lineL
        R1 == IF cont THEN prevR ELSE lineR
        Row1 == IF cont THEN prevRow ELSE lineRow
        H1 == IF cont THEN TRUE ELSE held
        wellOff == R1 # Nil /\ (Abs(y - Row1) >= 2 \/ (H1 /\ y < Row1))
        nextOfBlock == y < Row1 /\ Row1 - y <= 3 /\ bs # Nil /\ Abs(x0 - bs) * 10 < W
        R2 == IF wellOff THEN Nil ELSE R1
        L2 == IF wellOff THEN Nil ELSE L1
        H2 == IF wellOff THEN FALSE ELSE H1
        B2 == IF wellOff /\ ~nextOfBlock THEN Nil ELSE bs
        hand == IF cont THEN 0 ELSE handPan
        deliberate == hand * 10 >= V
        away == IF R2 # Nil THEN (x0 > R2 + Max(Gap(zoom) * 3, W \div 10) \/ x1 < L2 - Gap(zoom) * 3)
                ELSE (B2 = Nil \/ Abs(x0 - B2) * 10 > W)
        B3 == IF deliberate /\ away THEN x0 ELSE B2
        R3 == IF deliberate /\ away /\ R2 # Nil THEN Nil ELSE R2
        L3 == IF deliberate /\ away /\ R2 # Nil THEN Nil ELSE L2
        B4 == IF B3 = Nil THEN x0 ELSE B3
        fresh == B4 # bs \/ (wellOff /\ ~nextOfBlock)
        M4 == IF fresh THEN (IF Mut = "viewport" THEN (camX + V) - B4 ELSE ImplMeasure) ELSE m0
        G4 == IF fresh THEN SpecMeasure ELSE gm0
        Lf == IF R3 = Nil THEN x0 ELSE Min(L3, x0)
        Rf == IF R3 = Nil THEN x1 ELSE Max(R3, x1)
        Hist == IF R3 = Nil THEN << Rf >> ELSE Append(IF cont THEN << R1 >> ELSE hist, Rf)
        d == Decide(B4, M4, Lf, Rf, H2, camX)
    IN /\ writing /\ counted = 0
       /\ x0 >= camX /\ x0 < camX + V /\ x1 > x0 /\ x1 <= camX + V + V \div 20        \* starts in view; may run into the edge band
       /\ bs' = B4 /\ m0' = M4 /\ gm0' = G4
       /\ lineL' = Lf /\ lineR' = Rf /\ lineRow' = (IF R3 = Nil THEN y ELSE Row1) /\ hist' = Hist /\ redo' = << >>
       /\ held' = H2 /\ prevR' = IF wellOff \/ (lineR = Nil /\ ~cont) THEN Nil ELSE prevR
       /\ UNCHANGED <<prevL, prevRow>>
       /\ handPan' = 0
       /\ IF Mut = "wait0" /\ d.p = "nl"
          THEN \* the move at once, at the lift (no pause)
               /\ pending' = "none" /\ age' = 0 /\ ftarget' = 0 /\ moved' = "nl"
               /\ camX' = B4 - V \div 20 /\ camRow' = Row1 - 1
          ELSE /\ pending' = d.p /\ age' = 0 /\ ftarget' = d.t /\ moved' = "" /\ UNCHANGED <<camX, camRow>>
       /\ quiet' = 0 /\ dropped' = "" /\ act' = name
       /\ UNCHANGED <<writing, w, zoom, counted, edge>>

Write(f) == \* a word at f% across the view, on the row the view shows
    Commit(camX + (f * V) \div 100, camX + (f * V) \div 100 + Word(zoom), camRow, "write")
WriteNext == lineR # Nil /\ Commit(lineR + Gap(zoom), lineR + Gap(zoom) + Word(zoom), lineRow, "write")
\* Aimed at the guide: ending just short of the marker, in it, across the cutoff (the spec's cutoff: where the guide should be).
WriteTo(kind) == lineR # Nil /\ bs # Nil /\
    LET x1 == CASE kind = "short" -> (100 * SCut - 3 * SBW) \div 100 - 1
                [] kind = "zone"  -> SCut - 1
                [] OTHER          -> SCut + Word(zoom) \div 2
        x0 == Max(lineR + Gap(zoom), x1 - Word(zoom))
    IN x1 > x0 /\ Commit(x0, x1, lineRow, "write")
IDot == lineR # Nil /\ Commit(lineL, lineL + 1, lineRow, "write")                     \* inside the line: its right unchanged
WriteNextLine == bs # Nil /\ Commit(bs, bs + Word(zoom), camRow, "write")           \* where the view is after a move
WritePrevEnd == prevR # Nil /\ Commit(prevR + Gap(zoom), prevR + Gap(zoom) + Word(zoom), prevRow, "write")
WriteAbove == bs # Nil /\ Commit(bs, bs + Word(zoom), lineRow + 3, "write")

\* ---- the clock: advanceClock ---------------------------------------------------------------------------------------------
Tick ==
    /\ act' = "tick"
    /\ LET a == Min(age + 1, SpecWait + 1)
           fire == pending # "none" /\ counted = 0 /\ a >= Wait
       IN /\ age' = (IF pending = "none" THEN 0 ELSE a)
          /\ IF fire /\ pending = "nl"
             THEN /\ prevL' = lineL /\ prevR' = lineR /\ prevRow' = lineRow /\ lineR' = Nil /\ lineL' = Nil /\ hist' = << >> /\ held' = FALSE /\ moved' = "nl"
                  /\ handPan' = 0 /\ camX' = bs - V \div 20 /\ camRow' = lineRow - 1 /\ pending' = "none"
                  /\ bs' = IF Mut = "appMoveReset" THEN Nil ELSE bs
                  /\ UNCHANGED <<lineRow, m0, ftarget, redo>>
             ELSE IF fire /\ pending = "follow"
             THEN /\ camX' = ftarget /\ handPan' = 0 /\ pending' = "none"
                  /\ m0' = (IF Mut = "followRemeasure" THEN (ftarget + V) - bs ELSE m0) /\ moved' = "follow"
                  /\ UNCHANGED <<prevL, prevR, prevRow, lineR, lineL, hist, held, camRow, bs, lineRow, ftarget, redo>>
             ELSE /\ moved' = "" /\ UNCHANGED <<prevL, prevR, prevRow, lineR, lineL, hist, held, handPan, camX, camRow, pending, bs, m0, lineRow, ftarget, redo>>
    /\ quiet' = IF counted = 0 THEN Min(quiet + 1, SpecWait + 1) ELSE 0
    /\ UNCHANGED <<writing, w, zoom, counted, edge, gm0, dropped>>

\* ---- contacts ------------------------------------------------------------------------------------------------------------
Cancel(why) == /\ pending' = "none" /\ age' = 0
               /\ dropped' = IF pending # "none" THEN why ELSE dropped
TouchDown == counted = 0 /\ counted' = 1 /\ Cancel("touch") /\ quiet' = 0 /\ act' = "down"   \* a tap, a dot that won't ink
             /\ UNCHANGED <<writing, w, zoom, camX, camRow, bs, m0, lineL, lineR, lineRow, hist, redo, held, prevL, prevR, prevRow, ftarget, edge, handPan, gm0>> /\ moved' = ""
TouchUp == counted = 1 /\ counted' = 0 /\ quiet' = 0 /\ act' = "up"
           /\ UNCHANGED <<writing, w, zoom, camX, camRow, bs, m0, lineL, lineR, lineRow, hist, redo, held, prevL, prevR, prevRow, pending, age, ftarget, edge, handPan, gm0, dropped>> /\ moved' = ""
EdgeDown == edge = 0 /\ edge' = 1 /\ act' = "edge"
            /\ (IF Mut = "palmCancels" THEN Cancel("edge") ELSE UNCHANGED <<pending, age, dropped>>)
            /\ UNCHANGED <<writing, w, zoom, camX, camRow, bs, m0, lineL, lineR, lineRow, hist, redo, held, prevL, prevR, prevRow, ftarget, counted, handPan, gm0, quiet>> /\ moved' = ""
EdgeUp == edge = 1 /\ edge' = 0 /\ act' = "edge"
          /\ UNCHANGED <<writing, w, zoom, camX, camRow, bs, m0, lineL, lineR, lineRow, hist, redo, held, prevL, prevR, prevRow, pending, age, ftarget, counted, handPan, gm0, quiet, dropped>> /\ moved' = ""

\* ---- hand moves of the view ----------------------------------------------------------------------------------------------
Pan(d) == \* two fingers (counted): d% of the view sideways
    /\ counted = 0 /\ Cancel("hand") /\ quiet' = 0 /\ act' = "hand"
    /\ camX' = ClampX(camX + (d * V) \div 100, zoom) /\ handPan' = handPan + Abs(ClampX(camX + (d * V) \div 100, zoom) - camX)
    /\ m0' = IF Mut = "panMeasure" /\ bs # Nil THEN V ELSE m0
    /\ UNCHANGED <<writing, w, zoom, camRow, bs, lineL, lineR, lineRow, hist, redo, held, prevL, prevR, prevRow, ftarget, counted, edge, gm0>> /\ moved' = ""
Pinch(z) == \* two fingers (counted): to zoom z about the view's middle
    /\ counted = 0 /\ z # zoom /\ Cancel("hand") /\ quiet' = 0 /\ act' = "hand"
    /\ zoom' = z /\ camX' = ClampX(camX + V \div 2 - Vw(z) \div 2, z)
    /\ m0' = IF Mut \in {"zoomRemeasure", "panMeasure"} /\ bs # Nil THEN Vw(z) ELSE m0
    /\ UNCHANGED <<writing, w, camRow, bs, lineL, lineR, lineRow, hist, redo, held, prevL, prevR, prevRow, ftarget, counted, edge, handPan, gm0>> /\ moved' = ""
Arrow == \* → (not a touch): 10% of the view
    /\ counted = 0 /\ Cancel("hand") /\ act' = "hand"
    /\ camX' = ClampX(camX + V \div 10, zoom) /\ handPan' = handPan + Abs(ClampX(camX + V \div 10, zoom) - camX)
    /\ quiet' = 0 /\ moved' = ""
    /\ UNCHANGED <<writing, w, zoom, camRow, bs, m0, lineL, lineR, lineRow, hist, redo, held, prevL, prevR, prevRow, ftarget, counted, edge, gm0>>

\* ---- commands ------------------------------------------------------------------------------------------------------------
Undo == \* the line's last stroke goes (or an earlier line's: the line is then empty); the block stays; no move is decided
    /\ counted = 0 /\ writing /\ Cancel("undo") /\ act' = "undo"
    /\ IF Len(hist) > 0
       THEN /\ hist' = SubSeq(hist, 1, Len(hist) - 1) /\ redo' = Append(redo, hist[Len(hist)])
            /\ lineR' = IF Len(hist) > 1 THEN hist[Len(hist) - 1] ELSE Nil
            /\ lineL' = IF Len(hist) > 1 THEN lineL ELSE Nil
       ELSE UNCHANGED <<hist, redo, lineR, lineL>>
    /\ held' = FALSE /\ prevR' = Nil /\ handPan' = 0 /\ quiet' = 0 /\ moved' = ""
    /\ UNCHANGED <<writing, w, zoom, camX, camRow, bs, m0, lineRow, prevL, prevRow, ftarget, counted, edge, gm0>>
Redo == \* the stroke comes back onto the line, and the move is decided again (a block starts at it if there is none)
    /\ counted = 0 /\ writing /\ Len(redo) > 0 /\ act' = "redo"
    /\ LET r == redo[Len(redo)]
           R == IF lineR = Nil THEN r ELSE Max(lineR, r)
           L == IF lineL = Nil THEN r - Word(zoom) ELSE lineL
           B == IF bs = Nil THEN L ELSE bs
           M == IF bs = Nil THEN ImplMeasure ELSE m0
           G == IF bs = Nil THEN SpecMeasure ELSE gm0
           d == Decide(B, M, L, R, held, camX)
       IN /\ redo' = SubSeq(redo, 1, Len(redo) - 1) /\ hist' = Append(hist, R) /\ lineR' = R /\ lineL' = L
          /\ bs' = B /\ m0' = M /\ gm0' = G
          /\ pending' = d.p /\ age' = 0 /\ ftarget' = d.t
    /\ quiet' = 0 /\ dropped' = "" /\ moved' = ""
    /\ UNCHANGED <<writing, w, zoom, camX, camRow, lineRow, held, prevL, prevR, prevRow, counted, edge, handPan>>
Ret == \* Return: the next line now
    /\ counted = 0 /\ writing /\ act' = "ret" /\ pending' = "none" /\ age' = 0
    /\ prevL' = lineL /\ prevR' = lineR /\ prevRow' = lineRow /\ lineR' = Nil /\ lineL' = Nil /\ hist' = << >> /\ held' = FALSE /\ handPan' = 0
    /\ moved' = "ret" /\ quiet' = 0
    /\ camX' = (IF bs = Nil THEN W \div 33 ELSE bs) - V \div 20 /\ camRow' = lineRow - 1
    /\ UNCHANGED <<writing, w, zoom, bs, m0, lineRow, redo, ftarget, counted, edge, gm0, dropped>>
EndBlock(name, on) == \* endWritingLine(): the block, the line, the move
    /\ counted = 0 /\ act' = name /\ writing' = on
    /\ bs' = Nil /\ m0' = Nil /\ gm0' = Nil /\ lineR' = Nil /\ lineL' = Nil /\ hist' = << >> /\ held' = FALSE
    /\ prevR' = Nil /\ pending' = "none" /\ age' = 0 /\ handPan' = 0 /\ quiet' = 0 /\ dropped' = "" /\ moved' = ""
    /\ UNCHANGED <<w, zoom, camX, camRow, lineRow, redo, prevL, prevRow, ftarget, counted, edge>>
Page == writing /\ EndBlock("page", TRUE)
Toggle == EndBlock("toggle", ~writing)
SetWidth(v) == \* the setting: the block stays; a waiting move is dropped (re-decided at the next lift)
    /\ counted = 0 /\ v # w /\ w' = v /\ Cancel("width") /\ act' = "width" /\ quiet' = 0 /\ moved' = ""
    /\ UNCHANGED <<writing, zoom, camX, camRow, bs, m0, lineL, lineR, lineRow, hist, redo, held, prevL, prevR, prevRow, ftarget, counted, edge, handPan, gm0>>

Next ==
    /\ steps < MaxSteps /\ steps' = steps + 1
    /\ \/ \E f \in {5, 50, 90} : Write(f)
       \/ WriteNext \/ WriteTo("short") \/ WriteTo("zone") \/ WriteTo("cross") \/ IDot
       \/ WriteNextLine \/ WritePrevEnd \/ WriteAbove
       \/ Tick \/ TouchDown \/ TouchUp \/ EdgeDown \/ EdgeUp
       \/ Pan(30) \/ Pan(-30) \/ \E z \in Zooms : Pinch(z) \/ Arrow
       \/ Undo \/ Redo \/ Ret \/ Page \/ Toggle \/ \E v \in Widths : SetWidth(v)

Spec == Init /\ [][Next]_vars

\* ---- properties (docs/writing-cutoff-spec.md) ------------------------------------------------------------------------------
TypeOK == pending \in {"none", "nl", "follow"} /\ counted \in {0, 1} /\ edge \in {0, 1}
\* P1: the cutoff is the block's start + the setting x the spec's measure (the page width; rule A: the view's width when the block started).
P1 == writing /\ bs # Nil => Cut = SCut
\* P1 (stability): within a block, with the setting unchanged, nothing moves the cutoff (pans, zooms, follows, moves, undo, the guide).
P1Stable == [][(writing /\ writing' /\ bs # Nil /\ bs' = bs /\ w' = w /\ ~(act' = "write" /\ gm0' # gm0) /\ ~(Mut = "reachCap" /\ zoom' # zoom)) => Cut' = Cut]_vars
\* P2: the cutoff relative to the start is the setting x the measure, whatever the camera: no camX in it.
\* (With the reach fix, the amendment: never past CapX.)
P2 == writing /\ bs # Nil => Cut - bs = Capped(bs + (w * (IF Rule = "B" THEN W ELSE gm0)) \div 100, bs, (w * (IF Rule = "B" THEN W ELSE gm0)) \div 100) - bs
\* P3: the block's start changes only by a stroke (first of a block, written well off the line, or after a deliberate hand
\* move away), writing mode, a page change, or a redo with no block; never by a tick (the app's moves), Return, a pan, undo.
P3 == [][bs' # bs => act' \in {"write", "page", "toggle"} \/ (act' = "redo" /\ bs = Nil)]_vars
\* P4: at a commit or redo, the next line is pending iff the line's ink is past the spec's marker (not on a held line);
\* a counted touch cancels; a move happens only on a tick, at least the wait after its lift, with no finger down; it goes
\* to the block's start (at 5% of the view) and one line down.
P4Sched == [][(act' \in {"write", "redo"} /\ writing' /\ ~held' /\ moved' = "") => (pending' = "nl" <=> SpecDue')]_vars
P4Cancel == [][(counted' > counted) => pending' = "none"]_vars
P4Fire == [][(moved' \in {"nl", "follow"}) => (act' = "tick" /\ age >= SpecWait - 1 /\ counted = 0)]_vars
P4Target == [][(moved' = "nl") => (camX' = bs - V \div 20 /\ camRow' = lineRow - 1)]_vars
P4 == P4Sched /\ P4Cancel /\ P4Fire /\ P4Target
\* P5: ink past the marker and a pause of the wait with no counted contact: the move has come (the line is closed).
P5 == ~(writing /\ SpecDue /\ counted = 0 /\ quiet >= SpecWait)
\* P5 except what is decided (DECISIONS: a held line gets no automatic move; a hand move drops a waiting move).
P5Decided == ~(writing /\ SpecDue /\ counted = 0 /\ quiet >= SpecWait /\ ~held /\ dropped # "hand")
\* P5 by what blocked the move (one invariant each, so TLC reports every cause): a held line; a move dropped by a hand
\* move, a touch that didn't ink, an undo, the setting; or a due line never scheduled ("").
P5Stuck(c) == writing /\ SpecDue /\ counted = 0 /\ quiet >= SpecWait /\ (IF c = "held" THEN held ELSE ~held /\ dropped = c)
P5held == ~P5Stuck("held")
P5hand == ~P5Stuck("hand")
P5touch == ~P5Stuck("touch")
P5undo == ~P5Stuck("undo")
P5width == ~P5Stuck("width")
P5never == ~P5Stuck("")
\* P8 (reach): the marker is somewhere ink can get to: at most the right edge of the view at its reach, at this zoom, plus the
\* edge band a stroke may run into. If not, no stroke can ever be due and no next line comes (a wedge).
P8Reach == writing /\ bs # Nil => 100 * Cut - 3 * BW <= 100 * (ReachCenter + V \div 2 + V \div 20)
\* P6: the guide shows iff the ink is within 15% of the line of the cutoff; it's at the cutoff; hidden after the move.
P6 == (GuideShown <=> SpecGuide) /\ (GuideShown => Cut = SCut)
\* P7: an edge contact never cancels or delays a waiting move.
P7 == [][(act' = "edge") => (pending' = pending /\ age' = age)]_vars
\* P8: nothing is pending past its time with no finger down; writing mode off leaves nothing behind.
P8 == /\ (pending # "none" /\ counted = 0 => age < SpecWait)
      /\ (~writing => bs = Nil /\ lineR = Nil /\ pending = "none" /\ prevR = Nil /\ ~held /\ ~GuideShown)
=========================================================================================================================
