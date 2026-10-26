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

## Quiet draw mode (item 4)
- The draw-mode banner is a 4-5 word note ("Drawing · Esc to stop"), shown 2 s on entry and on a mode change. It used to stay up all session: it only faded when its text changed, and the text was set at launch while hidden (found by the robot; it's what the UX review saw in the recording).
- A small capsule at the bottom (where the toolbar sits outside draw mode) shows the tool with its colour, writing, zoom lock and page n/N; a 3 pt accent frame round the window marks draw mode. Robot: chrome over the page after 3 s fell from 10,880 to about 5,400 pt².
- The capsule doesn't expand on hover: the pointer is frozen in draw mode.

## Toolbar and Settings (item 5)
- Order: Draw (labelled, two buttons wide, blue) | pen, marker, highlighter, eraser, paper | writing, zoom lock | undo, redo | overview, ‹ › +. 14 buttons (was 15); the review aimed for ~10, but each remaining button is used and has a shortcut, so nothing else was cut.
- Writing and zoom lock stay two buttons rather than one segmented control: they toggle independently and both have their own key.
- The smoothing / prediction / edge-guard sliders moved to Settings (⌘,), with switches for scratch-out and the page map (tips and analytics join it later). Tests never save settings.
- Every button has a tooltip naming its shortcut (14/14; the paper button has no key).
- The capsule and the draw-mode frame never take clicks, and hide the moment draw mode ends: the capsule sat over the toolbar and swallowed a zoom-lock click (caught by checks/zoomlock.sh).

## Tips and the practice page (item 6)
- Five tips, each shown at most twice and only on a sign it's needed: every 3rd undo by ⌘Z/toolbar in draw mode (double tap and scrub), the first Return in writing mode (new lines are automatic), 3 pinches within a minute (L locks the zoom), the 2nd time the eraser is picked (scratch-out), 3 page changes by arrows (G). Using the gesture, the lock, scratch-out or the overview marks its tip as known, so it never shows.
- Tips show in the toast for 4 s; Settings › Tips turns them off.
- Practice page (Help › Practice Page, and a button in the welcome window): a new page, draw mode on, and a 4-line checklist (write your name, undo with a double tap, scratch out, G) that ticks itself; "Practice done" at the end. The page stays: it's ink you wrote.

## Feedback (item 7)
- Haptic tick (NSHapticFeedbackManager, .alignment) when a gesture undo or redo lands, at each scrub step, on a new line and on a scratch-out. It only reaches a Force Touch trackpad while a finger is on it, so a tap detected at lift may not be felt: that's on the hand-test list.
- While the page waits to move (the 400 ms pause), a faint chevron shows where it will go: at the right edge for a pan, low on the left for a new line. Any touch cancels the move and hides it.
- An undone or scratched-out stroke fades out over 120 ms instead of vanishing (drawn from its existing mesh with falling alpha; nothing extra while no fade is running).

## Overview: crop, titles, search, share (item 8)
- Thumbnails show the page's ink with a margin, in the tile's shape (at least a third of the page wide, so one dot isn't blown up); an empty page shows its top screen.
- Titles are the first handwritten line, read on this Mac with Vision on a background queue, only while the overview is open, once per page version; nothing is uploaded. Not editable yet: an editable title needs a place in the notebook file, and a misread title is better fixed by the next read than by a format change two days before release.
- OCR gets the ink with generous paper round it: cropped tight, Vision read "world" as "SIUM".
- ⌘F (Edit › Find in Pages) opens the overview with the search field focused; typing dims pages that don't match and selects the first match; Return opens it; Esc in an empty field leaves it, the next Esc closes the overview.
- Edit › Copy Page as Image (⌘C) and File › Share Page… (the system share menu with a PNG) act on the open page, or on the overview's selection. Tests copy to a private pasteboard, never yours.
- Not cut: OCR search shipped, it's cheap here because it runs only on overview pages.

## Usage counts (analytics)
- Provider (first pick, replaced): TelemetryDeck (privacy-first, EU-hosted, hashes user IDs, no IPs stored), spoken to directly over their v2 ingest API as their Swift SDK does it, so there's no dependency. Off until release.conf has TELEMETRY_APP_ID; it's empty, so this release sends nothing.
- record() is an append under an unfair lock (p99 0.67 µs on the main thread); a full queue (2,000) drops; batches go every 30 s on a utility queue; the local log is always written while it's on.
- At quit the last batch gets at most 0.5 s (quitting, never drawing); a slow network just loses it.
- Failed sends retry at 30 s, then 2, 4, 8, 16 min (capped at an hour), and are dropped after 6 tries; at most 5 batches wait.
- Props: allow-listed keys only, values only numbers, true/false or ≤ 32-character words: ink, text, search queries and file names can't get in by mistake.
- Notice: new users see it in the welcome window with a switch; people updating get a one-time sheet (Keep On / Turn Off). Settings has the switch; off clears the queue and stops writing and sending at once.
- Robot: the expected events land in the local log, nothing written ("secret") appears, and a session turned off writes nothing more. Timing unchanged: main-thread stalls 26 ms (25 before), ink jitter 0.59 pt (0.66 at the jitter fix).

## Release
- Still 0.1.0 (never published), build 2: everything here ships as the first public version; Karthik has build 1 installed, so the build number moves.

## Usage counts: PostHog (Karthik's pick, 2026-10-26)
- PostHog replaces TelemetryDeck as the remote sink. Same API in the app; only the sink and two release.conf keys changed (POSTHOG_PROJECT_TOKEN, POSTHOG_HOST).
- Spoken to directly over /batch/ the way posthog-ios sends it, so there's no SDK (and no autocapture, session replay or surveys).
- Anonymous events only: `$process_person_profile: false`, `$geoip_disable: true`, distinct_id = SHA-256 of the random install ID.
- EU Cloud by default (GDPR); "Discard client IP data" must be turned on in the project (a PostHog setting, not something the app can do).
- Checked against a local fixture server (checks/posthog.sh); real PostHog ingestion is unverified until a token exists.

## Delete page
- No confirm dialog: deleting shows "Page N deleted · ⌘Z to undo" for 3 s, and ⌘Z (or the toolbar's undo) puts the page back in its place, ink, view and history intact. Several deletes undo newest first.
- ⌘Z restores pages only while a delete was the last change: new ink, an erase, a scratch-out, Clear Page or a new page hands ⌘Z back to the ink (the deleted pages are let go then).
- Keys: Delete (or ⌦) on the overview's highlighted tile; Control-click / right-click a tile: Open, Delete Page; Edit › Delete Page is **⌥⌘⌫** (⌘⌫ was already Clear Page). It acts on the overview's selection, or the open page.
- Deleting the open page opens the next one (the previous one at the end); deleting the only page leaves one blank page.
- Deletes aren't kept across a relaunch for undo (the autosave writes the notebook without the page).

## Page map only when navigating
- Shown by view moves made by hand: two-finger pan and pinch, scrolling, magnify, arrow keys, and the map itself; never by auto-pans, new lines, resume, page switches or a tap's view reset.
- Fades (0.3 s) 1.2 s after the last hand move. It stays while the pointer is over it, so it can still be clicked outside draw mode.
- The old "fade to 35% while a finger is down" is gone: the map is now only up while you navigate, which is when you want to see it.
- Replay of the recorded sessions: 4,430 writing moves show it 0 times.

## Zoom percentage
- 100% = the page's width fills the view (the existing zoom 1). Shown rounded to 5% under 200% and 10% above, so it reads cleanly.
- Persistent spot: the toolbar (a zoom button between the zoom lock and undo, which brings the toolbar to 15 buttons) and the draw-mode capsule. While pinching: a badge under the page map, fading with it.
- Snap: a pinch (or trackpad magnify outside draw mode) that ends within 4% of a preset (100, 150, 200, 250, 300, 400, 500, 600, 800%) lands on it, so the same zoom is easy to hit again. Not while the zoom is locked.
- Bonus done: clicking the toolbar's zoom opens the presets, Whole Page, and a field to type any zoom (e.g. 175). Each page already saves its zoom, so a relaunch comes back at the same zoom.
