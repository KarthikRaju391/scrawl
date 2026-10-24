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
- Palm rejection (off by default) uses macOS's resting-touch flag, contact size
  (`palmMajorAxis` / `palmTotal`), and touches already on the pad when draw mode starts. Every lifted
  contact is logged (`"kind": "contact"`) for tuning.
- Writing while zoomed in keeps the same on-screen line width, so small handwriting stays crisp.
- **Pages**: each page is infinitely long downwards. A dashed line marks every screen height (from
  the aspect ratio of the display the app is on). Writing past one shows a hint: N for a new page,
  or K to keep writing. Toolbar ‹ › + (or ⌘[ ⌘] ⌘N) move between pages and add one. Pages are
  in memory only: quitting loses them.
- **Pan and zoom** work everywhere: in draw mode with two fingers (pan) and pinch (zoom); outside
  draw mode with the normal two-finger scroll and pinch.
- **Writing mode** (W in draw mode, or the cursor button; tap it again for line width ½ / ¾ /
  full page, or Off): when a stroke you finish reaches the right 15% of the view, the view pans so
  it ends mid-screen; when the line reaches the chosen width, the view goes to the start of the next
  line. Nothing moves while a finger is down.
- **Zoom lock** (lock button, or Z in draw mode): pinching no longer zooms; two fingers still pan.
- **Saved between launches**: tool, colours, sizes, background, line width, zoom lock, Smoothing and
  Prediction. Pages are not saved yet.
- **Palm rejection is off** (`defaults write local.trackpad-draw palmRejection -bool true` turns it
  back on): macOS's resting flag marked real fingers as palms and broke pinch.
- **Feel (⚙︎ in the toolbar)**: *Smoothing* (← follows the finger exactly · steadier →) and
  *Prediction* (← never overshoots · keeps up →). They apply to the next stroke and are remembered;
  Defaults resets them (50%, 12 ms). Measured on Karthik's strokes: prediction makes the tip keep
  up (20 → 10 pt behind the finger at 24 ms) but it shoots off at turns and stops; it's damped when
  slowing or turning. Every stroke ends exactly where the finger lifted.
- Toolbar: undo, redo, pen, marker, highlighter, eraser (erases whole strokes), background
  (none/square/dot/ruled), draw mode. Tap the selected tool for sizes and colors.
- Keys in draw mode: P, M, H, E pick a tool; 1–5 pick a size.
- Menu: ⌘Z / ⇧⌘Z, Clear Page (⌘⌫), Zoom to Whole Page (⌘0), Export Page PNG (⇧⌘E, saves to `data/`).

## Tuning (`defaults write local.trackpad-draw <key> <value>`, then relaunch)

| key | default | meaning |
|---|---|---|
| `widthModel` | `mt-pressure` | `mt-pressure` (per-finger force), `speed` (fallback), `contact-size` |
| `inputSource` | `mt` | `nstouch` forces the public-API path (no pressure, so speed width) |
| `smoothing` / `predictMs` | 0.5 / 12 | the ⚙︎ sliders (`oneEuroMinCutoff` / `oneEuroBeta` override smoothing) |
| `inkThreshold` | 0 (off) | Inklet-style hover: ink only starts once MT pressure reaches this |
| `palmMajorAxis` / `palmTotal` | 11 / 1.4 | contacts above either value are ignored as palms |
| `padFlipY` | false | set true if strokes come out upside down (unverified pad y direction) |

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
  `checks/autopan.sh [--writing-off]`: simulated writer following its ink across the view.
  `checks/stress.sh N
  [--zoomed]`: per-frame CPU/GPU and frame gaps with N strokes on the page. In test modes the
  real trackpad feed is off.
- `bench/`: offline checks. `checks/`: scripts for the four acceptance checks. `probe/`: Phase 1.
