# Robot user: results

`make robot` runs the robot user (see [robot/README.md](../robot/README.md)) against the built app and
writes `build/robot/report.html`, with a screenshot for every step. This page records the run that
proved it catches real bugs.

## Main (7789f1e + fixes): 51 of 51 checks pass

The run covers 20 scenarios in about 13 minutes, in the background:
- toggles from keys and the toolbar;
- writing mode at zoom 1 and 3, in every line width and pan mode;
- double-tap undo and redo;
- the eraser, including a pan that starts on ink;
- pages and the overview;
- four window shapes;
- a 9,000-stroke notebook;
- a recorded session;
- quit and relaunch.

| Measure | Main |
|---|---|
| Page moves inside a word (11 writing runs, 7–18 words each) | 0 |
| Longest main-thread stall while writing on a 9,000-stroke notebook | 25 ms (0 over 50 ms) |
| Strokes kept when replaying 45 s of Karthik's touches (palms included) | 60 (the session kept 59) |
| Strokes back after quit and relaunch | all, on every page |
| Key press to visible change, seen from outside | 120–250 ms (upper bound, see below) |

![Writing mode at zoom 3 on main](robot/main-write-zoom3.jpg)

## The same robot on old commits with known bugs

`robot/old-commit.sh <commit>` builds an old commit with the same robot hook and runs the same scenarios.

| Bug | Old commit | Robot on the old commit | Robot on main |
|---|---|---|---|
| The eraser erased at the start of a pan | `433b915` (fixed in `9fc7ed6`) | **FAIL**: an eraser touch followed by a two-finger pan erased a stroke (7 → 6) | pass (7 → 7) |
| Writing froze while autosave encoded on the main thread | `004c6bb` (fixed in `51326ef`) | **FAIL**: main-thread stalls up to 299 ms, 37 over 50 ms | pass: longest 25 ms, 0 over 50 ms |
| The page moved to a new line in the middle of a word | `8548c11` (fixed in `494c47d`) | **FAIL**: the page moved inside "jumps", "quick", "brown", "lazy" and "dog" | pass: 0 moves inside a word |

The old commit, mid-word moves: "jumps" is split across lines, and stray letters sit where the page moved away.

![8548c11: words split by page moves](robot/old-8548c11-newline-midword.jpg)

## What the numbers don't say

- **Key timings are upper bounds.** They include posting the key (about 5 ms), holding it 15 ms, polling
  (about 10 ms), and macOS delivering events to an app in the background, which it throttles. In-app click
  to frame is measured by `checks/gallery_speed.sh`: 5–35 ms.
- **No ink latency from the robot.** Its window sits behind the windows you're using, so macOS doesn't
  present its frames. Ink latency comes from `checks/e2e.sh`. The robot measures main-thread stalls
  instead; a stall is the frozen ink a user sees.
- Not covered (Karthik's hand-test list): a real finger on the trackpad (sensor noise, palms, feel), and
  macOS gestures that take touches before the app (Look Up, Mission Control, swipes between spaces).
