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

## Page map covers extended writing
- The map shows the page's first screen ∪ all the ink (also past the page's sides) ∪ the view, with a 2% margin; past the page's edges it's the grey desk, as on the canvas.

## Settings from draw mode
- Opening Settings (any route) leaves draw mode, because the frozen pointer could not click it; closing Settings returns to draw mode. Esc leaves draw mode from any of the app's windows, and any other app window coming to the front (Help, About) ends draw mode.

## Line width follows deliberate pans (½-page overrun fix)
- Replaces "a hand pan right frees the line to the page edge": that fired on any nudge and on pinches (zooming in moves the view's left edge right), so ½-page lines ran 70-99% wide.
- A hand pan counts when the view's centre moved sideways by ≥ 10% of the view since the last stroke (pinch frames don't count: their zoom moves the view around the fingers). Arrow keys count too.
- After such a pan, the next stroke moves the line's start only if it lands away from where the line ended (more than a word gap): writing somewhere new. Carrying on after the last word keeps the start, so No-pan writing still wraps at the width.
- The line then ends ½ or ¾ of the page after that start (clamped to the page margin). Auto-pans never move it. New lines start at the left margin as before.

## Overview thumbnails
- Thumbnails (and OCR titles and the page map) draw each stroke as one round line at its average width through points 1.5 px apart, not its exact pressure outline: identical at that size, 6 ms instead of ~5 s for a full page.
- Pages render in parallel; every page is warmed in the background after launch and again a second after an edit, so the overview opens complete. OCR titles run at background priority, after the thumbnails.

## Line breaks are decided before a word, and ink never moves (Karthik, 19:33 recording)
- Replaces the "hard limit, move the crossing word down" rule (321cf91): Karthik paused inside "the" (after "th") at the ½ mark, the break fired at that pause and carried "th" down. Written ink never moves now.
- At each word gap (the 400 ms pause), if this line's typical word (median width, after a typical word space) wouldn't fit before the limit (80% of a word may hang over), the line breaks now, before the next word starts.
- A word that starts before the limit is finished on its line, even past the limit; the break after it waits a longer pause (650 ms), so a pause inside it doesn't split it.
- A last word much shorter than this line's typical word (under 60%) looks unfinished: the break waits 800 ms (1.5 s if it's also past the limit). Real word gaps are mostly longer; pauses inside words mostly shorter.
- The limit is ½ / ¾ of the page width from the page's left edge (or after a start moved by a deliberate hand pan, which now also counts when no line is open yet).

## Click to draw (replaced arm on click, 261315d; reworked after d0f5b2a)
- Karthik: one click turns drawing on, and the click itself starts the stroke; then let go of the click and keep drawing, lift and touch again for more strokes, no more clicks. It turns off after more than 3 s without drawing (Settings, 2-5 s), timed from the last lift; never while writing. Then a touch only moves the blue aim mark until the next click.
- d0f5b2a needed a click per stroke, and on the real trackpad strokes also ended without a lift. Karthik's hand test (data/session-20261026-232153.jsonl, 13 clicks): releasing the click and the pressure dropping (to 1-10) never ended a stroke; the sensor did. With a very light finger it reports the touch as lifting (state 5, then 6) and in 5 of 13 strokes the same contact came back touching 38-149 ms later. The app took that as a lift. Now, while click to draw is on, a 5/6 report lasting under 0.15 s doesn't end the stroke; a real lift goes on to 7 or disappears within ~20 ms and ends it.
- No armed label or ring colour: the blue aim mark is the one from before 261315d. The ink appearing is the sign it's on.
- Off by default; with it off a touch draws as it always did. Two- and three-finger gestures keep their rules (a click during a pan or pinch draws nothing). The eraser is turned on by a click the same way.
- Taps never turn it on (Karthik, 27 Oct). macOS tap-to-click is on here (com.apple.AppleMultitouchTrackpad Clicking = 1): a light tap sends a click, often after the finger has already lifted. In his session (data/session-20261027-102046.jsonl) the 44 clicks split cleanly: real presses had the finger at 100-146 on the sensor in the 0.25 s before the click, taps 19-79 or no finger at all. A click now turns drawing on only after a press of 90 or more within 0.25 s (17 of the 44 would have been ignored). The press is noted as the frames arrive, not when they're drawn, because the click can reach the app before the next display tick drains the frames that pressed it. Without the private touch API there's no pressure, and any click counts.
- Hard quick taps (Karthik, 27 Oct evening, 0.1.1: "when I tap all across the trackpad consecutively, the drawing starts"). Tap to click is on (com.apple.AppleMultitouchTrackpad and ...AppleBluetoothMultitouch.trackpad Clicking = 1), so every tap is a click as the finger lifts. The 0.25 s press filter let some through: a fast hard tap reads 92-155 on the sensor (his afternoon sessions), above the 90 threshold. A real press differs in timing: in his four sessions the finger was gone 0-33 ms after a tap's click, and stayed down 66 ms or more after a real one. Now a click needs a finger on the pad at that moment that pressed firmly itself, and a click-started stroke whose finger lifts within 50 ms of the click is a tap: the stroke is dropped and drawing goes back off. NSEvent pressure/stage wasn't used: whether tap-to-click clicks carry a stage can't be checked without the hardware, and the touch data shows the difference directly.
- Aiming (Karthik, 27 Oct, superseding 7ddf404's carry-on): "A to B, the blue mark follows; when I lift, the blue mark goes away; next time I start from C, it should start from C, not from B" - as he aimed before click to draw, panning the page with two fingers under an absolute finger. The mark uses the absolute mapping drawing always used (the whole pad onto the view): it appears where the finger lands, follows it, and goes on lift; the ink, mapped the same way, starts exactly at it. 7ddf404 carried the mark on with an offset from where it last stopped: replaying its code over his 13:58 session, the mark started at the previous lift point in 450 of 457 touch-downs, under the finger in 7.
- Panning is untouched by click to draw: the robot compares the same two-finger pan, pan into the edge, pinch and arrow-key pan with it off, on before a click and on while drawing (identical on 4afe7fd too).
- The time can be 0 s (Settings 0-5 s): every lift turns drawing off, so each stroke needs its own click.
- If the finger's first frame comes just after the click, a touch within 0.15 s still starts the stroke.

## Rebuilds never break the app you have open
- build.sh builds and signs in build/.staging-<config>/, then swaps the bundle in. Before, it deleted the bundle and compiled for 1-2 minutes, so opening build/release/Scrawl.app (Karthik's copy) while the checks rebuilt it found an empty app. checks/bundle-intact.sh polls the bundle during a rebuild.
- Robot runs turn crash reports off (as the persist crash test already did): a crash fails the run, and never leaves a "quit unexpectedly" dialog on Karthik's screen. ROBOT_CRASH_REPORTS=1 keeps the report when a stack trace is needed. macOS writes the report up to ~30 s after a crash, so the robot scenario crash-no-dialog watches for 40 s.

## Start draw mode where I last wrote (a setting, 27 Oct)
- Karthik asked for "going back to the last drawing point" to be a setting. That's the resume: draw mode moves the view to the last word, at the zoom it was written at. (Rejoin snapping, a stroke starting near the last lift continuing from it, is off by default and off on his Mac, so it isn't what he sees.) Settings > "Start draw mode where I last wrote", on by default, so nothing changes until it's turned off.

## Settings window layout (27 Oct)
- The click-to-draw label was cut off, and its time slider sat under the usage-counts switch with its label running under the slider. Labels are shorter, the time is a row under its own switch (label, slider, value; greyed while click to draw is off), and the window is laid out top-down at the height of its rows. Before/after: docs/robot/settings-before.jpg, settings-after.jpg.

## Line breaks at 28-32% when zoomed in (Karthik's recording, 27 Oct 21:22)
- Not the zoom: the next-word look-ahead (decide the break before a word starts) splits a line into words where the gap between strokes is over 45% of the *line's* ink height. On his first line at 400% the p of "panning" raised that height from 33 to 48 page units; the threshold went from 15 to 22, his word spaces (~18) fell under it, and the whole line counted as one 358-477 unit "word". The look-ahead then saw no room for another such "word" and broke the line at 446 (28% of the page; ½-page lines end at 800). His saved page: lines end at 28%, 31%, 32%. Writing zoomed in made it likely: he writes large and with tight spacing there.
- Now the gap is 45% of a typical stroke's height (the median), so one descender or capital doesn't move it, and a "word" wider than a quarter of the line counts as a failed split (the look-ahead falls back on earlier lines' word, or waits for the word that crosses the limit). Replayed on his three lines: no early break. Robot half-line-zoomed writes ½-page lines at 400% with his spacing: 28% before, 53/48/47% now.

## No sideways pan in writing mode (Karthik, 28 Oct)
- The pan that followed the pen along a line (centre / left) was distracting: removed. The page moves only for the next line, when the line reaches its width (or, after a deliberate hand pan, that width after where you moved to). Writers pan by hand with two fingers if they want room.
- A faint vertical line (blue, 22% opacity, 1 pt at any zoom) marks where the next line comes: the current line's limit, `lineLimitX`. Shown whenever writing mode is on (a width is chosen and the next-line move is on); hidden otherwise. It's drawn only in the live canvas; exports, thumbnails and the page map render the page separately and never include it.
- Removed with it: the writing panel's No pan / Centre / Left tiles, the saved `autoPan` tool setting (old values are ignored), the `panEdge` default and `--pan-edge`/`--autopan` test flags, and the checks that measured sideways pans (autopan centre/left suites, the zoom-3 full-width pan case); `checks/autopan.sh` now runs once, panning by hand. Robot: write-* scenarios by width only, and every writing scenario checks there is no sideways pan.

## The limit line only as you approach it (Karthik, 28 Oct evening)
- "Only show the guide line when we are approaching the width point." It's hidden while you write a line; it starts to show when the line's rightmost ink (including the stroke being drawn) is within 15% of the line width of the limit (120 page units for ½-page lines, 180 for ¾, 240 for full: from about 43% of the page on a ½-page line), and its strength grows in proportion, to the full faint blue (22%) at the limit. After the new line, or when the ink is no longer near (an undo, a line started elsewhere), it fades out. Fades take 0.25 s for the full change. All internal (`CanvasView.limitShowWithin`, `limitFadeSeconds`): one more slider wasn't worth it.

## The next line goes back to the block's start (Karthik, 28 Oct)
- Recording 14:29: writing a block in the right half of the page, the next-line pan took him to the page's left margin, onto older notes. The next line now goes back to where the current writing run's first line began, and every line's width counts from there.
- A run (block) starts with the first stroke after: writing mode turning on, a page change or new page, a deliberate hand pan (10% of the view or more) followed by writing somewhere away from the line's end (the rule that already moved a line's start), or writing well above or below the current line. A pause doesn't start one (an idle gap isn't a move). An undo keeps the run (rewriting the last word doesn't move the block's start). Return keeps it too.
- Widths are 50% / 75% / 100% of the page width from the run's start (the panel says so now), capped at the page's right margin (97% of the page; 100% always ends there). A run starting at 55% with 50% wraps at 97%. From the margin (3.5%), 50% lines end at about 53.5% of the page (they ended at 50% before, measured from the page's edge).
- Only writing mode moves to the next line (unchanged): with it off, the page never moves while you write.
- The limit line sits at the run's start + the width (same value), fading in within 15% of it.

## The next line at the next word gap once past the limit (Karthik, 29 Oct, option A)
- Once the line's ink has crossed the width marker, the next line comes at the next normal word gap: 400 ms after the lift, like every other page move; a touch before then cancels it. The longer waits after crossing (650 ms, and 1.5 s for a word that looked unfinished) are gone. Before the marker (the look-ahead: the next word wouldn't fit), an unfinished-looking last word still waits 800 ms. Written ink never moves.

## Karthik's feedback on e2753a7 (29 Oct)
- "Filled a screen" note: once you keep writing on a page (K, or more ink with the note showing), it doesn't come back for that page, also after reopening (saved per page as `kept`).
- The writing width defaults to 100% (a saved choice is kept).
- The width panel: a click on the page closes it and keeps writing mode on (the picked width is already applied); a click on the writing button while the panel is open only closes it.
- The next line went to the left of the page (recording 17:16): the block start was never moved. He scrolled to the middle of the page outside draw mode and pinched; only a two-finger pan in draw mode counted as moving somewhere new, so the block stayed at text written earlier on the left (x 34; next lines went to x 250-340; his strokes were at 1040+). Now any move of the view by you since the last stroke (pan in or out of draw mode, pinch, scroll, arrows, page map) of 10% of the view counts; the app's own next-line move doesn't.
- No look-ahead line break: "it panned before I even reached the end of the line". The next line comes only when the ink crosses the limit (at the next word gap, 400 ms).

## A block from the middle of the page to its right side (Karthik on 4988285, 29 Oct)
- "Either it just pans to the next line and not to the next line's beginning, or not pan at all." Found with his sessions (replayed through the app with his exact touches, views and click-to-draw clicks: `checks/session_cf.sh <session> 400 0.7 --replay-all-views`) and robot block-mid-page / block-edge-cases:
  1. The limit was capped at 97% of the page: ink often stopped short of it (no move), and the guide line hugged the page's edge. Now 95% (92% made his lines, which go to 95-100%, cross while he still had a word to write, so the move came mid-phrase).
  2. After a move, the camera stops at the page's edge; the app remembered its unclamped target, so the difference looked like a hand move and his next stroke started a new block at the page's edge, and every later line went there (the view clamped at the right). Now it remembers where the view really goes.
  3. A hand move (pinch, nudge) after a move, then the next line a little off the block's start, started a new block there: lines drifted right (to 56%). Now a new block needs the stroke 10% of the page from the current block's start.
  4. Going back to finish the line a move just left started a new block at its end. Now it continues that line (no automatic move for it: you're finishing it), and writing just below near the block's start is the block's next line.
- The 19:59 session's early break (ink at 1348 of a 1552 limit) doesn't happen with 4988285's code on his exact input: that run was most likely an older build (the look-ahead). The session log now records why each move was decided (right, limit, block start, width).

## Carrying a line on after a hand pan keeps the block; ink at 93-95% brings the next line (Karthik on 74c61cf, 29 Oct, page 18)
- "When I start writing in the middle, why doesn't it bring me back to the relative starting point?" His session (22:36, width 50%, the saved choice): a block at 22% (x 376), 200%. He undid a word, rewrote it, pinched and panned right by hand, and his next mark came 78 page units (4.9% of the page) after the line's end. That counted as "writing somewhere new on the line" (the old gap: 1.5x the line's height or 8% of the view, 64 here, since after the undo the line was just the rewritten word), so a block started at x 905: the limit went to the page's edge (905 + 50% capped at 95%), the line ran to 95%, and the move went back to 905, not 376.
  - With no sideways auto-pan, panning right by hand is how a zoomed-in line goes on. Writing to the right of the line's end now carries the line on unless it's more than 10% of the page past it (the same distance as a new block from the block's start); to its left, the old gap.
  - An undo keeps the line open with what's left of it (it closed the line, so a pan right after an undo then looked like writing away from the block's start: a new block there).
- Ink that stops at 93-95% of the page when the limit is near the page's edge (past 93%, up to the 95% cap) got no move at all. Now it brings the next line after a longer pause (1.5 s, instead of 400 ms; a touch before then cancels it). Not a 93% limit: in his sessions he once lifted at 92.99% and wrote another word 0.97 s later, which a 93% limit would have broken mid-phrase; no pause at 92.5-95% before more ink on the line was longer than that.
- Robot block-pan-continue: his sequence (22%, 50%, 200%, undo, pan, a word gap of 1.2x the old threshold), and blocks from 20/50/60% with 50/75/100% widths and ink ending at 93-95%.
- Karthik on b03bac2: "don't wait for 1.5s, users won't know that. Keep it 400." The near-edge move (ink at 93-95% with the limit near the page's edge) now uses the same 400 ms word gap as crossing the width marker. That was the only longer wait left on the next-line path: the 650 ms and 1.5 s waits after crossing went in e2753a7, and the 800 ms wait for an unfinished-looking word went with the look-ahead (4988285; `lastWordUnfinished` is no longer called). Robot block-pan-continue (b) checks the move came within 0.9 s of the lift.

## Just inside the marker brings the next line (Karthik on 0.1.1, 30 Oct)
- "When I am just inside the guide line, the next line pan isn't triggering." His line "...to even trigger it" (50% width, 300%) ended at x 860.7, a few units short of the marker: the move only came once ink crossed it (`right >= limit`), or at 93%+ of the page with the marker at its edge. The line before moved only because "in" crossed.
- Now ink ending within 3% of the line width before the marker (24 page units at 50% of a 1600-wide page, 36 at 75%, 48 at 100%) is a full line too: the next line at the same 400 ms word gap, a touch before then cancels it. With the marker near the page's edge (past 93%) the zone starts at 93% of the page, as before.
- Why 3%: in his sessions (31 lines that broke) the only words ending within 4% of the marker were followed by long pauses (1.6 s, 6.3 s: waiting for a move that didn't come); at 4.8-5% he wrote another word on the line 0.6-2.4 s later, which a 5% zone would have broken early.
- Robot near-marker: widths 50/75/100% at 100% and 300%, ink ending 0.3-2.5% of the line width inside the marker (moves by 0.9 s, back to the block's start) and about 8% inside (no move after 1.5 s).


## The overview changes once per key press, not per auto-repeat (Karthik on 0.1.1, 30 Oct)
- "This is not good UX... that flickering state shouldn't happen" (recording 12:18): the overview and pages 9-12 flashed back and forth about once a second, with half-drawn frames (a page shrinking over the grid). At 10 fps the pointer sits still over a tile while it happens, and the usage log shows an overview opening every ~1 s with nothing else in between. G toggles: on a page it opens the overview; in the overview it opens the highlighted tile (the one under the pointer). macOS auto-repeats a held key (press-and-hold is off on his Mac), and every repeat that landed outside a transition toggled again.
- Now G, and Return / Space / Esc in the overview, act once per press: auto-repeats are ignored. Held arrows still repeat (moving the highlight).
- checks/gallerykeys.sh: G held on a page, G held in the overview and Return held in the overview, 1.5 s each at macOS's default repeat timing: one transition each. On fd5c559, G held gave 7 transitions in 1.5 s.
