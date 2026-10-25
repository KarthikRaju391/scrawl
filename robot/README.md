# Robot user

`make robot` builds the app and runs `robot/robot.py`, which uses the real `build/Scrawl.app` the way a
person does, in the background. You can keep using the Mac while it runs: it never takes focus, the
pointer or the trackpad. Report: `build/robot/report.html`, with screenshots for each scenario.

    make robot                         # every scenario, about 10 minutes
    make robot ONLY=toggles,write-zoom3
    python3 robot/robot.py --list      # the scenarios
    make robot-old C=433b915 ONLY=eraser   # the same robot against an old commit

## How it gets input into the app

| Input | Path into the app | What it skips |
|---|---|---|
| Touches | Frames go into `Multitouch.onFrame`, the callback MultitouchSupport and NSTouch feed, on an 8 ms clock like the driver. They enter through `--test-robot` (`app/Robot.swift`), which is compiled out of release builds. | The sensor and driver |
| Handwriting | Hershey script and roman letters (`robot/fonts`) with jitter, 45 mm/s, in-word lifts of about 0.15 s and a 0.55 s pause after each word. Or Karthik's recorded touch frames from `data/session-*.jsonl`, palms and thumbs included. | |
| Keys | Real CGEvents posted to the app's process (`robot/robot-input.swift`) | |
| Toolbar clicks | AppKit mouse events through `window.sendEvent`, inside the app | The window server. macOS doesn't deliver CGEvent clicks posted to an app that isn't in front. A system-wide click would move your pointer. |

## What it checks

What a user would see:
- window screenshots;
- Vision OCR of what was written (`robot/robot-ocr.swift`);
- the app's state: mode, tool, page, view, the note in draw mode, the overview selection;
- the notebook after a quit and relaunch;
- timing: key press to visible change, the longest gap between frames while writing, and ink latency
  from the stroke log.

The robot writes like a person. It waits for the page to stop moving, then writes the next word after the
last one, wherever that is on screen now. If the pad runs out of room and the page doesn't move, it pans
with two fingers.

## Proof that it catches real bugs

`robot/old-commit.sh` builds an old commit with the same robot hook and runs the robot on it:

| Bug | Commit before the fix | What the robot sees |
|---|---|---|
| The eraser erased when a pan started | `433b915` (fixed in `9fc7ed6`) | See `docs/robot-report.md` |
| Writing jittered while autosave encoded on the main thread | `004c6bb` (fixed in `51326ef`) | See `docs/robot-report.md` |
| The page moved to a new line in the middle of a word | `8548c11` (fixed in `494c47d`) | See `docs/robot-report.md` |

## What it can't cover: Karthik's hand-test list

1. **A real finger on a real trackpad:** sensor noise, palm shape and how it feels. The robot's touches
   start after the driver, and its recorded palms come from this Mac's trackpad only.
2. **macOS gestures that grab touches first:** three-finger Look Up, Mission Control and swipes between
   spaces. Injected frames skip the system, so a clash there is invisible to the robot.
3. **Full screen:** it would take over the screen. The robot covers the same sizes with large windows.
4. **The pointer lock:** the robot runs with the dry-run lock. Check once that the pointer freezes in draw
   mode and comes back with Esc.
