# Usage counts (analytics)

Scrawl counts which features get used, so we can tell whether people come back, which modes they use, and
where they give up. It never records ink, page images, handwriting text or file names.

## How it works

- `Analytics.shared.record(name, props)` only appends to an in-memory queue of up to 2,000 events, under a
  lock held for that one append. It can't block drawing:
  - p99 is 0.67 µs per call on the main thread (bench);
  - when the queue is full, events are dropped;
  - recording takes 1.4 ms per 10,000 events, even while the sink is stalled.
- A background queue writes the batch every 30 s, and at quit, to:
  - **the local log**, `~/Library/Logs/Scrawl/events.jsonl`. It rotates at 1 MB and keeps two files.
  - **PostHog** (US Cloud), from release builds only, since 0.1.3: `POSTHOG_PROJECT_TOKEN` in `release.conf`
    goes into release builds; development builds always leave it empty and send nothing.
- A failed send is tried again 30 s later, then after 2, 4, 8 and 16 minutes (an hour at most), and
  dropped after 6 tries: nothing ever retries in a loop.
- Props are filtered to an allow-list of keys. Values can only be numbers, true/false, or words of 32
  characters or fewer. Anything else is dropped before it's queued.
- Every event carries:
  - an anonymous install ID (a random UUID; PostHog receives only its SHA-256 hash);
  - a session ID (new each launch);
  - the app version and build, and the macOS major version;
  - the time, to the second.
- The first launch shows a one-time notice. **Settings › Share anonymous usage counts** turns it all off:
  the queue is cleared, and nothing more is written or sent.
- Test runs never read or write the real settings and never send anything.

## Events

| Event | Props | Question it answers |
|---|---|---|
| `session_start` | - | Do people come back (day 1, day 7 return)? How often? |
| `session_end` | `minutes` | How long do sessions last? Do they get longer? |
| `notice_shown` | - | How many installs saw the notice (the denominator for everything else) |
| `draw_mode` | `on`, `source` (key, toolbar, menu, hotkey) | Do people find draw mode, and how (button vs shortcut)? |
| `draw_mode_empty` | `seconds` | **Where people give up:** draw mode entered and left without a stroke |
| `first_stroke` | `seconds` (since launch) | Time to first ink (activation) |
| `strokes` | `count` (per draw-mode span) | How much people write per span |
| `tool` | `tool`, `source` | Most-used tools; are marker and highlighter used at all? |
| `writing_mode` | `on`, `source` | Is writing mode the main way to write? |
| `zoom_lock` | `on`, `source` | Is the lock used, and does its tip help? |
| `undo` / `redo` | `source` (key, toolbar, menu, gesture) | Do gestures replace ⌘Z (the tip's goal)? |
| `undo_burst` | `count` (≥ 3 undos within 2 s) | **Where people struggle:** peeling off a word stroke by stroke |
| `undo_scrub` | `steps` | Is the scrub found and used? |
| `scratch_out` | `strokes` | Is scratch-out used? Does it replace undo bursts and the eraser? |
| `new_line` | `kind` (auto, manual) | Does writing mode do the work, or do people press Return? |
| `auto_pan` | - | How much the page moves for people |
| `new_page` | `pages` | Notebook growth |
| `overview` | `pages` | Do people navigate by the overview? |
| `overview_search` | `result` (found, none) | Is handwriting search useful? |
| `export` | `format` (pdf, png, svg) | Do people take their pages out? |
| `share` / `copy_page` / `copy_selection` | - | Sharing, the other way out |
| `tip_shown` | `tip` | Which tips fire, and how often |
| `practice` | `step` (started, write, undo, scratch, overview, finished) | **Onboarding funnel:** where people stop |
| `settings_changed` | `key` (the setting's name only, never its value) | Which settings matter |
| `page_map` | `on` | Is the map wanted? |
| `resume` | - | How often draw mode brings people back to their spot |
| `error` | `category` (load_failed, input_stalled, export_failed) | What goes wrong in the field |
| `crash_detected` | - | The last session ended without quitting |

Retention: return within 7 days = an install ID with `session_start` on day 0 and again on days 1–7.
Activation: `first_stroke` within the first session, then `practice` finished or 20+ strokes.

## Never recorded

Stroke points, page images, OCR text, search queries, page titles, file names or paths, export
destinations, window titles, settings values, IP-derived location (every event sets `$geoip_disable`; no person profiles: `$process_person_profile` is false),
anything typed.

## How remote counts are set up (on since 0.1.3)

1. A PostHog project called "Scrawl" on **US Cloud** (`POSTHOG_HOST=https://us.i.posthog.com` in
   `release.conf`). No SDK is needed: Scrawl speaks PostHog's batch API directly, as their iOS/macOS SDK does.
2. In the project's settings, turn on **Discard client IP data**, so PostHog doesn't keep IP addresses.
3. Copy the project token (it starts with `phc_`) into `release.conf`: `POSTHOG_PROJECT_TOKEN=phc_...`. It's
   meant to be public (write-only), so it's fine in the repo and the app.
4. `scripts/release.sh` builds it in. Builds without a token (every development build) send nothing.

The free tier allows far more events than Scrawl will send at launch (a session sends roughly 30–50).
