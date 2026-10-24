# Developing Trackpad Draw

## Build

    ./build.sh                      # dev build: build/Trackpad Draw.app (bundle id local.trackpad-draw), plus build/bench
    open "build/Trackpad Draw.app"
    CONFIG=release ./build.sh       # release build: build/release/Trackpad Draw.app, universal, hardened runtime
    scripts/release.sh              # release build + DMG + zip + SHA256SUMS.txt in dist/<version>/

Only the Command Line Tools are needed. The name, bundle ID, version, minimum macOS and update URL
live in `release.conf`. The build number is the git commit count.

Development builds write touch diagnostics to `data/` in this repo. Release builds write nothing
there unless Help › Record Touch Diagnostics is on, and then they write to `~/Library/Logs/Trackpad Draw`.

### Signing and notarization

`scripts/release.sh` signs ad-hoc by default, which is what the GitHub release ships. With an Apple
Developer ID:

    SIGN_ID="Developer ID Application: <Name> (<TEAMID>)" NOTARY_PROFILE=<profile> scripts/release.sh

Create the profile once with
`xcrun notarytool store-credentials <profile> --apple-id <id> --team-id <TEAMID>`. Without these
variables, the signing and notarization steps are skipped.

## Tests

`checks/run_all.sh` runs every automated check. They all run in the background: none take focus,
the pointer or the trackpad, so they're safe to run while you use the Mac. The suites:

| suite | what it covers |
|---|---|
| `build/bench` | Offline checks:<br>• ink filter, renderer meshes, gestures<br>• the 400 ms pause before page moves, aim mode<br>• the notebook file round trip, export (PDF read back with PDFKit)<br>• device arbitration, the update check parser, display parking |
| `checks/persist.sh` | kill -9 and a real crash mid-stroke, then reopen: the notebook is identical and renders the same. Also covers:<br>• quitting straight after a stroke<br>• kill -9 while writing continuously<br>• kill -9 during large saves<br>• an unreadable file |
| `checks/cursor.sh` | The pointer comes back after:<br>• kill -9 and a crash<br>• SIGTERM, quit and Esc<br>• display sleep, system sleep and a user switch<br>• display changes<br>Uses a dry-run lock (`TRACKPAD_DRAW_DRYLOCK`): every step runs except the CoreGraphics pointer calls. |
| `checks/input.sh` | MultitouchSupport off (`--input-nstouch`); MT going quiet mid-use; welcome and help text |
| `checks/aim.sh`, `zoomlock.sh`, `autopan.sh`, `ui.sh` | aim-first, zoom lock on every path, writing-mode panning, toolbar clicks |
| `checks/e2e.sh <strokes.jsonl>` | Recorded strokes replayed through the trackpad callback in the real app. Checks:<br>• ink on screen<br>• frames<br>• latency |
| `checks/cf_all.sh` | Karthik's six recorded sessions replayed on a virtual clock with the old and new page-move rules |
| `checks/release.sh` | Builds the DMG and runs the app from the mounted volume. Checks:<br>• signature and entitlements<br>• menus and About box<br>• MultitouchSupport loading under the hardened runtime<br>• the update check against a local fixture server<br>• no network at launch<br>• kill -9 persistence, fallback and pointer<br>• 2,000/3,000-stroke render time |

Test modes (`--test-*`) never load or save the real notebook unless `TRACKPAD_DRAW_DATA` points at a
scratch folder, and the scripts always set it. Test crashes drop their crash-report port, so no
"quit unexpectedly" dialog appears. Both crash checks fail, and close the dialog, if one ever does.

Manual checks still need a person (see CHECKS.md):
- OCR accuracy on real handwriting;
- finger-to-ink latency on 240 fps video;
- jitter on a still finger;
- with a real pointer lock, that the trackpad moves the pointer again after kill -9 (`checks/kill_test.sh`).

## Tuning (`defaults write local.trackpad-draw <key> <value>`, then relaunch)

| key | default | meaning |
|---|---|---|
| `widthModel` | `mt-pressure` | `mt-pressure` (per-finger force), `speed` (fallback), `contact-size` |
| `inputSource` | `mt` | `nstouch` uses the public touch path (also View › Use Basic Touch Input) |
| `smoothing` / `predictMs` | 0.5 / 12 | the ⚙︎ sliders (`oneEuroMinCutoff` / `oneEuroBeta` override smoothing) |
| `pauseBeforeMoveMs` | 400 | writing mode: how long the finger must be up before the page moves |
| `aimThreshold` | 15 | aim first: MT pressure that starts the ink |
| `palmRejection` | false | macOS's resting flag marked real fingers as palms and broke pinch |
| `palmMajorAxis` / `palmTotal` | 11 / 1.4 | with palm rejection on: contacts above either value are ignored |
| `padFlipY` | false | set true if strokes come out upside down |
| `diagnosticLogs` | dev: true, release: false | touch diagnostics (Help › Record Touch Diagnostics) |

## Layout

- `app/Ink.swift`: One Euro filter, width models, perfect-freehand radius, CPU stroke path (export)
- `app/Renderer.swift`: Metal stroke meshes, per-stroke stencil, shader backgrounds
- `app/Canvas.swift`: document, camera, gesture engine, canvas view, input paths, session recorder
- `app/Writing.swift`: writing-mode layout (auto-pan, new line)
- `app/Notebook.swift`: file locations, the notebook file, autosave
- `app/Export.swift`: PNG and PDF export
- `app/DrawMode.swift`: pointer lock, watchdog process, signals, global hotkey
- `app/Multitouch.swift`: private MultitouchSupport access, several trackpads
- `app/Welcome.swift`, `app/AppMenu.swift`, `app/Updates.swift`: first run and help, menus and About, update check, crash note
- `app/Toolbar.swift`: Keep-style toolbar and panel
- `app/Test*.swift`: test modes
- `bench/`: offline checks. `checks/`: test scripts. `tools/`: analysis and replay tools. `probe/`: Phase 1.
- `data/`: Karthik's recorded strokes and sessions. The replay suites use them.
