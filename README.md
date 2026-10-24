# Trackpad Draw

A personal macOS app that turns the MacBook trackpad into a finger-drawing surface. The tools
follow Google Keep's drawing screen. It's local only: unsigned (ad-hoc), and it uses the private
MultitouchSupport framework.

## Build and run

    ./build.sh                       # Command Line Tools only, no Xcode
    open "build/Trackpad Draw.app"
    ./build/bench data/passive-1.jsonl   # offline checks (ink, renderer, gestures, jitter model)

## Use

- **⌃⌥D** enters draw mode. You can use it from any app. The cursor freezes and hides, and the
  whole trackpad maps to the visible part of the page.
- **Esc** always exits. So do ⌃⌥D, switching apps, and closing the window.
- One finger draws. Two fingers pan, and pinching zooms (1×–12×). Blue rings show where your
  fingers are, since there's no cursor.
- Palm rejection uses three signals: macOS's own resting-touch flag (matched to the private
  framework's contacts by position), contact size (`palmMajorAxis` / `palmTotal`), and touches
  already on the pad when draw mode starts, which are ignored until lifted. Every lifted contact
  is logged (`"kind": "contact"`) with its peak size and width, whether macOS called it resting,
  and whether it was treated as a palm. One session with a resting palm is enough to set the
  thresholds from data.
- Writing while zoomed in keeps the same on-screen line width, so small handwriting stays crisp.
- **Writing mode** (W in draw mode, or the cursor button in the toolbar): the page moves, not
  your finger. Write at the blue caret. After you lift and pause (`advanceDelayMs`, 500), the page
  slides so the end of your writing sits back at the same spot on the pad (30% from the left), and
  at the right margin it wraps to the next line. Return starts a new line. The page never moves
  while a finger is down, so a cursive word, which is one stroke, is written at one fixed mapping.
  Dots and crossbars added within the pause land on the word. A single cursive word longer than
  the free part of the pad (about 70% of its width) runs out of room, so lower `writingZoom` (3)
  if that happens.
- Toolbar: undo, redo, pen, marker, highlighter, eraser (erases whole strokes), background
  (none/square/dot/ruled), draw mode. Tap the selected tool for sizes and colors.
- Keys in draw mode: P, M, H, E pick a tool; 1–5 pick a size.
- Menu: ⌘Z / ⇧⌘Z, Clear Page (⌘⌫), Zoom to Whole Page (⌘0), Export Page PNG (⇧⌘E, saves to `data/`).

## Tuning (`defaults write local.trackpad-draw <key> <value>`, then relaunch)

| key | default | meaning |
|---|---|---|
| `widthModel` | `mt-pressure` | `mt-pressure` (per-finger force), `speed` (fallback), `contact-size` |
| `inputSource` | `mt` | `nstouch` forces the public-API path (no pressure, so speed width) |
| `oneEuroMinCutoff` / `oneEuroBeta` | 1.0 / 0.05 | jitter vs lag |
| `inkThreshold` | 0 (off) | Inklet-style hover: ink only starts once MT pressure reaches this |
| `palmMajorAxis` / `palmTotal` | 11 / 1.4 | contacts above either value are ignored as palms |
| `padFlipY` | false | set true if strokes come out upside down (unverified pad y direction) |
| `writingZoom` / `advanceDelayMs` | 3 / 500 | writing mode's zoom; pause before the page moves |
| `predictMs` | 16 | how far ahead the predicted tip point is drawn |

The pressure range in `MTPressureModel` (`lo` 4, `hi` 70) is a guess from passive data. Retune
it after `probe/run-guided.sh` (see PHASE1.md).

## Layout

- `app/Ink.swift`: One Euro filter, width models, perfect-freehand radius, CPU stroke path (export)
- `app/Renderer.swift`: Metal: stroke triangle meshes, per-stroke stencil, shader backgrounds
- `app/Canvas.swift`: document, camera, gesture engine, canvas view, stroke log
- `app/DrawMode.swift`: cursor lock, watchdog process, signals, global hotkey
- `app/Toolbar.swift`: Keep-style toolbar and panel
- `app/Multitouch.swift`: private MultitouchSupport access
- `checks/e2e.sh <strokes.jsonl> --test-front [--test-lock]`: replays recorded strokes through
  the input callback in the real app, then screenshots, counts ink, and reports frames presented and
  latency. `checks/ui.sh`: clicks through the toolbar with real NSEvents and screenshots each step.
  `checks/writing.sh [--writing-off]`: simulated writer aiming at the caret. `checks/stress.sh N
  [--zoomed]`: per-frame CPU/GPU and frame gaps with N strokes on the page. In test modes the
  real trackpad feed is off.
- `bench/`: offline checks. `checks/`: scripts for the four acceptance checks. `probe/`: Phase 1.
