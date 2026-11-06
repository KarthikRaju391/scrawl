------------------------------ MODULE WritingMode ------------------------------
(* Writing mode's next-line timing: when a move is scheduled, when it fires, what cancels it (properties
   P1, P7, P8 of bench/writingVerify.swift). Time is in ticks of 50 ms; the wait is Wait ticks (4 = 200 ms, 8 = 400 ms, 20 = 1000 ms). The line's
   geometry (is the line full, is it held) is abstracted to a nondeterministic choice at each commit: the Swift model
   checker (bench/writingVerify.swift) covers it with the real WritingLayout.

   CanvasView code paths: TouchDown/Lift/Frame = handle() (countedContacts, cancelPendingMove, commit in endStroke);
   Tick = advanceClock(); EdgeDown/EdgeUp = contacts the edge guard ignores; Arrow = panByArrow; Scroll = scrollWheel /
   magnify outside draw mode; EndLine = undo, Return, page change, writing mode off, width change. *)
EXTENDS Naturals

CONSTANTS Wait,            \* ticks
          ScrollCancels    \* TRUE: scroll/magnify drop a waiting move (this branch); FALSE: main before the fix

VARIABLES fingers,    \* counted fingers on the pad (0..2)
          seen,       \* countedContacts: what the canvas last saw (frames are only handled in draw mode)
          edge,       \* a contact that touched down in the edge band
          drawMode,
          drawing,    \* the first finger is drawing a stroke
          pending,    \* a next-line move is waiting
          age,        \* ticks since the lift that scheduled it (saturates at Wait)
          downSince,  \* monitor: a counted touch-down since that lift
          handSince,  \* monitor: the view was moved by hand since that lift
          fired       \* monitor: the last step was an automatic move

\* What a frame with a counted finger down does to a waiting move (handle(): cancelPendingMove).
Cancel(p) == FALSE
\* What an edge-band contact touching down does to it (nothing: the edge guard).
EdgeEffect(p) == p

vars == <<fingers, seen, edge, drawMode, drawing, pending, age, downSince, handSince, fired>>

Init == fingers = 0 /\ seen = 0 /\ edge = 0 /\ drawMode = TRUE /\ drawing = FALSE /\ pending = FALSE
        /\ age = 0 /\ downSince = FALSE /\ handSince = FALSE /\ fired = FALSE

\* A counted finger touches down. In draw mode its frame cancels a waiting move; the first finger draws.
TouchDown == /\ fingers < 2
             /\ fingers' = fingers + 1
             /\ IF drawMode THEN /\ seen' = fingers + 1 /\ pending' = FALSE
                                 \* A second finger turns a stroke into a pan or pinch, unless it comes late in a long stroke.
                                 /\ \E late \in BOOLEAN : drawing' = IF fingers = 0 THEN TRUE ELSE (drawing /\ late)
                            ELSE UNCHANGED <<seen, pending, drawing>>
             /\ downSince' = (downSince \/ drawMode) /\ fired' = FALSE   \* outside draw mode a touch isn't the canvas's
             /\ handSince' = (handSince \/ (drawMode /\ fingers = 1))   \* a second finger in draw mode: a pan or pinch
             /\ UNCHANGED <<edge, drawMode, age>>

\* A finger lifts. If it's the drawing finger, the stroke commits: a move is scheduled if the line is full and not held
\* (chosen freely: the geometry is the Swift checker's job); the frame's cancel comes first, then the commit schedules,
\* so another finger still down cancels it at its next frame. Any other lift is a frame that cancels if a finger is
\* still down.
CommitLift == /\ drawMode /\ drawing
              /\ fingers' = fingers - 1 /\ seen' = fingers - 1 /\ drawing' = FALSE
              /\ \E full \in BOOLEAN : pending' = full
              /\ age' = 0 /\ downSince' = FALSE /\ handSince' = FALSE /\ fired' = FALSE
              /\ UNCHANGED <<edge, drawMode>>
OtherLift == /\ fingers > (IF drawing THEN 1 ELSE 0)
             /\ fingers' = fingers - 1
             /\ IF drawMode THEN /\ seen' = fingers - 1 /\ pending' = IF fingers > 1 THEN Cancel(pending) ELSE pending
                            ELSE UNCHANGED <<seen, pending>>
             /\ drawing' = (drawing /\ drawMode) /\ fired' = FALSE
             /\ UNCHANGED <<edge, drawMode, age, downSince, handSince>>
Lift == CommitLift \/ OtherLift

\* A sensor frame while counted fingers are down (125 a second): handle() cancels a waiting move.
Frame == /\ drawMode /\ fingers > 0
         /\ seen' = fingers /\ pending' = Cancel(pending) /\ fired' = FALSE
         /\ UNCHANGED <<fingers, edge, drawMode, drawing, age, downSince, handSince>>

\* A display tick: drainInput() then advanceClock(). While fingers are down in draw mode the sensor sends a frame every
\* 8 ms, so each tick handles at least one (seen, and its cancel) before the clock check.
Tick == LET framed == drawMode /\ fingers > 0
            p1 == IF framed THEN Cancel(pending) ELSE pending
            s1 == IF framed THEN fingers ELSE seen
        IN /\ age' = IF age < Wait THEN age + 1 ELSE Wait
           /\ seen' = s1
           /\ IF p1 /\ s1 = 0 /\ age' >= Wait
                THEN pending' = FALSE /\ fired' = TRUE
                ELSE pending' = p1 /\ fired' = FALSE
           /\ UNCHANGED <<fingers, edge, drawMode, drawing, downSince, handSince>>

\* A palm or thumb on the edge band: not counted.
\* (Their frames go through handle() like any other, so in draw mode they refresh the count.)
EdgeDown == edge = 0 /\ edge' = 1 /\ fired' = FALSE /\ seen' = (IF drawMode THEN fingers ELSE seen) /\ pending' = EdgeEffect(pending)
            /\ UNCHANGED <<fingers, drawMode, drawing, age, downSince, handSince>>
EdgeUp   == edge = 1 /\ edge' = 0 /\ fired' = FALSE /\ seen' = (IF drawMode THEN fingers ELSE seen)
            /\ UNCHANGED <<fingers, drawMode, drawing, pending, age, downSince, handSince>>

\* Esc / the draw-mode hotkey (fingers may be down: their frames stop being handled, `seen` goes stale).
\* Back into draw mode with fingers resting: the sensor keeps sending frames, and the next display tick handles one
\* before advanceClock, so they're seen (and cancel) before any tick.
\* The count is reset when draw mode changes (fingers that lift outside it are never seen to lift).
\* Leaving draw mode drops a waiting move (0.1.6.1: it used to fire 0.4 s later, behind the overview, with a haptic).
ToggleDraw == /\ drawMode' = ~drawMode /\ drawing' = FALSE /\ fired' = FALSE
              /\ IF ~drawMode /\ fingers > 0 THEN seen' = fingers /\ pending' = FALSE
                 ELSE /\ seen' = 0 /\ pending' = (pending /\ ~drawMode)
              /\ UNCHANGED <<fingers, edge, age, downSince, handSince>>

\* Arrow keys: panByArrow drops a waiting move.
Arrow == pending' = FALSE /\ handSince' = TRUE /\ fired' = FALSE
         /\ UNCHANGED <<fingers, seen, edge, drawMode, drawing, age, downSince>>

\* A two-finger scroll or a magnify outside draw mode.
Scroll == /\ ~drawMode
          /\ pending' = IF ScrollCancels THEN FALSE ELSE pending
          /\ handSince' = TRUE /\ fired' = FALSE
          /\ UNCHANGED <<fingers, seen, edge, drawMode, drawing, age, downSince>>

\* Undo, Return, a page change, writing mode off, a width change: endWritingLine / cancelPendingMove.
EndLine == pending' = FALSE /\ fired' = FALSE /\ UNCHANGED <<fingers, seen, edge, drawMode, drawing, age, downSince, handSince>>

Next == TouchDown \/ Lift \/ Frame \/ Tick \/ EdgeDown \/ EdgeUp \/ ToggleDraw \/ Arrow \/ Scroll \/ EndLine

\* The sensor sends frames while fingers are down in draw mode, and the display keeps ticking.
Spec == Init /\ [][Next]_vars /\ WF_vars(Tick) /\ WF_vars(Frame)

TypeOK == fingers \in 0..2 /\ seen \in 0..2 /\ edge \in 0..1 /\ age \in 0..Wait
          /\ drawMode \in BOOLEAN /\ drawing \in BOOLEAN /\ pending \in BOOLEAN

\* P1: an automatic move only after the wait, with no counted finger seen down, and no counted touch-down since the lift.
NeverMidWord == fired => (age >= Wait /\ seen = 0 /\ ~downSince)
\* P1: a counted touch-down in draw mode leaves nothing waiting.
TouchCancels == [][TouchDown /\ drawMode => ~pending']_vars
\* P7: edge contacts never cancel (or schedule) a move.
EdgeGuard == [][(EdgeDown \/ EdgeUp) => pending' = pending]_vars
\* P8a: nothing waits past its time with no finger seen down (it fires on that tick).
NotOverdue == (pending /\ seen = 0) => age < Wait
\* P8b: a move never fires after the view was moved by hand since its lift.
NoFireAfterHandMove == fired => ~handSince
\* P8 (liveness): a waiting move is always eventually done with (fired or dropped).
EventuallyDone == pending ~> ~pending
\* 0.1.6.1: a move never waits (or fires) outside draw mode.
OnlyInDrawMode == pending => drawMode
=============================================================================
