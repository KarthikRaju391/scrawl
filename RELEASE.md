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
- [x] **Performance.** 2,000 and 3,000 strokes render under the 8.3 ms frame budget (release build).
- [x] **The trackpad covers the whole writing area.** Windowed, the window keeps the pad's shape (1.625:1, no stretch). In full screen (green button, ⌃⌘F) it stretches per axis: 2.1% on the built-in display, 9.4% on 16:9. `mapping.sh` checks zero gap and the corners at zoom 1 and zoom 3 (panned), in the window and at three full-screen sizes. A 16 pt-margin mutation fails it.
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
- [x] **Mode keys toggle** (D, W, A, L/Z; M/H/E back to the pen; P back to the last other tool). `keys.sh` presses each twice, and the toolbar stays in sync.
- [x] **Renamed to Scrawl.** App, DMG, zip, window, menus, About, welcome and docs. Pages, logs and settings move over on first launch, tested in the bench.
- [x] **Dark mode.** The aim-first checkbox label was white on the light panel; the window content now always uses the light appearance.
- [x] README (install, Gatekeeper, privacy, uninstall), DEVELOPMENT.md, CHANGELOG.md, LICENSE.

## Not verified (needs a person or other hardware)

- **Hand-test in 0.1.0:**
  - **Full-area map:** touch each trackpad corner just inside the edge band (about 6 mm in from the sides, 4 mm from top and bottom). Ink should start at the window's corner. Try the same in full screen (⌃⌘F).
  - **Edge guard:**
    - rest your palm or thumb on the edge while writing: no pans or zooms;
    - start a stroke right at the edge: no ink;
    - start inside and run off the edge: the ink follows;
    - pinch with a thumb resting on the bottom edge;
    - try the ⚙︎ slider at 0% and 10%.
  - **Toggles:** D twice, W twice, M/H/E twice, P on the pen.
  - **Full screen:** enter and leave it with the green button and ⌃⌘F, in and out of draw mode. The toolbar hides in draw mode, and the banner fades after 3 s.
  - **Writing at zoom 3** in full screen: line width, the 0.4 s pause and new lines.

- **Real touches through the public-touch fallback.** The conversion and the drawing were tested with synthetic touch samples. Real NSTouch delivery while the pointer is frozen wasn't, because that needs fingers on the pad.
- **The real pointer after kill -9.** The tests use a dry-run lock so they never take your pointer. An older real-lock test showed the pointer visible again. Whether the trackpad moves it again needs `checks/kill_test.sh` with you.
- **Intel Macs, macOS 14/15, and a physical Magic Trackpad or second display.** The app is built for them. Only the logic is tested (device arbitration, parking math); this Mac runs macOS 26 with the built-in trackpad.
- **The Gatekeeper first-open flow on a downloaded DMG.** `spctl` rejects the app, as expected, but nobody has clicked through Open Anyway yet.
- **Frame presentation timing.** The background tests measure render CPU/GPU time per frame. Presented-frame gaps need the window in front (`checks/e2e.sh --test-front`).
- **Atomic saves under kill -9.** The kill-during-save test passes, but a non-atomic write also passed it, so it doesn't prove the atomic write. The write itself uses `Data.write(options: .atomic)`, which renames a complete temporary file into place.

## Test results

See "Test run" below (filled in from `checks/run_all.sh`).
