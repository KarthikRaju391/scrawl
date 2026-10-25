# Decisions

Calls made while building, one line each with the reason. Newest at the bottom of each section.

## Modes and toggles
- Every tool and mode input goes through one rule set (`ModeState.after`): keys, toolbar, menu and the hotkey can't disagree.
- A click on the active tool or the writing button toggles it; sizes, colours and writing settings moved to a chevron, right-click or Control-click, because a click that sometimes toggles and sometimes opens a panel was the reported bug.
- In draw mode, a tool or mode change shows a short note ("Eraser off · Pen"), because the toolbar is hidden there.
- Test runs never load the real app's tools: Karthik's copy was left on the eraser and broke the release check.

## Robot user
- Keys are real CGEvents posted to the app's process. Clicks go through AppKit inside the app, because macOS drops posted clicks to a background app, and system-wide clicks would take the pointer.
- The robot measures main-thread stalls, not presented frames: a window behind others gets no frames, and a stall is the frozen ink a user sees.
- ⌘-shortcuts are driven through the menu items: they don't reach a background app's menu.

## Scratch-out and undo scrub (W1)
- Shape is judged in pad millimetres (zoom-independent): at least 4 long legs, path/extent ≥ 3.2, ≥ 60 mm/s, ≥ 4 mm, net turning < 0.75 turns. With these, 0 of 6,056 recorded strokes erase anything and 96% of synthetic scratches are caught.
- Circling is excluded by net turning, because the one real false hit was a wheel drawn round and round over sketch ink.
- Pen and marker only: a highlighter zig-zag over text is highlighting.
- A scratch erases strokes it touches that lie mostly inside its area. The scratch itself is never kept. It's one undo step.
- Scrub arms when the second tap of a two-finger double tap is held still for 0.25 s, and starts only after a 4 mm sideways slide, because two recorded touches rested like that and then lifted. It steps every 7 mm; left = undo.
- The scrub follows the two fingers that held it: one lifting ends it, because a lift moved the midpoint 9.5 mm in a recorded session.
- Scratch-out ships on by default (the 0-false-erase bar is met); a Settings switch comes with the Settings window.

## Writing flow (W2)
- A pan keeps the last three words on screen if they fit in 60% of the view, else two, else one, and moves at most half the view: you can follow the jump and still read the end of your sentence.
- Centre mode still aims the line's end at mid-view, but keeping the words wins, so the end can sit a little right of the middle.
- A new line puts the next line 57.5% down the view (was 50%): with two lines written, both stay in view (the robot measured 1 before).
- A hand pan right (two fingers or →) with auto-pan on frees the current line from the line width until the next new line, because Karthik pans right on purpose to keep writing, and the old rule sent him back to the margin (the parked pan bug; the robot reproduced it and checks/pan.sh now passes).
- With No pan, a hand pan is how you move along, so the line width still applies (otherwise a No-pan line never wraps).
- The early new line at the page's end (at 70% of the view once the view reached the edge) is gone: the line ends at the page margin.
- Page map: top-right, 132 pt wide; shown when zoomed past 1.5x (in and out of draw mode); clicks and drags move the view outside draw mode only (draw mode freezes the pointer); renders on a background queue at most every 0.4 s and only after a stroke ends; fades to 35% while a finger is down; View › Page Map turns it off (saved).

## Resume (item 3)
- Draw mode glides (250 ms) to the end of the last stroke on the page, at the zoom it was written at, with the line 57.5% down and the word's end 40% across, so you can keep writing straight away.
- It only moves when the view is where draw mode ended or at the whole page (zoom ~1, "looking"); if you zoomed in somewhere else yourself, that's where you meant to write, so it stays.
- No 600 ms "finger here" pulse: the blue finger rings already show where a touch lands, and a pulse would flash on every draw start.
- After a relaunch the zoom the last stroke was written at isn't known, so it uses 3x (Karthik's median is 3.6x).
- Off in test modes (they check exact views); the robot turns it on.
