# Release checklist: Scrawl 0.1.0

Distribution: a GitHub release with an ad-hoc-signed DMG (Karthik, 2026-10-24). No Developer ID and no
notarization, so first-open needs the Gatekeeper steps in the README and the release notes.

## Karthik decides before publishing

The name and bundle ID are settled. A quick search on 2026-10-25 found other Mac apps called Scrawl:
- [Scrawl by Cocoatype](https://apps.apple.com/us/app/scrawl/id1249895598?mt=12): an iCloud notes app on the Mac App Store, last updated 2021.
- [Scrawl by Kit Langton](https://scrawl.kitlangton.com/): screen capture for AI coding agents, macOS 15+.
- [Scrawl by schristoph](https://schristoph.online/blog/scrawl/): an open-source (MIT) macOS menu-bar overlay for drawing on top of any app. It's the closest in purpose.
- [Scrawl by Liip AG](https://apps.apple.com/us/app/scrawl/id1444724045): an iPhone drawing game.

This isn't a trademark search. Worth a look before publishing. Still open: `data/`, publishing, and later a Developer ID.

| decision | current setting | where to change |
|---|---|---|
| License | **Decided: MIT**, copyright 2026 Karthik Raju | `LICENSE` |
| App name | **Decided: "Scrawl"** (2026-10-25). The repo and source keep "trackpad-draw". | `release.conf` `APP_NAME` |
| Bundle ID | **Decided: `com.karthikraju.scrawl`** | `release.conf` `BUNDLE_ID`. On first launch, Scrawl moves any "Trackpad Draw" pages and logs folders to the new names and copies settings from the old bundle ID. The welcome window shows once. |
| Recorded handwriting in `data/` | 59 MB of your strokes and sessions are in the repo; the replay tests need them | Before making the repo public: keep them, or have them removed from the history first (removing them later doesn't erase them from a public history). |
| Publish | The repo is **private**, and the release is a **draft** | GitHub: make the repo public, then publish the draft. Check for Updates only works once both are public: until then it says "No published release found." |
| Developer ID + notarization (later) | Not done: needs the Apple Developer Program ($99/year) | Then run `SIGN_ID=… NOTARY_PROFILE=… scripts/release.sh`. The Gatekeeper prompt goes away. |
| Usage counts sent remotely | **Off**: `POSTHOG_PROJECT_TOKEN` in `release.conf` is empty, so counts stay in the local log | Create a free PostHog project (EU Cloud), turn on "Discard client IP data", put its `phc_` token in `release.conf`, rebuild. Nothing else (see `docs/analytics.md`). |
| Update host | GitHub releases API (`release.conf` `UPDATE_URL`) | Change it if releases move elsewhere. Only the Check for Updates menu uses it. |

## Done and tested

- [x] **Pages saved and restored.**
  - Autosave runs 0.5 s after a change, written atomically off the main thread, plus a save on quit.
  - Undo/redo history survives reopening.
  - Tested by `persist.sh`:
    - kill -9 mid-stroke, and a real crash mid-stroke, reopen identical and render the same;
    - quitting right after a stroke;
    - kill -9 while writing continuously loses at most about 0.5 s;
    - kill -9 during 12 MB saves 8×;
    - an unreadable file is kept aside.
- [x] **The pointer always comes back.**
  - Covered:
    - kill -9 and a crash, through the watchdog process;
    - SIGTERM, quit, Esc;
    - display sleep, system sleep, a user switch / screen lock;
    - display changes.
  - Tested by `cursor.sh`, with a dry-run lock.
- [x] **Export.** Every page goes to one vector PDF, and the current page to PNG. The PDF is read back with PDFKit, and its ink matches the PNG.
- [x] **First run.**
  - The welcome window covers draw mode, the live input path, shortcuts and privacy.
  - The app needs no permissions.
  - If touches stop arriving, it switches to the public touch path and points to Input Monitoring.
- [x] **App identity.** Version from `release.conf`, build number = commit count, About box, app icon.
- [x] **Menu bar.** Full menus, Help (⌘?) with every shortcut, diagnostics switch, basic-touch switch.
- [x] **Check for Updates.**
  - One GitHub request, only when chosen.
  - Tested against a local fixture server: newer, same, prerelease, 404, server down, and unreadable responses.
- [x] **Signing and packaging.**
  - Hardened runtime, no entitlements, universal (arm64 + x86_64).
  - `scripts/release.sh` builds the DMG, zip and SHA256SUMS.
  - Developer ID signing and notarization only run when credentials are supplied.
- [x] **MultitouchSupport** loads under the hardened runtime. The public-touch fallback works with MultitouchSupport turned off.
- [x] **Several trackpads:** the one you touch owns the input until its fingers lift.
- [x] **Several displays:** the pointer parks on the canvas whichever display the window is on. Draw mode ends when displays change.
- [x] **Minimum macOS 14.** The app uses the view's display link, which is new in 14; it doesn't compile for 13.
- [x] **Privacy.**
  - No network at launch (lsof, from the DMG build).
  - Crash notes and diagnostics stay in `~/Library/Logs/Scrawl`.
- [x] **Performance.** With 2,000 and 3,000 strokes on the page (release build), Scrawl's own work per frame is about 0.1–0.4 ms (building plus encoding), far under the 120 Hz budget of 8.3 ms. An earlier version of this note blamed battery power for some 9.4 ms readings. That was wrong. The measurement included the wait for a drawable from the window server, which is 8–9 ms for a test window sitting behind other windows (it gets one per display refresh) and less when the window is visible. The check now counts only Scrawl's own time and reports the wait separately. Presented-frame timing of a frontmost window still needs `checks/e2e.sh --test-front` while nobody is using the Mac.
- [x] **Any window shape, and paper everywhere.**
  - The window resizes freely: tall beside another app, wide, or full screen.
  - The paper fills the window with no grey margins.
  - The pad's inner 90% maps without distortion to the largest pad-shaped rectangle in the window, centred, outlined in draw mode. The paper around it is reached by panning.
  - Full screen uses the same rule, with no stretch.
  - `mapping.sh` covers a pad-shaped window, a wide window, a tall half-screen window (with screenshots), and full screen at 1512x950 and 1920x1080. In each it checks: no gap, white paper at the window's edges, pad shape, centring, equal scale on both axes, corners and real ink from the corners, outline only in draw mode, edge guard, two-finger pan, zoom lock.
  - Rendering with the old stretched mapping fails all five shapes.
- [x] **New lines go back to the left margin.**
  - The bug: the line start came from the current line's first stroke. After a hand pan, an undo or a page switch it was mid-page, so new lines went down but not left. Seen in the recordings: new lines landing at the page's right edge.
  - Lines now start at the page margin, and Return does a new line by hand.
  - A palm resting in the edge band no longer cancels or holds back a pending page move.
  - `newline.sh`: 108 cases (auto-pan off/centre/left × line width ½/¾/full × zoom 2/3/5 × lock off/on × a start at the page left or after a hand pan right) plus Return and the palm case. On the previous code: 0/108.
- [x] **Edge guard** (5% default, ⚙︎ slider, 0 = off).
  - Touches that start in the band never draw, pan or pinch, and don't count as a second finger. The inner 90% maps to the whole writing area.
  - `edge.sh` covers:
    - band starts;
    - a palm on the side before and during a stroke;
    - a thumb on the bottom during a pinch;
    - two fingers with one in the band;
    - a stroke into the band;
    - corners in the window and full screen;
    - a guard-off control.
  - A guard-disabled mutation fails 5 checks.
  - Replaying Karthik's 6 sessions (`edge_cf.sh`):
    - 45 edge-caused two-finger gestures removed (805 → 760);
    - 41 strokes now drawn that a resting edge touch had turned into a gesture;
    - 11 strokes removed: 5 of them he had undone, and 6 real strokes (0.4% of 1,464) are lost.
- [x] **Mode keys toggle** (D, W, L/Z; M/H/E back to the pen; P back to the last other tool). `keys.sh` presses each twice, and the toolbar stays in sync.
- [x] **Page bounds are obvious.**
  - Off-page space (beside the page, above its top) is a plain grey desk with a shadowed edge and no lines.
  - The trackpad's area sits at the top of a tall window, so the page top meets the window top and can't drift below it.
  - `page.sh` covers narrow, wide and screen-sized windows at zoom 1, zoom 3, and zoom 3 at the right edge, with screenshots and pixel checks. Two mutations fail it.
- [x] **Pages overview (G / grid button).**
  - Cached thumbnails.
  - The grow and shrink transition between a grid cell and the canvas, with its geometry asserted.
  - The "+ New page" tile is last.
  - It leaves draw mode and returns to it.
  - `gallery.sh` covers 40 pages, persistence across a restart, and screenshots.
- [x] **Page arrows dim** on the first and last page, and ⌘[ / ⌘] do nothing then. Next never adds a page. `arrows.sh` checks this, and a mutation fails it.
- [x] **Page dates.** Created and last-edited dates per page, shown on overview tiles and the open page's label. Pages saved before this change show "date unknown" (no real source to recover them from). Tested by `meta.sh` and the bench.
- [x] **Overview responsiveness.** Click to first frame went from ~300 ms to ~5 ms, and G from ~320 ms to 10–35 ms. The animation runs 0.22 s, easing out, at 8.3 ms frames. Tested by `gallery_speed.sh`, which fails on the old build.
- [x] **Tool keys and buttons outside draw mode** turn draw mode on with that tool. Tested by `tooldraw.sh`, which fails on the old build.
- [x] **Two-finger double tap = undo, three-finger double tap = redo** (draw mode).
  - The tap rules come from Karthik's recorded sessions.
  - Replaying the 7 sessions recorded before the gestures gives 0 false double taps; looser rules give 1, which fails the check. Karthik's session recorded with the gestures replays to exactly the 14 undos and redos the app made.
  - Fixed along the way: an eraser pan could erase under the first finger.
  - Tested by `taps.sh`, which fails on the old build, and the bench replay.
- [x] **Writing jitter fixed.**
  - The cause: autosave encoded the whole notebook on the main thread, about every half second while writing. On Karthik's 4.5 MB notebook that blocked drawing for ~100 ms per save; his recorded session shows 153 stalls of 86 ms.
  - Now the main thread only takes a snapshot (0.2 ms); the encoding and writing happen in the background.
  - Tested by `jitter.sh`: every displayed frame's ink step must stay within 1 pt of the steady step. Before: 20.9 pt jumps; after: 0.66 pt. On a copy of his notebook: 6.6 → 0.6 pt. A mutation that puts the encoding back on the main thread fails it.
- [x] **Overview: one highlight.** The blue ring moves with the arrows and the pointer, and G, Return or Space opens it. Esc goes back. The page you came from shows a small dot. Tested by `gallerykeys.sh`, which fails on the old build.
- [x] **Arrow keys.**
  - They pan the page: 10% of the view, or a screen with Shift, clamped at the page edges.
  - In the overview they move a selection, and Return or Space opens it.
  - Fixed along the way: shortcut letters typed into a text field (e.g. the save panel) were taken as shortcuts.
  - Tested by `arrowkeys.sh`, which fails on the old build.
- [x] **Pill labels centred.** The toast and banners had text 1.8–4.2 pt above centre; now it's within 0.8 pt. Tested by `toast.sh`, which measures screenshots.
- [x] **Aim-first mode removed** (Karthik: the finger rings already show where you'll write).
  - The toggle, the A key, the panel checkbox, the help and doc mentions, and its test suite are gone.
  - Old settings that still contain `aimFirst` load fine; the key is ignored and not written back (bench check).
- [x] **Renamed to Scrawl.** App, DMG, zip, window, menus, About, welcome and docs. Pages, logs and settings move over on first launch, tested in the bench.
- [x] **Dark mode.** A settings checkbox label was white on the light panel; the window content now always uses the light appearance.
- [x] README (install, Gatekeeper, privacy, uninstall), DEVELOPMENT.md, CHANGELOG.md, LICENSE.

## Not verified (needs a person or other hardware)

- **Hand-test (short: everything else is covered by the robot user, see docs/robot-report.md):**
  - **Feel on the real trackpad:** write a few lines at zoom 3 in writing mode; scratch out a word with
    your finger (does a natural zig-zag trigger it, and does fast cursive never trigger it?); the undo scrub
    (double tap, hold, slide); whether the haptic tick is felt on a double-tap undo (it fires at lift).
  - **macOS gestures:** with three-finger Look Up / Mission Control / swipes between spaces turned on in
    System Settings › Trackpad, check that the three-finger double tap (redo) and the scrub aren't taken by
    the system first. Injected test touches skip the system, so only your fingers can check this.

- **Real touches through the public-touch fallback.** The conversion and the drawing were tested with synthetic touch samples. Real NSTouch delivery while the pointer is frozen wasn't, because that needs fingers on the pad.
- **The real pointer after kill -9.** The tests use a dry-run lock so they never take your pointer. An older real-lock test showed the pointer visible again. Whether the trackpad moves it again needs `checks/kill_test.sh` with you.
- **Intel Macs, macOS 14/15, and a physical Magic Trackpad or second display.** The app is built for them. Only the logic is tested (device arbitration, parking math); this Mac runs macOS 26 with the built-in trackpad.
- **The Gatekeeper first-open flow on a downloaded DMG.** `spctl` rejects the app, as expected, but nobody has clicked through Open Anyway yet.
- **Frame presentation timing.** The background tests measure render CPU/GPU time per frame. Presented-frame gaps need the window in front (`checks/e2e.sh --test-front`).
- **Atomic saves under kill -9.** The kill-during-save test passes, but a non-atomic write also passed it, so it doesn't prove the atomic write. The write itself uses `Data.write(options: .atomic)`, which renames a complete temporary file into place.

## Test results (2026-10-26, build 2, everything in the background)

- `checks/run_all.sh`, 30 suites: 29 passed in one run. The 30th, mapping, sampled two
  "paper" pixels where the regrouped toolbar now reaches in a narrow window; the samples moved above the
  toolbar and it passes 7/7. The DMG smoke test passed again on the final build (28/28).
- Bench 94/94: scratch-out over every recorded stroke, the scrub over every recorded session (0 false
  starts; the 14 logged gesture undos/redos still replay exactly), usage counts never on the main thread.
- `make robot`: 115/115 checks in 30 scenarios (docs/robot-report.md), including failing-first proof for
  every item in this round and three old bugs caught on their old commits.
- Mutation checks: 5 for the mode rules, 7 for scratch-out and the scrub, 3 for usage counts. All caught.
- Nothing slower: the longest main-thread stall writing on a 9,000-stroke notebook is 26 ms (25 before);
  ink jitter is 0.59 pt (0.66 at the jitter fix).

The parked pan bug (a hand pan right, then a new line pulled the view back) is fixed as part of the writing
flow work: its test, `checks/pan.sh`, is committed and passes 34/34.
