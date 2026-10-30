#!/usr/bin/env python3
"""Robot user: drives the real built Scrawl.app the way a person does, in the background.

    make robot                          # build, run every scenario, write build/robot/report.html
    robot/robot.py [--app PATH] [--out DIR] [--only a,b] [--list]

Input goes in where a person's does:
  * touches: frames into the trackpad callback (Multitouch.onFrame), through the app's --test-robot hook
    (dev builds only), on an 8 ms clock like the driver. Handwriting is Hershey script/roman letters with
    a hand's jitter and rhythm, or Karthik's recorded touch frames (palms included).
  * keys: real CGEvents posted to the app's process (robot-input), so the app never takes focus and the
    pointer of whoever is using the Mac doesn't move.
  * toolbar clicks: AppKit mouse events through window.sendEvent inside the app (macOS drops CGEvent
    clicks posted to an app in the background).

Checks are what a user would see: window screenshots, Vision OCR of the written text, the app's state
(mode, tool, page, view), the saved notebook after quit and relaunch, and timing (input to first frame,
frame gaps while writing, ink latency).
"""
import argparse, glob, html, json, math, os, random, shutil, subprocess, sys, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
KEY = {"a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14,
       "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "]": 30, "o": 31, "u": 32, "[": 33,
       "i": 34, "p": 35, "return": 36, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46, "space": 49, "delete": 51, "esc": 53,
       "left": 123, "right": 124, "down": 125, "up": 126}
SENTENCE = "the quick brown fox jumps over the lazy dog"


# ---------------------------------------------------------------- handwriting

def load_font(path):
    """Hershey .jhf (one glyph per line, ASCII 32 upward): {char: (left, right, [[(x, y)...]...])}."""
    out = {}
    for k, line in enumerate(open(path, encoding="ascii").read().split("\n")[:96]):
        b = line.encode()
        if len(b) < 10: continue
        d = b[8:]
        strokes, i = [[]], 2
        while i + 1 < len(d):
            if d[i] == 32 and d[i + 1] == 82: strokes.append([])
            else: strokes[-1].append((d[i] - 82, -(d[i + 1] - 82)))
            i += 2
        out[chr(32 + k)] = (d[0] - 82, d[1] - 82, [s for s in strokes if s])
    return out


class Hand:
    """A writer: letters from a Hershey font, cap height `h` mm on the pad, ~45 mm/s, a little wobble, and
    Karthik's rhythm (in-word lifts ~0.15 s, a pause before each word that the page may use)."""
    def __init__(self, seed=1, h=6.0):
        self.rng = random.Random(seed)
        self.h = h
        self.script = load_font(os.path.join(ROOT, "robot/fonts/scripts.jhf"))
        self.roman = load_font(os.path.join(ROOT, "robot/fonts/rowmans.jhf"))

    def width(self, word, font=None):
        f = font or self.script
        s = self.h / 21
        return sum((f[c][1] - f[c][0]) * s for c in word if c in f)

    def word(self, word, x, y, font=None):
        """Strokes (lists of pad-mm points) for `word` with its left baseline at (x, y)."""
        f = font or self.script
        s = self.h / 21
        out = []
        dx, dy = self.rng.gauss(0, 0.15), self.rng.gauss(0, 0.15)
        for c in word:
            if c not in f: continue
            left, right, strokes = f[c]
            for st in strokes:
                out.append([(x + (px - left) * s + dx, y + py * s + dy) for px, py in st])
            x += (right - left) * s
        return out

    def frames(self, strokes, cid, in_word_gap=0.15, speed=45.0):
        """Touch frames [dt, [[id, x, y, pressure, size, major]]] for strokes written one after another."""
        fr = []
        for k, st in enumerate(strokes):
            path = []
            for (ax, ay), (bx, by) in zip(st, st[1:]):
                n = max(1, int(math.hypot(bx - ax, by - ay) / (speed * 0.008)))
                path += [(ax + (bx - ax) * u / n, ay + (by - ay) * u / n) for u in range(n)]
            path.append(st[-1])
            while len(path) < 4: path.append(path[-1])
            cid += 1
            for i, (px, py) in enumerate(path):
                p = 10 + 25 * math.sin(math.pi * (i + 1) / (len(path) + 1))
                fr.append([0.008, [[cid, px + self.rng.gauss(0, 0.05), py + self.rng.gauss(0, 0.05), p, 0.5, 7.5]]])
            fr.append([0.008, []])
            if k < len(strokes) - 1:
                fr += [[0.008, []]] * max(1, int(self.rng.uniform(0.8, 1.2) * in_word_gap / 0.008))
        return fr, cid


def two_finger(cx, cy, d0, d1, shift=(0, 0), dur=0.5, cid=900):
    """Two fingers `d0` mm apart around (cx, cy), spreading to `d1` while the centre moves by `shift`."""
    n = int(dur / 0.008)
    fr = []
    for i in range(n + 1):
        u = i / n
        d = d0 + (d1 - d0) * u
        x, y = cx + shift[0] * u, cy + shift[1] * u
        fr.append([0.008, [[cid, x - d / 2, y, 15, 0.5, 7.5], [cid + 1, x + d / 2, y, 15, 0.5, 7.5]]])
    return fr + [[0.008, []], [0.25, []]]


def double_tap(n_fingers, cx, cy, cid=700):
    fr = []
    for tap in range(2):
        cs = [[cid + tap * 10 + k, cx + (k - (n_fingers - 1) / 2) * 18, cy, 12, 0.5, 7.5] for k in range(n_fingers)]
        fr += [[0.008, cs]] * 10 + [[0.008, []]]
        if tap == 0: fr += [[0.008, []]] * 18   # ~150 ms between the taps
    return fr + [[0.4, []]]


# ---------------------------------------------------------------- the app

def close_crash_dialogs():
    """A crashed app's report dialog would sit on the screen of the person using the Mac: close it (the app
    turns reports off in robot runs; this is the fallback). Returns the dialog pids closed."""
    tool = os.path.join(ROOT, "build/crashdialogs")
    if not os.path.exists(tool): return []
    found, t0 = [], time.time()
    while time.time() - t0 < 6:
        found += subprocess.run([tool, "--close"], capture_output=True, text=True).stdout.split()
        time.sleep(0.2)
    return found


class App:
    def __init__(self, binary, out, data, input_tool, label):
        self.binary, self.out, self.data, self.input_tool, self.label = binary, out, data, input_tool, label
        self.ctl = os.path.join(out, "ctl-" + label)
        self.n = 0
        self.proc = None

    def launch(self):
        shutil.rmtree(self.ctl, ignore_errors=True)
        os.makedirs(self.ctl)
        os.makedirs(self.data, exist_ok=True)
        env = dict(os.environ, TRACKPAD_DRAW_DATA=self.data, TRACKPAD_DRAW_DRYLOCK="1")
        self.proc = subprocess.Popen([self.binary, "--test-robot", self.ctl, "--no-activate"], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        t0 = time.time()
        while not os.path.exists(os.path.join(self.ctl, "ready")):
            if time.time() - t0 > 20 or self.proc.poll() is not None: raise RuntimeError("app did not start (no --test-robot hook in this build?)")
            time.sleep(0.05)
        self.pid, self.win = map(int, open(os.path.join(self.ctl, "ready")).read().split())
        self.n = 0
        time.sleep(0.8)

    def cmd(self, c, timeout=180):
        self.n += 1
        p = os.path.join(self.ctl, f"cmd-{self.n}.json")
        open(p + ".tmp", "w").write(json.dumps(c))
        os.rename(p + ".tmp", p)
        r = os.path.join(self.ctl, f"res-{self.n}.json")
        t0 = time.time()
        while not os.path.exists(r):
            if time.time() - t0 > timeout: raise RuntimeError(f"no answer to {c.get('cmd')}")
            if self.proc.poll() is not None:
                self.dialogs = close_crash_dialogs()
                raise RuntimeError(f"app exited during {c.get('cmd')} (status {self.proc.poll()})")
            time.sleep(0.003)
        return json.load(open(r))

    def state(self): return self.cmd({"cmd": "state"})

    def key(self, name, mods=""):
        subprocess.run([self.input_tool, "key", str(self.pid), str(KEY[name])] + ([mods] if mods else []), check=True)

    def press(self, name, mods="", until=None, wait=1.5):
        """A key press; returns (state, ms until the app showed the change) if `until(state)` is given. The ms
        include posting the key (~5 ms), holding it 15 ms and polling (~10 ms)."""
        self.cmd({"cmd": "mark"})
        t0 = time.time()
        self.key(name, mods)
        if until is None:
            time.sleep(0.25); return self.state(), None
        while time.time() - t0 < wait:
            s = self.state()
            if until(s): return s, (time.time() - t0) * 1000
            time.sleep(0.005)
        return self.state(), None

    def click(self, item, how="plain"):
        r = self.cmd({"cmd": "click", "item": item, "how": how})
        time.sleep(0.25)
        return r

    def touch(self, frames, settle=0.6): return self.cmd({"cmd": "touch", "frames": frames, "settle": settle})

    def shot(self, path):
        subprocess.run(["screencapture", "-x", "-o", f"-l{self.win}", path], check=False)
        return path

    def quit(self):
        try: self.cmd({"cmd": "quit"}, timeout=10)
        except RuntimeError: pass
        try: self.proc.wait(10)
        except subprocess.TimeoutExpired: self.proc.kill()

    def kill(self):
        if self.proc and self.proc.poll() is None: self.proc.kill(); self.proc.wait()


# ---------------------------------------------------------------- checks

def ocr(png, expected):
    """Character accuracy of Vision's reading of `png` against `expected` (0..1), and the text read."""
    tool = os.path.join(ROOT, "build/robot-ocr")
    r = subprocess.run([tool, png, expected], capture_output=True, text=True)
    try: return json.loads(r.stdout)
    except ValueError: return {"accuracy": 0.0, "text": r.stdout.strip()[:200]}


def ink_pixels(png):
    """Count of dark, saturated or grey pixels that aren't paper (rough 'is there ink' check)."""
    tool = os.path.join(ROOT, "build/robot-ocr")
    r = subprocess.run([tool, png, "--ink"], capture_output=True, text=True)
    try: return json.loads(r.stdout)["ink"]
    except ValueError: return -1


class Report:
    def __init__(self, out):
        self.out, self.scenarios = out, []
        self.cur = None

    def begin(self, name, about):
        self.cur = {"name": name, "about": about, "steps": [], "checks": [], "shots": [], "error": None, "t0": time.time()}
        self.scenarios.append(self.cur)

    def step(self, what, **kw): self.cur["steps"].append(dict(what=what, **kw))

    def check(self, ok, what, detail=""):
        self.cur["checks"].append({"ok": bool(ok), "what": what, "detail": detail})
        print(("  PASS " if ok else "  FAIL ") + what + (f"  ({detail})" if detail else ""), flush=True)

    def shot(self, app, label):
        name = f"{self.cur['name']}-{len(self.cur['shots']) + 1}.png"
        p = app.shot(os.path.join(self.out, "shots", name))
        self.cur["shots"].append({"file": "shots/" + name, "label": label})
        return p

    def end(self): self.cur["secs"] = round(time.time() - self.cur["t0"], 1)

    def write(self, meta):
        n_ok = sum(c["ok"] for s in self.scenarios for c in s["checks"])
        n = sum(len(s["checks"]) for s in self.scenarios)
        data = {"meta": meta, "passed": n_ok, "checks": n, "scenarios": self.scenarios}
        json.dump(data, open(os.path.join(self.out, "report.json"), "w"), indent=1, default=str)
        e = lambda x: html.escape(str(x))
        rows = []
        for s in self.scenarios:
            bad = [c for c in s["checks"] if not c["ok"]]
            status = "error" if s["error"] else ("fail" if bad else "pass")
            checks = "".join(f'<li class="{"ok" if c["ok"] else "bad"}">{"✓" if c["ok"] else "✗"} {e(c["what"])}'
                             f'{(" <span class=d>" + e(str(c["detail"])) + "</span>") if c["detail"] else ""}</li>' for c in s["checks"])
            steps = "".join(f"<tr><td>{e(st['what'])}</td><td>{e(', '.join(f'{k}={v}' for k, v in st.items() if k != 'what'))}</td></tr>" for st in s["steps"])
            shots = "".join(f'<figure><a href="{e(x["file"])}"><img src="{e(x["file"])}" loading=lazy></a><figcaption>{e(x["label"])}</figcaption></figure>' for x in s["shots"])
            err = f'<pre class=bad>{e(s["error"])}</pre>' if s["error"] else ""
            rows.append(f'<section class="{status}"><h2>{e(s["name"])} <small>{status.upper()} · {s.get("secs", "?")} s</small></h2>'
                        f'<p>{e(s["about"])}</p>{err}<ul>{checks}</ul><details><summary>steps and timings</summary><table>{steps}</table></details>'
                        f'<div class=shots>{shots}</div></section>')
        page = f"""<!doctype html><meta charset=utf-8><title>Scrawl robot user: {e(meta.get('label', ''))}</title>
<style>body{{font:14px -apple-system,system-ui;margin:24px;max-width:1200px;color:#222}}h1{{font-size:22px}}
section{{border:1px solid #ddd;border-radius:10px;padding:12px 16px;margin:14px 0}}section.fail,section.error{{border-color:#d33}}
h2{{font-size:16px;margin:4px 0}}small{{color:#888;font-weight:normal}}.ok{{color:#1a7f37}}.bad{{color:#c62828}}.d{{color:#777}}
ul{{list-style:none;padding-left:4px}}.shots{{display:flex;flex-wrap:wrap;gap:8px}}figure{{margin:0;width:280px}}
img{{width:280px;border:1px solid #ccc;border-radius:6px}}figcaption{{font-size:12px;color:#555}}table{{font-size:12px}}td{{padding:1px 8px;vertical-align:top}}</style>
<h1>Scrawl robot user · {e(meta.get('label', ''))}</h1>
<p><b>{n_ok}/{n}</b> checks passed · build {e(meta.get('commit', ''))} · {e(meta.get('when', ''))} · {e(meta.get('secs', ''))} s</p>
<p class=d>{e(meta.get('note', ''))}</p>{''.join(rows)}"""
        open(os.path.join(self.out, "report.html"), "w").write(page)
        return n_ok, n


# ---------------------------------------------------------------- scenarios

def ensure(app, field, value, key):
    """Press `key` only if `field` isn't `value` already (scenarios don't inherit each other's modes)."""
    if app.state()[field] != value: app.press(key, until=lambda s: s[field] == value)


def settle(app, quiet=0.12, limit=1.5):
    """Wait until the view has stopped moving (a person waits for the page before writing on)."""
    t0, last, since = time.time(), None, time.time()
    while time.time() - t0 < limit:
        v = app.state()["view"]
        if v != last: last, since = v, time.time()
        elif time.time() - since >= quiet: break
        time.sleep(0.02)
    return last


def write_words(app, hand, words, line_y, x0, cid, rep, font=None, nudge_every=0, nudge_frac=0.0, pinch_at=None, jump_after=None, jump_pad_x=None, stop_on_new_line=False, jump_shift=0.22):
    """Write `words` like a person in writing mode. Each word goes just after the last word, where that is
    on the screen now (the page may have moved); when the page has gone to a new line, the next word starts
    that line, below the line's first word. With no room left on the pad (there is no sideways pan), the
    person pans with two fingers. Returns one record per word."""
    pad_w, pad_h = app.state()["padMM"]
    line = None   # this line in page units: left x, baseline y, ink height
    recs = []
    last_hand = 0.0   # when the robot last moved the page by hand (that's meant to show the page map)
    for wi, w in enumerate(words):
        settle(app)
        if nudge_every and wi > 0 and wi % nudge_every == 0:   # a small hand nudge right, as a writer does
            app.touch(two_finger(pad_w * 0.6, pad_h * 0.3, 25, 25, shift=(-pad_w * 0.9 * nudge_frac, 0), dur=0.3)); last_hand = time.time(); settle(app)
        if pinch_at is not None and wi == pinch_at:              # and a small pinch
            app.touch(two_finger(pad_w * 0.6, pad_h * 0.3, 25, 26.5, dur=0.3)); last_hand = time.time(); settle(app)
        jumped = False
        if jump_after is not None and wi == jump_after + 1 and line is not None:   # a deliberate pan right, then write somewhere new
            app.touch(two_finger(pad_w * 0.6, pad_h * 0.3, 25, 25, shift=(-pad_w * jump_shift, 0), dur=0.5)); last_hand = time.time(); settle(app)
            jumped = True
        st = app.state()
        width = hand.width(w, font)
        if line is None:
            x, y = x0, line_y
        elif jumped:
            last = st["lastStrokes"][-1]
            (lx, y), = app.cmd({"cmd": "toPad", "points": [[last[2], line["y"]]]})["points"]
            x = jump_pad_x if jump_pad_x is not None else lx + pad_w * 0.18   # a gap: well past the next word's place
        else:
            last = st["lastStrokes"][-1]
            (x, y), = app.cmd({"cmd": "toPad", "points": [[last[2], line["y"]]]})["points"]
            x += hand.h * 0.9
            if x + width > pad_w * 0.95:
                app.touch(two_finger(pad_w / 2, pad_h / 2, 25, 25, shift=(-(pad_w * 0.45), 0), dur=0.5))
                last_hand = time.time()
                settle(app)
                (x, y), = app.cmd({"cmd": "toPad", "points": [[last[2], line["y"]]]})["points"]
                x += hand.h * 0.9
        strokes = hand.word(w, x, y, font)
        fr, cid = hand.frames(strokes, cid)
        fr += [[0.008, []]] * int(0.55 / 0.008)   # the pause after the word (> 400 ms: the page may move now)
        before = app.state()["view"]
        hand_moved = time.time() - last_hand < 2.0
        r = app.touch(fr, settle=0.05)
        map_seen = r.get("mapSeen", 0)
        # A move the app still has queued (the chevron shows; a word past the limit waits 650-800 ms): wait for it, as a
        # person seeing the chevron does, so it isn't missed (it raced the 0.55 s pause).
        for _ in range(40):
            if not app.state().get("pendingMove"): break
            time.sleep(0.05)
        after_view = settle(app)
        map_seen += 1 if app.state().get("pageMap") else 0
        after = app.state()
        views = [d["view"] for d in r["downs"]]
        moved = any(any(abs(v[k] - views[0][k]) > 1e-6 for k in ("x", "y", "zoom")) for v in views)
        new = after["lastStrokes"][-len(strokes):]
        if line is None and new:
            # Where this word sits on the page: from the pad point it was written at and the view at the time.
            bx = min(b[0] for b in new)
            line = {"x": bx, "y": min(b[1] for b in new) + (max(b[3] for b in new) - min(b[1] for b in new)) * 0.05,
                    "h": max(b[3] for b in new) - min(b[1] for b in new)}
        new_line = after["view"]["y"] < before["y"] - (line["h"] * 0.5 if line else 1)
        wb = [min(b[0] for b in new), min(b[1] for b in new), max(b[2] for b in new), max(b[3] for b in new)] if new else None
        recs.append({"jumped": jumped, "word": w, "midWordMove": moved, "newLine": new_line, "view": after["view"], "before": before, "bounds": wb, "mapSeen": map_seen, "handMoved": hand_moved})
        if new_line and line:
            # The next word starts the new line: below this line's first word.
            nl = {"x": line["x"], "y": line["y"] - max(line["h"] * 1.6, after["view"]["h"] * 0.12), "h": line["h"]}
            (x0, line_y), = app.cmd({"cmd": "toPad", "points": [[nl["x"], nl["y"]]]})["points"]
            line = None
            if stop_on_new_line: break
    return recs, cid


def scenario_writing(app, rep, hand, zoom, width_index, words):
    """Writing mode at `zoom`, line width ½/¾/full (no sideways pan: the writer pans by hand when the pad runs out):
    a sentence across the line, a pause, the next line."""
    st = app.state()
    pad_w, pad_h = st["padMM"]
    # Set up the way a person does: the writing panel (chevron) for the width, W for writing mode.
    if not st["writing"]: app.press("w", until=lambda s: s["writing"])
    app.click("writing", "chevron")
    app.cmd({"cmd": "panelPick", "writing": width_index})
    app.press("esc")
    s, ms = app.press("d", until=lambda s: s["draw"])
    if not s["draw"]: app.click("draw"); s = app.state()   # builds from before D entered draw mode
    rep.step("D enters draw mode", ms=round(ms or -1))
    app.cmd({"cmd": "menu", "action": "resetZoom"}); settle(app)   # from the whole page (draw mode resumes at the last zoom)
    if zoom > 1:
        app.touch(two_finger(pad_w / 2, pad_h * 0.6, 15, 15 * zoom, dur=0.6))
        time.sleep(1.6)   # the page map shown by the pinch fades before writing starts
    st = app.state()
    rep.step("view", zoom=round(st["view"]["zoom"], 2), lineWidth=st["lineWidth"])
    app.cmd({"cmd": "mark"})
    recs, _ = write_words(app, hand, words, pad_h * 0.62, pad_w * 0.12, 1000, rep)
    st = app.state()
    return recs, st


CAP = 0.95   # the line's limit is capped here (fraction of the page width): reachable inside the pad's edge guard

def run_scenarios(app, rep, only, hand):
    S = {}

    def scenario(name, about):
        def deco(f): S[name] = (about, f); return f
        return deco

    @scenario("first-look", "Launch: the page, the toolbar and the hint at the top; no draw mode yet.")
    def _():
        st = app.state()
        rep.shot(app, "just launched")
        rep.check(not st["draw"] and not st["writing"] and st["tool"] == "pen", "starts out of draw mode with the pen", f"{st['tool']}")
        rep.check(not st["toolbarHidden"], "toolbar visible")

    @scenario("toggles", "E, W, D and L from the keyboard and the toolbar, from different modes; each press turns its mode on, the next turns it off. Draw mode shows a note when a tool changes.")
    def _():
        s, ms = app.press("e", until=lambda s: s["tool"] == "eraser" and s["draw"])
        rep.check(s["tool"] == "eraser" and s["draw"], "E outside draw mode: eraser, draw mode on", f"{ms and round(ms)} ms")
        rep.step("E", ms=round(ms or -1), frames=s["frames"])
        rep.shot(app, "E: eraser in draw mode (note at the top)")
        rep.check("Eraser" in s.get("toast", ""), "a note says Eraser", s.get("toast"))
        s, ms = app.press("e", until=lambda s: s["tool"] == "pen")
        rep.check(s["tool"] == "pen" and s["draw"], "E again: back to the pen, still in draw mode", f"{ms and round(ms)} ms")
        rep.check("Eraser off" in s.get("toast", ""), "a note says the eraser is off", s.get("toast"))
        rep.shot(app, "E again: 'Eraser off · Pen'")
        s, ms = app.press("w", until=lambda s: s["writing"]); rep.check(s["writing"], "W in draw mode: writing on")
        s, ms = app.press("w", until=lambda s: not s["writing"]); rep.check(not s["writing"], "W again: writing off")
        s, ms = app.press("l", until=lambda s: s["zoomLocked"]); rep.check(s["zoomLocked"] and "Zoom locked" in s.get("toast", ""), "L: zoom locked, with a note", s.get("toast"))
        s, ms = app.press("l", until=lambda s: not s["zoomLocked"]); rep.check(not s["zoomLocked"], "L again: unlocked")
        s, ms = app.press("d", until=lambda s: not s["draw"]); rep.check(not s["draw"] and not s["toolbarHidden"], "D: out of draw mode, toolbar back", f"{ms and round(ms)} ms")
        for item, key, field, on in [("writing", None, "writing", True), ("writing", None, "writing", False), ("zoomLock", None, "zoomLocked", True), ("zoomLock", None, "zoomLocked", False)]:
            app.cmd({"cmd": "mark"}); app.click(item); s = app.state()
            rep.check(s[field] == on and not s["panelOpen"], f"toolbar {item}: {field} {'on' if on else 'off'}, no panel")
        app.click("writing"); rep.shot(app, "toolbar with writing on (highlighted)"); app.click("writing")
        r = app.click("eraser"); s = app.state()
        rep.step("toolbar eraser click to first frame", ms=r.get("firstFrameMs") and round(r["firstFrameMs"], 1))
        rep.check(s["tool"] == "eraser" and s["draw"], "toolbar eraser outside draw mode: eraser, draw mode on", f"first frame {r.get('firstFrameMs') and round(r['firstFrameMs'])} ms after the click")
        app.press("d", until=lambda s: not s["draw"]); app.click("eraser"); s = app.state()
        rep.check(s["tool"] == "pen" and not s["draw"], "toolbar eraser again (out of draw mode): pen, draw mode stays off")
        app.click("marker", "chevron"); s = app.state()
        rep.check(s["panelOpen"] and s["tool"] == "pen", "the marker's chevron opens its panel without picking it")
        rep.shot(app, "marker chevron: sizes and colours")
        app.press("esc")

    @scenario("write-zoom1", "Writing mode at zoom 1, full width: a sentence across the line, pauses, the next line. The page must never move inside a word, nor sideways along the line.")
    def _():
        words = (SENTENCE + " " + SENTENCE).split()
        recs, st = scenario_writing(app, rep, hand, 1, 2, words)
        judge_writing(app, rep, recs, st, " ".join(words))

    @scenario("write-zoom3", "The same at zoom 3 (pinched in with two fingers): no sideways pan (the writer pans by hand when the pad runs out); the next line where the width runs out.")
    def _():
        app.press("n", until=lambda s: s["page"] > 0 or True)
        words = (SENTENCE + " " + SENTENCE).split()
        recs, st = scenario_writing(app, rep, hand, 3, 2, words)
        judge_writing(app, rep, recs, st, " ".join(words))

    for wi, wname in enumerate(["half", "three-quarter"]):   # (full: write-zoom3)
        def make(wi=wi):
            def f():
                app.press("n")
                recs, st = scenario_writing(app, rep, hand, 3, wi, SENTENCE.split()[:7])
                judge_writing(app, rep, recs, st, " ".join(SENTENCE.split()[:7]), ocr_check=False)
            return f
        S[f"write-{wname}"] = (f"Writing mode at zoom 3, {wname} line width: seven words, no sideways pan, the new line where the width runs out.", make())

    @scenario("pan-right-by-hand", "Karthik's case: start a line, pan right with two fingers past the line width, keep writing there and pause. The page must stay where he put it (no jump back to the margin).")
    def _():
        app.press("n")
        st = app.state()
        if not st["writing"]: app.press("w", until=lambda s: s["writing"])
        app.click("writing", "chevron"); app.cmd({"cmd": "panelPick", "writing": 0}); app.press("esc")
        if not app.state()["draw"]: app.press("d", until=lambda s: s["draw"])
        st = app.state(); pad_w, pad_h = st["padMM"]
        app.cmd({"cmd": "menu", "action": "resetZoom"}); settle(app)        # View › Zoom to Whole Page
        app.touch(two_finger(pad_w / 2, pad_h * 0.6, 15, 30, dur=0.6))   # then pinch to zoom 2
        recs, cid = write_words(app, hand, ["start", "here"], pad_h * 0.55, pad_w * 0.08, 9700, rep)
        settle(app)
        app.touch(two_finger(pad_w * 0.75, pad_h * 0.5, 25, 25, shift=(-40, 0), dur=0.6))   # pan right by hand, twice,
        app.touch(two_finger(pad_w * 0.75, pad_h * 0.5, 25, 25, shift=(-35, 0), dur=0.6))   # well past the ½-page line
        settle(app)
        lim = app.state()
        rep.step("after the hand pan", viewX=round(lim["view"]["x"]), viewRight=round(lim["view"]["x"] + lim["view"]["w"]), pageW=lim.get("pageW"))
        rep.check(lim["view"]["x"] + lim["view"]["w"] > lim["pageW"] * 0.56 + 60, "the hand pan reached past the ½-page line (the case to test)",
                  f"view {lim['view']['x']:.0f}-{lim['view']['x'] + lim['view']['w']:.0f} of {lim['pageW']:.0f}")
        a = app.state()
        (lx, ly), = app.cmd({"cmd": "toPad", "points": [[lim["pageW"] * 0.56, lim["view"]["y"] + lim["view"]["h"] * 0.5]]})["points"]
        fr, cid = hand.frames(hand.word("there", lx, pad_h * 0.55), cid)   # just past the ½-page line
        app.touch(fr + [[0.008, []]] * 100)
        settle(app); b = app.state()
        rep.check(abs(b["view"]["x"] - a["view"]["x"]) < 1e-6 and abs(b["view"]["y"] - a["view"]["y"]) < 1e-6,
                  "after panning right by hand, writing there keeps the page where it is", f"view x {a['view']['x']:.0f} -> {b['view']['x']:.0f}, y {a['view']['y']:.0f} -> {b['view']['y']:.0f}")
        rep.shot(app, "wrote after panning right by hand")
        app.press("d", until=lambda s: not s["draw"])

    @scenario("page-map", "Zoomed in past 1.5x, a small map of the page shows the view's place; clicking or dragging it moves the view; View › Page Map turns it off. At the whole page it stays away.")
    def _():
        if app.state()["draw"]: app.press("d", until=lambda s: not s["draw"])
        app.press("n")
        app.cmd({"cmd": "menu", "action": "resetZoom"}); settle(app)
        s0 = app.state()
        rep.check(not s0.get("pageMap"), "no map at the whole page", f"{s0.get('pageMap')}")
        app.press("d", until=lambda s: s["draw"])
        st = app.state(); pad_w, pad_h = st["padMM"]
        fr, cid = hand.frames(hand.word("map", pad_w * 0.3, pad_h * 0.7, hand.roman), 9800)
        app.touch(fr)
        r = app.touch(two_finger(pad_w / 2, pad_h * 0.6, 15, 45, dur=0.6), settle=0.1)   # pinch to zoom 3
        s1 = app.state()
        rep.check(bool(s1.get("pageMap")) and s1["view"]["zoom"] > 1.5, "pinching in: the page map shows", f"zoom {s1['view']['zoom']:.1f}, map {s1.get('pageMap')}")
        time.sleep(1.9); s1b = app.state()
        rep.check(not s1b.get("pageMap"), "and fades about 1.5 s after the fingers stop", f"{s1b.get('pageMap')}")
        r = app.touch(two_finger(pad_w / 2, pad_h * 0.5, 25, 25, shift=(-15, 0), dur=0.4), settle=0.1)
        rep.check(bool(app.state().get("pageMap")), "a two-finger pan shows it again", "")
        time.sleep(1.9)
        fr, cid = hand.frames(hand.word("ink", pad_w * 0.4, pad_h * 0.4, hand.roman), cid)
        r = app.touch(fr)
        rep.check(r.get("mapSeen", 0) == 0 and not app.state().get("pageMap"), "writing doesn't show it", f"seen in {r.get('mapSeen', 0)} samples")
        app.press("right"); s1 = app.state()
        rep.check(bool(s1.get("pageMap")), "an arrow key pan shows it", "")
        rep.shot(app, "page map at zoom 3 (top right)")
        app.press("d", until=lambda s: not s["draw"])
        app.press("left")   # outside draw mode too: arrow pans show the map (and it stays while the pointer is on it)
        v0 = app.state()["view"]
        app.cmd({"cmd": "clickMap", "x": 0.85, "y": 0.5}); time.sleep(0.2)
        v1 = app.state()["view"]
        rep.check(v1["x"] > v0["x"] + v0["w"] * 0.3, "clicking the map's right side moves the view there", f"view x {v0['x']:.0f} -> {v1['x']:.0f}")
        app.cmd({"cmd": "clickMap", "x": 0.85, "y": 0.5, "to": [0.15, 0.5]}); time.sleep(0.2)
        v2 = app.state()["view"]
        rep.check(v2["x"] < v1["x"] - v1["w"] * 0.3, "dragging on the map moves the view along", f"view x {v1['x']:.0f} -> {v2['x']:.0f}")
        rep.shot(app, "after dragging on the map")
        app.cmd({"cmd": "menu", "action": "togglePageMapAction"}); time.sleep(0.3)
        app.press("right")
        rep.check(not app.state().get("pageMap"), "View › Page Map off: panning doesn't show it")
        app.cmd({"cmd": "menu", "action": "togglePageMapAction"}); time.sleep(0.3)
        app.press("left")
        rep.check(bool(app.state().get("pageMap")), "and on again")

    @scenario("resume", "Write at zoom 3, leave draw mode and zoom out to the whole page, press D: you're back at the end of your last word, at zoom 3, in a quarter second. If you zoomed in somewhere else yourself, D leaves you there.")
    def _():
        if app.state()["draw"]: app.press("d", until=lambda s: not s["draw"])
        app.press("n")
        app.cmd({"cmd": "menu", "action": "resetZoom"}); settle(app)
        app.press("d", until=lambda s: s["draw"])
        st = app.state(); pad_w, pad_h = st["padMM"]
        app.touch(two_finger(pad_w / 2, pad_h * 0.4, 15, 45, dur=0.6)); settle(app)
        fr, cid = hand.frames(hand.word("resume", pad_w * 0.3, pad_h * 0.5), 9850)
        app.touch(fr); settle(app)
        a = app.state(); last = a["lastStrokes"][-1]
        app.press("esc", until=lambda s: not s["draw"])
        app.cmd({"cmd": "menu", "action": "resetZoom"}); settle(app)
        z1 = app.state()["view"]["zoom"]
        t0 = time.time()
        app.press("d", until=lambda s: s["draw"])
        v = settle(app); dt = (time.time() - t0) * 1000
        inside = v["x"] <= last[2] <= v["x"] + v["w"] and v["y"] <= (last[1] + last[3]) / 2 <= v["y"] + v["h"]
        rep.check(z1 < 1.05 and abs(v["zoom"] - a["view"]["zoom"]) < 0.05 and inside,
                  "D from the whole page: back at the last word, at the zoom it was written at", f"zoom {z1:.1f} -> {v['zoom']:.1f} (wrote at {a['view']['zoom']:.1f}), last word in view: {inside}, settled in {dt:.0f} ms")
        across = (last[2] - v["x"]) / v["w"]
        rep.check(0.2 <= across <= 0.6, "with room to keep writing (the last word ends left of the middle)", f"ends {across:.0%} across")
        rep.shot(app, "D from the whole page: back where you were writing")
        app.press("esc", until=lambda s: not s["draw"])
        for _ in range(4): app.press("down")
        b = app.state()["view"]
        app.press("d", until=lambda s: s["draw"]); c = settle(app)
        rep.check(abs(c["x"] - b["x"]) < 0.5 and abs(c["y"] - b["y"]) < 0.5 and abs(c["zoom"] - b["zoom"]) < 1e-3,
                  "moved somewhere else yourself (zoomed in): D stays there", f"view y {b['y']:.0f} -> {c['y']:.0f}")
        app.press("d", until=lambda s: not s["draw"])

    @scenario("draw-chrome", "Draw mode is quiet but unmistakable: a short note on entry that fades in about 2 s, a small capsule with the tool, writing, zoom lock and page, and a thin frame round the window.")
    def _():
        if app.state()["draw"]: app.press("d", until=lambda s: not s["draw"])
        app.press("d", until=lambda s: s["draw"])
        time.sleep(0.3); a = app.state()["chrome"]
        rep.shot(app, "just entered draw mode")
        words = len(a["banner"].split())
        rep.check(0 < words <= 8, "the entry note is short", f"{words} words: {a['banner']!r}")
        time.sleep(2.6); b = app.state()["chrome"]
        rep.check(b["banner"] == "", "the note is gone after about 2 s", repr(b["banner"]))
        rep.check(bool(b.get("capsule")) and b.get("frame") is True, "a capsule shows the state, a frame marks draw mode", f"capsule {b.get('capsule')!r}, frame {b.get('frame')}")
        area = b["bannerArea"] + b.get("capsuleArea", 0) + b["toolbarArea"]
        rep.step("chrome over the page after 3 s (pt²)", area=round(area), banner=round(b["bannerArea"]), capsule=round(b.get("capsuleArea", 0)))
        rep.check(area < 6000, "little chrome over the page while drawing", f"{area:.0f} pt² after 3 s")
        ensure(app, "tool", "eraser", "e"); ensure(app, "writing", True, "w"); time.sleep(0.2)
        c = app.state()["chrome"]
        rep.check("Eraser" in c.get("capsule", "") and "writing" in c.get("capsule", ""), "the capsule follows the tool and writing mode", c.get("capsule"))
        time.sleep(2.2); rep.shot(app, "draw mode: eraser, writing on (capsule at the bottom, frame round the window)")
        ensure(app, "writing", False, "w"); ensure(app, "tool", "pen", "p")
        ensure(app, "draw", False, "d")

    @scenario("toolbar-settings", "The toolbar: Draw first and labelled, the tuning sliders gone from it, a tooltip with the shortcut on every button. Settings (⌘,) has the sliders and switches, and the scratch-out switch really turns it off.")
    def _():
        if app.state()["draw"]: app.press("d", until=lambda s: not s["draw"])
        st = app.state()
        tips = st.get("toolbarTips") or []
        rep.check(len(tips) > 0 and all(tips) and len(tips) <= 15, "every toolbar button has a tooltip; 15 buttons or fewer (with the zoom)", f"{sum(1 for t in tips if t)}/{len(tips)} buttons")
        rep.check(bool(tips) and tips[0].startswith("Draw"), "Draw is the first button", tips[0] if tips else "")
        withkey = sum(1 for t in tips if "(" in t)
        rep.check(withkey >= len(tips) - 1, "tooltips name the shortcut", f"{withkey}/{len(tips)}")
        rep.shot(app, "the regrouped toolbar")
        app.cmd({"cmd": "menu", "action": "showSettings"}); time.sleep(0.6)
        s2 = app.state(); wn = s2.get("settingsWindow", 0)
        rep.check(wn != 0, "Scrawl › Settings… opens the settings window", f"window {wn}")
        if wn:
            p = os.path.join(rep.out, "shots", "toolbar-settings-window.png")
            subprocess.run(["screencapture", "-x", "-o", f"-l{wn}", p])
            rep.cur["shots"].append({"file": "shots/toolbar-settings-window.png", "label": "Settings (⌘,)"})
        sw = s2.get("settingsSwitches") or []
        idx = next((i for i, x in enumerate(sw) if x[0].startswith("Scratch")), None)
        rep.check(idx is not None, "a Scratch out switch", str([x[0] for x in sw]))
        if idx is None: return
        app.cmd({"cmd": "settingsSwitch", "index": idx, "on": False})
        app.press("n"); app.press("d", until=lambda s: s["draw"])
        st = app.state(); pad_w, pad_h = st["padMM"]
        fr, cid = hand.frames(hand.word("off", pad_w * 0.3, pad_h * 0.45, hand.roman), 9950); app.touch(fr); a = app.state()
        lo = app.cmd({"cmd": "toPad", "points": [[min(w[0] for w in a["lastStrokes"]), min(w[1] for w in a["lastStrokes"])]]})["points"][0]
        hi = app.cmd({"cmd": "toPad", "points": [[max(w[2] for w in a["lastStrokes"]), max(w[3] for w in a["lastStrokes"])]]})["points"][0]
        zig = [[(lo[0] + (hi[0] - lo[0]) * (k % 2), lo[1] + (hi[1] - lo[1]) * (0.25 + 0.5 * k / 6)) for k in range(7)]]
        fr, cid = hand.frames(zig, cid, speed=140); app.touch(fr); b = app.state()
        rep.check(b["strokes"] == a["strokes"] + 1, "with scratch-out off, a zig-zag over a word stays as ink", f"{a['strokes']} -> {b['strokes']}")
        app.cmd({"cmd": "settingsSwitch", "index": idx, "on": True})
        app.press("d", until=lambda s: not s["draw"])

    @scenario("tips-practice", "Tips show in context and at most twice: three ⌘Z undos in draw mode suggest the double tap, three pinches suggest the zoom lock; Settings turns tips off. Help › Practice Page ticks each step as the robot does it.")
    def _():
        if app.state()["draw"]: app.press("d", until=lambda s: not s["draw"])
        app.press("n"); app.press("d", until=lambda s: s["draw"])
        st = app.state(); pad_w, pad_h = st["padMM"]
        cid = 10000
        for i in range(6):
            fr, cid = hand.frames(hand.word("ab", pad_w * (0.1 + 0.12 * i), pad_h * 0.5, hand.roman), cid); app.touch(fr, settle=0.1)
        counts = []
        for i in range(9):
            app.cmd({"cmd": "menu", "action": "undo"}); time.sleep(0.15)
            counts.append(app.state()["tips"]["undoGesture"])
        tipped = [i + 1 for i in range(9) if counts[i] > (counts[i - 1] if i else 0)]
        rep.check(tipped == [3, 6], "the double-tap tip shows on the 3rd and 6th ⌘Z undo, then never again", f"tip after undo #{tipped}")
        rep.shot(app, "the undo tip")
        pre_lock_tip = app.state()["tips"]["zoomLock"]
        for k in range(3):
            app.touch(two_finger(pad_w / 2, pad_h * 0.5, 20, 26 if k % 2 == 0 else 15, dur=0.3)); time.sleep(0.1)
        if pre_lock_tip >= 2:
            rep.step("zoom-lock tip", why="already known: the zoom lock was used earlier in this run, so the tip is retired")
        else:
            rep.check("locks the zoom" in app.state().get("toast", ""), "three pinches within a minute: the zoom-lock tip", app.state().get("toast", ""))
        sw = app.state().get("settingsSwitches") or []
        ti = next((i for i, x in enumerate(sw) if x[0].startswith("Tips")), None)
        if ti is not None:
            app.cmd({"cmd": "settingsSwitch", "index": ti, "on": False})
            before = app.state()["tips"]
            for k in range(6): app.press("e", until=lambda s: True)
            rep.check(app.state()["tips"] == before, "with tips off in Settings, no tip shows", f"{before} -> {app.state()['tips']}")
            app.cmd({"cmd": "settingsSwitch", "index": ti, "on": True})
        if app.state()["tool"] != "pen": app.press("p")
        # The practice page.
        app.cmd({"cmd": "menu", "action": "startPracticeAction"}); time.sleep(0.5)
        p0 = app.state().get("practice")
        rep.check(p0 == {"done": []}, "Help › Practice Page: a fresh page and an empty checklist", str(p0))
        st = app.state()
        for i, w in enumerate(["karthik"]):
            fr, cid = hand.frames(hand.word(w, pad_w * 0.25, pad_h * 0.5), cid); app.touch(fr)
        app.touch(double_tap(2, pad_w / 2, pad_h * 0.3))
        a = app.state()
        fr, cid = hand.frames(hand.word("oops", pad_w * 0.3, pad_h * 0.25, hand.roman), cid); app.touch(fr); b = app.state()
        new = b["lastStrokes"][-(b["strokes"] - a["strokes"]):]
        lo = app.cmd({"cmd": "toPad", "points": [[min(w[0] for w in new), min(w[1] for w in new)]]})["points"][0]
        hi = app.cmd({"cmd": "toPad", "points": [[max(w[2] for w in new), max(w[3] for w in new)]]})["points"][0]
        zig = [[(lo[0] + (hi[0] - lo[0]) * (k % 2), lo[1] + (hi[1] - lo[1]) * (0.25 + 0.5 * k / 6)) for k in range(7)]]
        fr, cid = hand.frames(zig, cid, speed=140); app.touch(fr)
        p1 = app.state().get("practice")
        rep.shot(app, "practice: three of four done")
        rep.check(p1 and set(p1["done"]) == {"write", "undo", "scratch"}, "writing, a double-tap undo and a scratch-out tick their lines", str(p1))
        app.press("g", until=lambda s: s["gallery"] >= 0, wait=3); time.sleep(0.5)
        rep.check("Practice done" in app.state().get("toast", ""), "G ticks the last one: 'Practice done'", app.state().get("toast", ""))
        app.press("esc", until=lambda s: s["gallery"] == -2, wait=3)
        if app.state()["draw"]: app.press("d", until=lambda s: not s["draw"])

    @scenario("feedback", "Changes you can't see get feedback: a haptic tick on gesture undo/redo and scratch-out, an undone stroke fades out instead of vanishing, and a faint chevron shows while the page waits to move (gone when a touch cancels it).")
    def _():
        if app.state()["draw"]: app.press("d", until=lambda s: not s["draw"])
        app.press("n"); app.press("d", until=lambda s: s["draw"])
        st = app.state(); pad_w, pad_h = st["padMM"]
        fr, cid = hand.frames(hand.word("tick", pad_w * 0.3, pad_h * 0.5, hand.roman), 10500); app.touch(fr)
        h0 = app.state().get("haptics", 0)
        app.touch(double_tap(2, pad_w / 2, pad_h * 0.3)); h1 = app.state().get("haptics", 0)
        app.touch(double_tap(3, pad_w / 2, pad_h * 0.3)); h2 = app.state().get("haptics", 0)
        rep.check(h1 == h0 + 1 and h2 == h1 + 1, "a haptic tick when a gesture undo and a redo land", f"{h0} -> {h1} -> {h2}")
        app.cmd({"cmd": "menu", "action": "undo"}); f0 = app.state().get("fading", 0)
        time.sleep(0.3); f1 = app.state().get("fading", 0)
        rep.check(f0 >= 1 and f1 == 0, "an undone stroke fades out (gone after the 120 ms fade)", f"fading right after: {f0}, 0.3 s later: {f1}")
        # The pending move (the next line): in writing mode, write a word across the line's limit (the faint line),
        # then look during the pause.
        # A clean page and a fresh block (writing mode off, then on), 50% lines; then draw mode (Esc closing the panel
        # would leave it).
        ensure(app, "draw", False, "d"); app.press("n")
        ensure(app, "writing", False, "w"); ensure(app, "writing", True, "w")
        app.click("writing", "chevron"); app.cmd({"cmd": "panelPick", "writing": 0}); app.press("esc")
        app.cmd({"cmd": "menu", "action": "resetZoom"}); settle(app)
        ensure(app, "draw", True, "d")
        st_ = app.state(); pad_w, pad_h = st_["padMM"]
        # A first word at the left starts the block (its width counts from there); then a word just short of its limit.
        fr0, cid = hand.frames(hand.word("go", pad_w * 0.08, pad_h * 0.5, hand.roman), cid)
        app.touch(fr0 + [[0.008, []]] * 12, settle=0.1)
        lx = app.state()["lineLimitX"]
        (ex, _), = app.cmd({"cmd": "toPad", "points": [[lx - 20, 0]]})["points"]
        fr, cid = hand.frames(hand.word("edge", ex, pad_h * 0.5, hand.roman), cid)
        app.touch(fr + [[0.008, []]] * 12, settle=0.0)
        sd = app.state(); p0 = sd.get("pendingMove", "")
        rep.step("chevron setup", limit=lx, padX=round(ex, 1), padW=pad_w, lineRight=sd.get("lineRight"), strokes=sd["strokes"], lineWidth=sd.get("lineWidth"),
                 writing=sd["writing"], draw=sd["draw"], pending=p0, view=sd["view"])
        app.touch([[0.008, [[cid + 50, pad_w * 0.5, pad_h * 0.2, 2, 0.5, 7.5]]]] * 3 + [[0.008, []]], settle=0.05)   # a light touch: cancels
        p1 = app.state().get("pendingMove", "")
        rep.check(p0 != "" and p1 == "", "a chevron shows while the page waits to move, and a touch cancels it", f"during the pause: {p0!r}, after a touch: {p1!r}")
        ensure(app, "writing", False, "w")
        ensure(app, "draw", False, "d")

    @scenario("overview-find", "The overview shows each page's ink (cropped to it, not a near-blank top screen), titles each tile with its first handwritten line, finds pages by handwriting (⌘F, typed), and copies or shares a page as an image.")
    def _():
        if app.state()["draw"]: app.press("d", until=lambda s: not s["draw"])
        cid = 10600
        start = app.state()["pages"]
        for w in ["hello", "world", "."]:
            app.press("n"); app.press("d", until=lambda s: s["draw"])
            st = app.state(); pad_w, pad_h = st["padMM"]
            old_h = hand.h; hand.h = 9.0
            fr, cid = hand.frames(hand.word(w, pad_w * 0.2, pad_h * 0.75, hand.roman), cid); app.touch(fr)
            hand.h = old_h
            app.press("d", until=lambda s: not s["draw"])
        st = app.state(); n = st["pages"]; a, b, c = n - 3, n - 2, n - 1
        regs = st.get("thumbRegions") or []
        pw = st["pageW"]
        rep.check(regs and regs[a][2] < pw * 0.6 and regs[c][2] <= pw * 0.34, "thumbnails are cropped to the ink", f"page {a + 1} shows {regs[a][2] / pw:.0%} of the page width, the dot page {regs[c][2] / pw:.0%}" if regs else "")
        app.press("g", until=lambda s: s["gallery"] >= 0, wait=3)
        t0 = time.time(); titles = []
        while time.time() - t0 < 12:
            titles = app.state().get("galleryTitles") or []
            if len(titles) > b and titles[a] and titles[b]: break
            time.sleep(0.3)
        rep.step("titles", titles=titles[a:])
        rep.check(len(titles) > b and "hello" in titles[a].lower() and "world" in titles[b].lower(), "tiles get their first handwritten line as a title", f"{titles[a:] if titles else []} in {time.time() - t0:.1f} s")
        time.sleep(0.5); rep.shot(app, "overview: cropped thumbnails and handwriting titles")
        app.cmd({"cmd": "menu", "action": "findInPagesAction"}); time.sleep(0.6)
        rep.check(app.state().get("searchFocused") is True, "⌘F (Edit › Find in Pages) puts the cursor in the search field", "")
        for ch in "world": app.key(ch); time.sleep(0.05)
        time.sleep(0.4); s1 = app.state()
        rep.check(s1.get("galleryQuery") == "world" and s1.get("galleryMatching") == [b] and s1["gallery"] == b, "typing 'world' finds that page and selects it",
                  f"query {s1.get('galleryQuery')!r}, matching {s1.get('galleryMatching')}, selected {s1['gallery']}")
        rep.shot(app, "searching 'world'")
        app.key("return"); time.sleep(1.0); s2 = app.state()
        rep.check(s2["gallery"] == -2 and s2["page"] == b, "Return opens it", f"page {s2['page'] + 1}")
        app.cmd({"cmd": "menu", "action": "copyPageAction"}); time.sleep(0.3)
        rep.check(app.state().get("pasteboardPNG", 0) > 1000, "Edit › Copy Page as Image puts a PNG on the pasteboard", f"{app.state().get('pasteboardPNG', 0)} bytes")
        app.cmd({"cmd": "menu", "action": "sharePageAction"}); time.sleep(0.3)
        rep.check(app.state().get("shareFile") == "ok", "File › Share Page… shares the page as an image file", app.state().get("shareFile", ""))

    @scenario("zoom-percent", "The zoom as a percentage: a badge while pinching, always in the capsule (draw mode) and the toolbar; a pinch ending near 300% snaps to exactly 300%; the toolbar's zoom menu has presets and a field to type one; a page keeps its zoom after a relaunch.")
    def _():
        ensure(app, "draw", False, "d")
        app.press("n"); app.cmd({"cmd": "menu", "action": "resetZoom"}); settle(app)
        ensure(app, "draw", True, "d")
        st = app.state(); pad_w, pad_h = st["padMM"]
        r = app.touch(two_finger(pad_w / 2, pad_h * 0.5, 15, 15 * 2.94, dur=0.7), settle=0.15)   # ends at ~294%
        s1 = app.state()
        rep.check(abs(s1["view"]["zoom"] - 3.0) < 1e-6, "a pinch ending near 300% snaps to exactly 300%", f"zoom {s1['view']['zoom']:.4f}")
        rep.check(s1.get("zoomBadge") == "300%", "a zoom badge shows while pinching", repr(s1.get("zoomBadge")))
        rep.shot(app, "pinching: the zoom badge")
        rep.check("300%" in (s1.get("chrome") or {}).get("capsule", ""), "the capsule always shows the zoom in draw mode", (s1.get("chrome") or {}).get("capsule", ""))
        time.sleep(2.0)
        rep.check(app.state().get("zoomBadge") == "", "the badge fades after the pinch", "")
        app.touch(two_finger(pad_w / 2, pad_h * 0.5, 20, 23.5, dur=0.5), settle=0.15)
        ensure(app, "draw", False, "d")
        s2 = app.state()
        rep.check(s2.get("toolbarZoom", "").endswith("%"), "the toolbar shows the zoom outside draw mode", repr(s2.get("toolbarZoom")))
        rep.shot(app, "the zoom in the toolbar")
        m = app.cmd({"cmd": "zoomMenu", "pick": "200%"}); time.sleep(0.5)
        s3 = app.state()
        rep.check("200%" in (m.get("items") or []) and abs(s3["view"]["zoom"] - 2.0) < 1e-6 and s3.get("toolbarZoom") == "200%",
                  "the toolbar's zoom menu: picking 200% zooms to 200%", f"items {m.get('items')}, zoom {s3['view']['zoom']}")
        app.cmd({"cmd": "zoomMenu", "type": "150"}); time.sleep(0.5)
        s4 = app.state()
        rep.check(abs(s4["view"]["zoom"] - 1.5) < 1e-6, "typing 150 in the menu's field zooms to 150%", f"zoom {s4['view']['zoom']}")
        page = s4["page"]
        app.quit(); app.launch()
        s5 = app.state()
        rep.check(s5["page"] == page and abs(s5["view"]["zoom"] - 1.5) < 1e-6 and s5.get("toolbarZoom") == "150%", "after a relaunch the page is at the same zoom, and says so", f"zoom {s5['view']['zoom']}, toolbar {s5.get('toolbarZoom')}")

    @scenario("page-map-extended", "Writing past the page's right edge and far below the first screen: the page map covers the page, all the ink and the view, not just the original page.")
    def _():
        ensure(app, "draw", False, "d")
        app.press("n"); app.cmd({"cmd": "menu", "action": "resetZoom"}); settle(app)
        ensure(app, "draw", True, "d")
        st = app.state(); pad_w, pad_h = st["padMM"]
        app.touch(two_finger(pad_w / 2, pad_h * 0.6, 15, 45, dur=0.6)); time.sleep(1.6)
        for _ in range(12): app.press("right")
        settle(app)
        cid = 12000
        # A stroke from inside the pad running off its right edge (ink past the page's right side).
        line = [[(pad_w * 0.55 + k * pad_w * 0.045, pad_h * 0.55) for k in range(11)]]
        fr, cid = hand.frames(line, cid, speed=60); app.touch(fr)
        for _ in range(14): app.press("down")
        settle(app)
        fr, cid = hand.frames(hand.word("below", pad_w * 0.3, pad_h * 0.4, hand.roman), cid); app.touch(fr)
        app.press("left")   # a hand move: the map shows
        s = app.state(); m, ink, v, pw = s["mapRegion"], s["inkBounds"], s["view"], s["pageW"]
        rep.step("geometry", inkMaxX=round(ink[2]), pageW=round(pw), map=[round(x) for x in m], inkMinY=round(ink[1]))
        rep.check(ink and ink[2] > pw, "the ink runs past the page's right edge (the case to test)", f"ink to x {ink[2]:.0f}, page width {pw:.0f}")
        covers = m[0] <= ink[0] + 1e-6 and m[1] <= ink[1] + 1e-6 and m[2] >= ink[2] - 1e-6 and m[3] >= ink[3] - 1e-6
        view_in = m[0] <= v["x"] + 1e-6 and m[1] <= v["y"] + 1e-6 and m[2] >= v["x"] + v["w"] - 1e-6 and m[3] >= v["y"] + v["h"] - 1e-6
        rep.check(covers and view_in and m[0] <= 1e-6 and m[2] >= pw - 1e-6, "the map covers the page, all the ink and the view", f"map x {m[0]:.0f}..{m[2]:.0f}, y {m[1]:.0f}..{m[3]:.0f}")
        rep.shot(app, "map with ink past the right edge and far down")
        ensure(app, "draw", False, "d")

    @scenario("settings-in-draw-mode", "Opening Settings (Cmd-,) while drawing must never lock you in: draw mode steps aside (pointer back) so Settings can be used, Esc works from the Settings window, and closing Settings puts draw mode back.")
    def _():
        ensure(app, "draw", False, "d")
        app.cmd({"cmd": "enterDrawLocked"}); time.sleep(0.3)
        a = app.state()
        rep.check(a["draw"] and a.get("cursorLocked"), "draw mode with the pointer frozen (the starting state)", f"draw {a['draw']}, pointer locked {a.get('cursorLocked')}")
        app.cmd({"cmd": "menu", "action": "showSettings"}); time.sleep(0.6)
        b = app.state()
        rep.check(b.get("settingsWindow", 0) != 0 and not b["draw"] and not b.get("cursorLocked"),
                  "Cmd-, in draw mode: Settings opens and draw mode steps aside, so the pointer is free to use it",
                  f"settings window {b.get('settingsWindow')}, draw {b['draw']}, pointer locked {b.get('cursorLocked')}")
        app.cmd({"cmd": "closeSettings"}); time.sleep(0.4)
        c = app.state()
        rep.check(c["draw"] and c.get("settingsWindow", 0) == 0, "closing Settings puts draw mode back", f"draw {c['draw']}")
        # Esc must always get you out, even with Settings in front.
        app.cmd({"cmd": "menu", "action": "showSettings"}); time.sleep(0.4)
        app.cmd({"cmd": "enterDrawLocked"}); time.sleep(0.2)   # draw mode on again somehow (hotkey) while Settings is up
        app.cmd({"cmd": "settingsKey", "code": 53}); time.sleep(0.3)
        d = app.state()
        rep.check(not d["draw"] and not d.get("cursorLocked"), "Esc pressed in the Settings window leaves draw mode", f"draw {d['draw']}, pointer locked {d.get('cursorLocked')}")
        app.cmd({"cmd": "closeSettings"}); time.sleep(0.3)
        ensure(app, "draw", False, "d")

    def line_widths(recs):
        """Each written line: where it starts (its first word, or the first word after a deliberate jump) and ends."""
        out, cur = [], None
        for r in recs:
            b = r["bounds"]
            if not b: continue
            if cur is None or r.get("jumped"): cur = {"start": b[0], "end": b[2], "last": b[2] - b[0]}; out.append(cur)
            else: cur["end"] = max(cur["end"], b[2]); cur["last"] = b[2] - b[0]
            if r["newLine"]: cur = None
        return out

    def half_setup():
        ensure(app, "draw", False, "d"); app.press("n")
        ensure(app, "writing", True, "w")
        app.click("writing", "chevron"); app.cmd({"cmd": "panelPick", "writing": 0}); app.press("esc")
        app.cmd({"cmd": "menu", "action": "resetZoom"}); settle(app)
        ensure(app, "draw", True, "d")
        st = app.state(); pad_w, pad_h = st["padMM"]
        app.touch(two_finger(pad_w / 2, pad_h * 0.6, 15, 45, dur=0.6))
        for _ in range(12): app.press("left")   # to the page's left side, where lines start
        time.sleep(1.6)
        return app.state()

    @scenario("half-line-nudges", "½-page lines with small hand nudges (under 10% of the view) and a small pinch between words: each line still ends about half a page after it starts (plus the word that crossed the limit), never running 70-80% wide.")
    def _():
        st = half_setup(); pad_w, pad_h = st["padMM"]; W = st["pageW"]
        recs, _ = write_words(app, hand, (SENTENCE + " " + SENTENCE).split(), pad_h * 0.55, pad_w * 0.1, 12500, rep, nudge_every=3, nudge_frac=0.06, pinch_at=4)
        lines = line_widths(recs)
        full = [l for l in lines[:-1]]   # finished lines (the last may be partial)
        # Lines start at the page's left margin (3%) and may end one word past margin + ½ page.
        over = [(l["end"] / W) - (0.03 + 0.5 + l["last"] / W + 0.02) for l in full]
        rep.step("lines", ends=[round(l["end"] / W, 2) for l in lines], widths=[round((l["end"] - l["start"]) / W, 2) for l in lines])
        rep.check(len(full) >= 1 and max(over) <= 0, "every finished ½-page line ends at margin + half a page (plus the word that crossed it)",
                  f"line ends at {[round(l['end'] / W, 2) for l in full]} of the page; worst overshoot {max(over):+.0%}")
        rep.shot(app, "½-page lines with nudges")
        ensure(app, "writing", False, "w"); ensure(app, "draw", False, "d")

    @scenario("half-line-autopan", "½-page lines written with no hand moves (and no sideways pan any more): the page never moves along the line, and the line wraps at margin + half a page.")
    def _():
        st = half_setup(); pad_w, pad_h = st["padMM"]; W = st["pageW"]
        recs, _ = write_words(app, hand, (SENTENCE + " " + SENTENCE).split(), pad_h * 0.55, pad_w * 0.1, 13100, rep)
        full = line_widths(recs)[:-1]
        over = [(l["end"] / W) - (0.03 + 0.5 + l["last"] / W + 0.02) for l in full]
        pans = sum(1 for r in recs if r["view"]["x"] > r["before"]["x"] + 1e-6 and not r["newLine"])
        rep.check(len(full) >= 1 and pans == 0 and max(over) <= 0, "no sideways pan, and ½-page lines wrap at margin + half a page",
                  f"{pans} sideways pans; line ends {[round(l['end'] / W, 2) for l in full]}")
        ensure(app, "writing", False, "w"); ensure(app, "draw", False, "d")

    @scenario("half-line-small-nudge-gap", "A small nudge (6% of the view, under the 10% bar), then a word written with a gap: that's still the same line, so it wraps at margin + half a page.")
    def _():
        st = half_setup(); pad_w, pad_h = st["padMM"]; W = st["pageW"]
        words = "a small nudge then a gap and this line keeps its start at the margin as before ok".split()
        recs, _ = write_words(app, hand, words, pad_h * 0.55, pad_w * 0.1, 13400, rep, jump_after=1, jump_shift=0.06, jump_pad_x=None, stop_on_new_line=True)
        b = [r["bounds"] for r in recs if r["bounds"]]
        end = max(x[2] for x in b) / W; last = (b[-1][2] - b[-1][0]) / W
        wrapped = any(r["newLine"] for r in recs)
        rep.check(wrapped and end <= 0.03 + 0.5 + last + 0.02, "after a small nudge, writing with a gap doesn't move the line's start",
                  f"line ends at {end:.0%} of the page (margin + ½ + last word = {0.53 + last:.0%}), new line: {wrapped}")
        ensure(app, "writing", False, "w"); ensure(app, "draw", False, "d")

    @scenario("half-line-moved-start", "A deliberate pan right (well over 10% of the view), then writing at a new spot: the line now starts there and wraps half a page later, not at the page's edge.")
    def _():
        st = half_setup(); pad_w, pad_h = st["padMM"]; W = st["pageW"]
        words = "start here then keep writing along this line until it wraps over to the next one please".split()
        recs, _ = write_words(app, hand, words, pad_h * 0.55, pad_w * 0.1, 12800, rep, jump_after=1, jump_pad_x=pad_w * 0.62, stop_on_new_line=True)
        lines = line_widths(recs)
        moved = next((l for l in lines if any(r.get("jumped") for r in recs)), None)
        seg = lines[1] if len(lines) > 1 else None
        wrapped = any(r["newLine"] for r in recs)
        w = (seg["end"] - seg["start"]) / W if seg else 0
        rep.step("segment", lines=[(round(l["start"]), round(l["end"])) for l in lines], wrapped=wrapped)
        rep.check(seg is not None and wrapped and 0.4 <= w <= 0.5 + seg["last"] / W + 0.02,
                  "after the deliberate pan the line starts at the new spot and wraps about half a page later",
                  f"segment {w:.0%} of the page wide, new line: {wrapped}")
        rep.shot(app, "line moved by a deliberate pan")
        ensure(app, "writing", False, "w"); ensure(app, "draw", False, "d")

    def write_rows(cid, words, start_page, font=None, space=0.9, pause=0.6, on_word=None):
        """Write `words` the way a person does in writing mode at zoom 100%: each word right after the last one;
        when the app starts a new line, carry on there (after the word it moved down, if it moved one). All
        positions are kept in page units and turned into pad positions just before writing."""
        st = app.state(); pad_w, pad_h = st["padMM"]
        p0 = app.cmd({"cmd": "toPagePt", "point": [10, 10]})["point"]; p1 = app.cmd({"cmd": "toPagePt", "point": [20, 10]})["point"]
        upm = (p1[0] - p0[0]) / 10   # page units per pad mm
        base = list(start_page); lines0 = st["newLines"]; written = 0
        write_rows.off_pad = 0
        for w in words:
            (px, py), = app.cmd({"cmd": "toPad", "points": [base]})["points"]
            if px + hand.width(w, font) > pad_w * 0.92:   # no room left on the pad: pan by hand with two fingers, as a person does
                app.touch(two_finger(pad_w / 2, pad_h / 2, 25, 25, shift=(-(pad_w * 0.45), 0), dur=0.5)); settle(app)
                (px, py), = app.cmd({"cmd": "toPad", "points": [base]})["points"]
            strokes = hand.word(w, px, py, font)
            fr, cid = hand.frames(strokes, cid)
            before_word = app.state()
            app.touch(fr, settle=0.05)
            written += len(strokes)
            after_word = None
            if on_word: time.sleep(0.25); after_word = app.state()   # just after the word, inside the pause
            # Strokes that run off the trackpad (a person's finger can't), or start in the edge guard's band (5%, ignored
            # like a resting palm): never drawn, not counted as lost.
            g = 0.05
            write_rows.off_pad += sum(1 for st_ in strokes if any(not (0 <= q[0] <= pad_w and 0 <= q[1] <= pad_h) for q in st_)
                                      or not (g * pad_w <= st_[0][0] <= (1 - g) * pad_w and g * pad_h <= st_[0][1] <= (1 - g) * pad_h))
            mine = app.state()["lastStrokes"][-len(strokes):]
            app.touch([[0.008, []]] * int(pause / 0.008), settle=0.3); settle(app)
            s2 = app.state(); now = s2["lastStrokes"][-len(strokes):]
            if on_word: on_word(w, s2, before_word, after_word)
            gap = hand.h * space * upm
            if s2["newLines"] > lines0:
                lines0 = s2["newLines"]
                dx, dy = now[0][0] - mine[0][0], now[0][1] - mine[0][1]
                if abs(dx) > 1 or abs(dy) > 1:   # the app moved this word down to the next line
                    base = [max(b[2] for b in now) + gap, base[1] + dy]
                else:
                    nl = s2["nextLine"]
                    base = [nl[0], nl[1] - hand.h * 0.35 * upm]
            else:
                base = [max(b[2] for b in now) + gap, base[1]]
        return cid, written

    def hard_limit(frac, idx, name):
        ensure(app, "draw", False, "d"); app.press("n")
        ensure(app, "writing", True, "w")
        app.click("writing", "chevron"); app.cmd({"cmd": "panelPick", "writing": idx}); app.press("esc")
        app.cmd({"cmd": "menu", "action": "resetZoom"}); settle(app)   # zoom 100%, as in Karthik's screenshot
        ensure(app, "draw", True, "d")
        st = app.state(); W = st["pageW"]
        n0 = st["strokes"]
        words = (SENTENCE + " " + SENTENCE + " " + SENTENCE).split()
        old_h = hand.h; hand.h = 4.5   # handwriting size at 100%
        top = app.cmd({"cmd": "toPagePt", "point": [0, st["padMM"][1] * 0.85]})["point"][1]
        cid, written = write_rows(14000 + idx * 500, words, [W * 0.035, top])
        hand.h = old_h
        s = app.state()
        ink = s["inkBounds"]
        rep.step("ink", maxX=round(ink[2] / W, 4), newLines=s["newLines"], strokesWritten=written, strokesOnPage=s["strokes"] - n0)
        start = ink[0]   # the block's start: the width counts from there (28 Oct)
        rep.check(ink[2] <= start + (frac + 0.06) * W, f"{name} lines end at about {frac:.0%} of the page after the block's start (a word may run slightly past it)", f"ink from {start / W:.1%} to {ink[2] / W:.1%} of the page (limit {(start / W + frac):.1%})")
        rep.check(s["strokes"] - n0 == written, "every stroke stays where it was written", f"{written} written, {s['strokes'] - n0} on the page")
        rep.shot(app, f"{name} lines at 100%")
        ensure(app, "writing", False, "w"); ensure(app, "draw", False, "d")

    @scenario("edge-word-stays", "Karthik's repro (19:33): a fast writer reaches the ½-page mark and starts 'the' right after 'dog', pausing 0.7 s inside the word. The word finishes on its line, nothing already written ever moves, and the line breaks only after the word; the next words keep to the ½-page mark.")
    def _():
        ensure(app, "draw", False, "d"); app.press("n")
        ensure(app, "writing", True, "w")
        app.click("writing", "chevron"); app.cmd({"cmd": "panelPick", "writing": 0}); app.press("esc")
        app.cmd({"cmd": "menu", "action": "resetZoom"}); settle(app)
        ensure(app, "draw", True, "d")
        st = app.state(); W = st["pageW"]; pad_w, pad_h = st["padMM"]
        old_h = hand.h; hand.h = 4.5
        p0 = app.cmd({"cmd": "toPagePt", "point": [10, 10]})["point"]; p1 = app.cmd({"cmd": "toPagePt", "point": [20, 10]})["point"]
        upm = (p1[0] - p0[0]) / 10
        y = pad_h * 0.8
        (x,) = [app.cmd({"cmd": "toPad", "points": [[W * 0.035, 0]]})["points"][0][0]]
        cid = 15000
        lines0 = st["newLines"]
        # Fast writing: words 0.2 s apart (no 400 ms pause, so the app makes no decision) up to ~42% of the page.
        fr = []
        for w in ["over", "the", "lazy", "dog"]:
            strokes = hand.word(w, x, y)
            f, cid = hand.frames(strokes, cid); fr += f + [[0.008, []]] * 25
            x += hand.width(w) + hand.h * 0.9
            if (app.cmd({"cmd": "toPagePt", "point": [x, y]})["point"][0]) > W * 0.42: break
        app.touch(fr, settle=0.05)
        before = app.state()["pageBounds"]
        # 'th', a 0.7 s pause inside the word, then 'e'; then the word gap.
        th = hand.word("th", x, y); e_x = x + hand.width("th")
        f1, cid = hand.frames(th, cid)
        f2, cid = hand.frames(hand.word("e", e_x, y), cid)
        r = app.touch(f1 + [[0.008, []]] * int(0.7 / 0.008) + f2, settle=0.05)
        mid = app.state()
        word_bounds = mid["pageBounds"][len(before):]
        rep.check(mid["newLines"] == lines0, "no line break inside the word (not at the 0.7 s pause between 'th' and 'e')", f"new lines during the word: {mid['newLines'] - lines0}")
        app.touch([[0.008, []]] * int(1.4 / 0.008), settle=0.3); settle(app)
        after = app.state()
        moved = [i for i, (a, b) in enumerate(zip(before + word_bounds, after["pageBounds"])) if any(abs(u - v) > 1e-6 for u, v in zip(a, b))]
        rep.check(not moved and len(after["pageBounds"]) == len(before) + len(word_bounds), "nothing already written moves (the started word and everything before it)", f"moved strokes: {moved}")
        ys = [(b[1] + b[3]) / 2 for b in word_bounds]; line_y = [(b[1] + b[3]) / 2 for b in before]
        same_line = word_bounds and max(abs(v - (sum(line_y) / len(line_y))) for v in ys) < hand.h * 1.2 * upm
        rep.check(same_line, "'the' is finished on the line it started on (no break inside the word)", f"word ends at {max(b[2] for b in word_bounds) / W:.0%} of the page")
        rep.check(after["newLines"] > lines0, "after the word, the line breaks", f"new lines {after['newLines'] - lines0}")
        rep.shot(app, "'the' finished on its line past the mark; the next line comes after it")
        # The next words follow the app's breaks and keep to the ½-page mark (each starts before it).
        n0 = len(after["pageBounds"])
        cid, written = write_rows(cid, "quick brown fox jumps over the lazy dog again and again".split(), [after["nextLine"][0], after["nextLine"][1] - hand.h * 0.35 * upm])
        fin = app.state()
        rest = fin["pageBounds"][n0:]
        mark = min(b[0] for b in after["pageBounds"][:n0]) + W * 0.5   # ½ a page after the block's start (28 Oct)
        starts_ok = all(b[0] <= mark for b in rest)
        over = max(b[2] for b in rest) / W
        rep.check(starts_ok and over <= mark / W + 0.06, "the next words start before the ½-page mark (from the block's start); a word may only run slightly past it", f"ink to {over:.1%} of the page, mark {mark / W:.1%}")
        hand.h = old_h
        ensure(app, "writing", False, "w"); ensure(app, "draw", False, "d")

    @scenario("half-line-zoomed", "Karthik's recording (21:22): ½-page lines written zoomed in to 400% with the page following the pen (centre). Each line ends at about half the page, not after a screen or so (his lines ended at 28-32% of the page).")
    def _():
        ensure(app, "draw", False, "d"); app.press("n")
        ensure(app, "writing", True, "w")
        app.click("writing", "chevron"); app.cmd({"cmd": "panelPick", "writing": 0}); app.press("esc")
        app.cmd({"cmd": "menu", "action": "resetZoom"}); settle(app)
        ensure(app, "draw", True, "d")
        app.cmd({"cmd": "zoomMenu", "pick": "400%"}); settle(app, limit=3)
        for _ in range(16): app.press("left")
        for _ in range(16): app.press("up")
        settle(app, limit=3)
        st = app.state(); W = st["pageW"]; n0 = st["strokes"]; pad_w, pad_h = st["padMM"]
        rep.check(abs(st["view"]["zoom"] - 4) < 0.05 and st["view"]["x"] < W * 0.02, "zoomed in to 400% at the page's left edge", str(st["view"]))
        p0 = app.cmd({"cmd": "toPagePt", "point": [10, 10]})["point"]; p1 = app.cmd({"cmd": "toPagePt", "point": [20, 10]})["point"]
        upm = (p1[0] - p0[0]) / 10
        old_h = hand.h; hand.h = 9   # his letters at 400%: about a tenth of the view's height
        top = app.cmd({"cmd": "toPagePt", "point": [0, pad_h * 0.7]})["point"][1]
        words = (SENTENCE + " " + SENTENCE + " " + SENTENCE).split()
        # Karthik's spacing: word spaces about 18 units for letters 20-26 tall and a line 48 tall with its capitals and
        # descenders (a space of about 0.35 of the letter height here).
        cid, written = write_rows(19000, words, [W * 0.035, top], space=0.35, pause=1.6)   # he pauses between words
        hand.h = old_h
        s2 = app.state()
        mine = s2["pageBounds"][n0:]
        lines = []
        for b in mine:
            y = (b[1] + b[3]) / 2
            for L in lines:
                if abs(L[0] - y) < hand.h * 1.1 * upm: L[1] = min(L[1], b[0]); L[2] = max(L[2], b[2]); break
            else: lines.append([y, b[0], b[2]])
        lines.sort(key=lambda L: -L[0])
        ends = [round(L[2] / W, 3) for L in lines]
        rep.step("lines", ends=ends, newLines=s2["newLines"] - st["newLines"], zoom=s2["view"]["zoom"])
        full = ends[:-1]
        rep.check(len(full) >= 2 and all(0.42 <= e <= 0.58 for e in full), "every full line ends at about half the page (42-58%)", f"lines end at {[f'{e:.0%}' for e in ends]} of the page")
        off = write_rows.off_pad
        rep.check(s2["strokes"] - n0 == written - off, "every stroke written on the trackpad is on the page", f"{written - off} written on the pad ({off} ran off its edge), {s2['strokes'] - n0} on the page")
        rep.shot(app, "½-page lines written at 400%")
        app.cmd({"cmd": "menu", "action": "resetZoom"}); settle(app)
        rep.shot(app, "the same lines, whole page")
        ensure(app, "writing", False, "w"); ensure(app, "draw", False, "d")

    def limit_line_px(shot, st):
        """The canvas column where the line limit is (window screenshot pixels), and how blue it is against the paper
        a few pixels either side (mean of blue minus red over the canvas's middle half, height-wise)."""
        from PIL import Image
        im = Image.open(shot).convert("RGB"); k = im.width / st["canvasFrame"][4]
        cx, cy, cw, ch = (v * k for v in st["canvasFrame"][:4])
        d = st.get("limitDrawn")   # where the app last drew it: page x, and the view's left and width then
        if not d: return None, 0.0
        col = cx + (d[0] - d[1]) / d[2] * cw
        def tint(x):
            px = [im.getpixel((int(x), int(cy + ch * (0.25 + 0.5 * i / 40)))) for i in range(41)]
            return sum(b - r for r, g, b in px) / len(px)
        return col, max(tint(col + d) for d in (-1, 0, 1)) - (tint(col - 8) + tint(col + 8)) / 2

    @scenario("writing-limit-border", "Writing mode, Karthik's design (28 Oct): no sideways pan while writing (at 400%, ½-page lines), the next-line pan when a line reaches the limit, and a faint vertical line at the limit, only in writing mode, at the right page x at any zoom; never in exports or thumbnails.")
    def _():
        ensure(app, "draw", False, "d"); app.press("n")
        ensure(app, "writing", True, "w")
        app.click("writing", "chevron"); app.cmd({"cmd": "panelPick", "writing": 0}); app.press("esc")
        app.cmd({"cmd": "menu", "action": "resetZoom"}); settle(app)
        ensure(app, "draw", True, "d")
        app.cmd({"cmd": "zoomMenu", "pick": "400%"}); settle(app, limit=3)
        for _ in range(16): app.press("left")
        for _ in range(16): app.press("up")
        settle(app, limit=3)
        st = app.state(); W = st["pageW"]; n0 = st["strokes"]; pad_w, pad_h = st["padMM"]; nl0 = st["newLines"]
        old_h = hand.h; hand.h = 9
        top = app.cmd({"cmd": "toPagePt", "point": [0, pad_h * 0.7]})["point"][1]
        views = []
        start_shot, samples, after_nl = [], [], []
        def seen(w, s_, b_, a_):
            views.append((w, b_["view"]["x"], s_["view"]["x"], s_["newLines"] - b_["newLines"]))
            if a_ and a_.get("lineLimitX") is not None and a_.get("lineRight") is not None and a_["newLines"] == b_["newLines"]:
                lim, right = a_["lineLimitX"], a_["lineRight"]
                width = W * 0.5   # the ½-page line width
                inview = a_["view"]["x"] < lim < a_["view"]["x"] + a_["view"]["w"]
                samples.append((w, (lim - right) / width, a_.get("limitAlpha", 0), a_.get("limitDrawn"), lim, inview))
            if s_["newLines"] > b_["newLines"]:
                time.sleep(0.4); after_nl.append(app.state().get("limitAlpha", 0))
        words = (SENTENCE + " " + SENTENCE).split()
        cid, written = write_rows(20000, words, [W * 0.035, top], space=0.6, pause=1.0, on_word=seen)
        hand.h = old_h
        # (a) sideways moves only with a new line (the view goes back to the margin), never while writing along a line
        # The view from just before each word (after any hand pan) to after its pause: it moves only with a new line.
        side = [(w, round(after - before, 1)) for w, before, after, nl in views if abs(after - before) > 1 and nl == 0]
        rep.check(not side, "(a) no sideways pan while writing along a line (400%, ½-page lines)", f"sideways moves without a new line: {side[:4]} ({len(views)} words)")
        s2 = app.state()
        rep.check(s2["newLines"] > nl0, "(b) the next-line pan still comes", f"{s2['newLines'] - nl0} new lines")
        mine = s2["pageBounds"][n0:]
        p0 = app.cmd({"cmd": "toPagePt", "point": [10, 10]})["point"]; p1 = app.cmd({"cmd": "toPagePt", "point": [20, 10]})["point"]
        upm = (p1[0] - p0[0]) / 10
        lines = []
        for b in mine:
            y = (b[1] + b[3]) / 2
            for L in lines:
                if abs(L[0] - y) < 9 * 1.1 * upm: L[1] = max(L[1], b[2]); break
            else: lines.append([y, b[2]])
        lines.sort(key=lambda L: -L[0])
        ends = [L[1] / W for L in lines]
        full_lines = ends[:-1]
        rep.check(full_lines and all(0.42 <= e <= 0.58 for e in full_lines), "(b) it comes near the ½-page limit (lines end at 42-58% of the page)", f"{[f'{e:.0%}' for e in ends]}")
        # (c) the limit line (Karthik, 28 Oct evening: only when approaching the width point): hidden at the start of a
        # line, fading in within 15% of the line width from the limit, gone after the next-line move.
        lx = s2.get("lineLimitX")
        first_x = min(b[0] for b in mine) if mine else 0
        # (the block starts at its first stroke; a later line's stroke may sit a little further left: 1% tolerance)
        rep.check(lx is not None and (abs(lx - 0.5 * W) < 1 or abs(lx - (first_x + 0.5 * W)) < 0.01 * W),
                  "(c) the limit is where the next-line pan comes: ½ page from the line's start", f"limit x {lx}, page {W}, line start {first_x:.0f}")
        far = [(w, round(d, 2), a) for w, d, a, _, _, _ in samples if d > 0.3]
        near = [(w, round(d, 2), a) for w, d, a, _, _, _ in samples if d <= 0.15]
        rep.step("limit line", samples=[(w, round(d, 2), round(a, 3)) for w, d, a, _, _, _ in samples], afterNewLine=[round(a, 3) for a in after_nl])
        rep.check(far and all(a <= 0.01 for _, _, a in far), "(c) hidden while the line's ink is far from the limit (more than 30% of the line width)", f"{far[:6]}")
        # Strength 22% x (1 - distance / 15% of the line width): e.g. 0.015 at 14%, 0.044 at 12%, 0.22 at the limit.
        rep.check(near and all(abs(a - 0.22 * max(0.0, 1 - d / 0.15)) < 0.03 for _, d, a in near) and max(a for _, _, a in near) > 0.005,
                  "(c) fades in as the ink comes within 15% of the line width of the limit (in proportion)", f"{near}")
        shown_in_view = [(d, l) for _, _, a, d, l, iv in samples if a > 0.002 and iv]
        rep.check(all(d and abs(d[0] - l) < 1e-6 for d, l in shown_in_view), "(c) when shown (and the limit is in view), it's drawn at the limit's page x (the 100% screenshot below checks it too)", f"{len(shown_in_view)} shown in view: drawn at {[d and round(d[0]) for d, _ in shown_in_view]}")
        # The last line has only a few words (far from the limit): at 100%, with the limit in view, no line to be seen.
        app.cmd({"cmd": "menu", "action": "resetZoom"}); settle(app, limit=3); time.sleep(0.6)
        st0 = app.state(); start_shot.append((rep.shot(app, "a line just started (100%): no limit line"), st0))
        # Then a word on that line that ends just short of the limit: the line fades in (screenshot before the pause ends).
        last = s2["pageBounds"][-1]; lim0 = st0["lineLimitX"]
        q0 = app.cmd({"cmd": "toPagePt", "point": [10, 10]})["point"]; q1 = app.cmd({"cmd": "toPagePt", "point": [20, 10]})["point"]
        upm1 = (q1[0] - q0[0]) / 10
        old_h = hand.h; hand.h = 4.5   # handwriting size at 100%
        start = lim0 - W * 0.02 - hand.width("near") * upm1   # ends about 2% of the page short of the limit
        (nx, ny), = app.cmd({"cmd": "toPad", "points": [[start, (last[1] + last[3]) / 2]]})["points"]
        strokes_ = hand.word("near", nx, ny); hand.h = old_h
        f_, _ = hand.frames(strokes_, 21500)
        # Hold the finger still at the word's end for 2 s (the stroke still live: no new line yet), and take the
        # screenshot 1.2 s in, from another thread (the window's frames reach the screen with some delay).
        tip = f_[-2][1][0] if len(f_) > 1 and f_[-2][1] else None
        if tip: f_ = f_[:-1] + [[0.008, [list(tip)]]] * int(2.0 / 0.008) + [f_[-1]]
        import threading
        shot_box = []
        th = threading.Thread(target=lambda: (time.sleep(1.4), shot_box.append(rep.shot(app, "a word just short of the limit (100%): the limit line fades in"))))
        th.start(); app.touch(f_, settle=0.05); th.join()
        st1 = app.state(); sh1 = shot_box[0]
        from PIL import Image
        im1 = Image.open(sh1).convert("RGB"); k1 = im1.width / st1["canvasFrame"][4]
        cx1, cy1, cw1, ch1 = (v * k1 for v in st1["canvasFrame"][:4]); v1 = st1["view"]
        col1 = cx1 + (st1["lineLimitX"] - v1["x"]) / v1["w"] * cw1
        def tint_at(x): 
            px = [im1.getpixel((int(x), int(cy1 + ch1 * (0.25 + 0.5 * i / 40)))) for i in range(41)]
            return sum(b - r_ for r_, g_, b in px) / len(px)
        tint1 = max(tint_at(col1 + d) for d in (-1, 0, 1)) - (tint_at(col1 - 8) + tint_at(col1 + 8)) / 2
        rep.check(tint1 > 6 and st1.get("limitAlpha", 0) > 0.05, "(c) you can see it as the ink nears the limit (screenshot)", f"strength {st1.get('limitAlpha', 0):.3f}, blue tint {tint1:.1f}, ink {(st1.get('lineRight') or 0) / W:.1%} of the page")
        if start_shot:
            sh, st_ = start_shot[0]
            from PIL import Image
            im = Image.open(sh).convert("RGB"); k = im.width / st_["canvasFrame"][4]
            cx, cy, cw, ch = (v * k for v in st_["canvasFrame"][:4]); v = st_["view"]
            col = cx + (st_["lineLimitX"] - v["x"]) / v["w"] * cw
            t0 = 0.0
            if cx < col < cx + cw:
                px = [im.getpixel((int(col), int(cy + ch * (0.25 + 0.5 * i / 40)))) for i in range(41)]
                t0 = sum(b - r_ for r_, g_, b in px) / len(px)
            rep.check(t0 < 3, "(c) not to be seen at the start of a line (screenshot)", f"blue tint at the limit's column {t0:.1f}")
        rep.check(after_nl and all(a <= 0.01 for a in after_nl), "(c) gone after the next-line move", f"{after_nl}")
        # Hidden without writing mode (no width chosen), and never in the page export.
        ensure(app, "writing", False, "w"); time.sleep(0.3)
        s5 = app.state(); shot5 = rep.shot(app, "writing mode off: no line")
        rep.check(s5.get("lineLimitX") is None, "(c) hidden when writing mode is off", str(s5.get("lineLimitX")))
        png = os.path.join(app.out, "limit-export.png"); app.cmd({"cmd": "exportPNG", "path": png})
        from PIL import Image
        im = Image.open(png).convert("RGB")
        blue = sum(1 for x in range(im.width) for y in range(0, im.height, 7) if (lambda p: p[2] - p[0] > 25 and p[0] > 150)(im.getpixel((x, y))))
        rep.check(blue == 0, "(c) not in the page export", f"{blue} bluish pixels")
        ensure(app, "draw", False, "d")

    @scenario("next-line-run-start", "Karthik (28 Oct): in writing mode a block wraps back to where its first line began (not the page's left margin), and the width (50% / 75% / 100% of the page) counts from there, capped at the page's right margin. A block from the margin still wraps to the margin. Outside writing mode the page never moves. At 300%.")
    def _():
        def run(start_frac, width_idx, label):
            ensure(app, "draw", False, "d"); app.press("n")
            ensure(app, "writing", True, "w")
            app.click("writing", "chevron"); app.cmd({"cmd": "panelPick", "writing": width_idx}); app.press("esc")
            app.cmd({"cmd": "menu", "action": "resetZoom"}); settle(app)
            ensure(app, "draw", True, "d")
            app.cmd({"cmd": "zoomMenu", "pick": "300%"}); settle(app, limit=3)
            for _ in range(16): app.press("up")
            for _ in range(16): app.press("left")
            st = app.state(); W = st["pageW"]; vw = st["view"]["w"]
            for _ in range(40):   # move the view (by hand: arrow keys) until the run's start is a fifth into it
                if st["view"]["x"] >= W * start_frac - vw * 0.2 - 1 or st["view"]["x"] + vw >= W - 1: break
                app.press("right"); settle(app); st = app.state()
            time.sleep(1.4)
            n0 = st["strokes"]; pad_w, pad_h = st["padMM"]
            top = app.cmd({"cmd": "toPagePt", "point": [0, pad_h * 0.75]})["point"][1]
            views, limits = [], []
            def seen(w, s_, b_, a_):
                if a_ and a_.get("lineLimitX") is not None and a_["newLines"] == b_["newLines"]: limits.append(a_["lineLimitX"])
                if s_["newLines"] > b_["newLines"]: views.append((s_["view"], s_.get("nextLine")))
            write_rows(23000 + int(start_frac * 1000) + width_idx * 100, (SENTENCE + " " + SENTENCE + " " + SENTENCE).split()[:24], [W * start_frac, top], on_word=seen)
            s2 = app.state()
            mine = s2["pageBounds"][n0:]
            lines = []
            for b in mine:
                y = (b[1] + b[3]) / 2
                for L in lines:
                    if abs(L[0] - y) < 30: L[1] = min(L[1], b[0]); L[2] = max(L[2], b[2]); break
                else: lines.append([y, b[0], b[2]])
            lines.sort(key=lambda L: -L[0])
            rep.step(label, lines=[(round(L[1] / W, 3), round(L[2] / W, 3)) for L in lines], limits=sorted({round(l / W, 3) for l in limits}),
                     afterNewLine=[(round(v["x"] / W, 3), nl and round(nl[0] / W, 3)) for v, nl in views])
            rep.shot(app, f"{label}: after the next-line pan")
            app.cmd({"cmd": "menu", "action": "resetZoom"}); settle(app, limit=3); time.sleep(0.6)
            rep.shot(app, f"{label}: the whole page")
            return W, lines, views, limits
        for start, wi, wname in [(0.30, 0, "50%"), (0.20, 1, "75%"), (0.55, 0, "50%"), (0.035, 0, "50%"), (0.035, 2, "100%")]:
            label = f"{wname} from {'the margin' if start < 0.05 else f'{start:.0%}'}"
            W, lines, views, limits = run(start, wi, label)
            want = min(lines[0][1] / W + [0.5, 0.75, 1.0][wi], CAP) if lines else None
            rep.check(len(lines) >= 2 and views, f"{label}: the block wraps to a second line", f"{len(lines)} lines, {len(views)} next-line pans")
            if len(lines) < 2 or not views: continue
            rep.check(limits and all(abs(l / W - want) < 0.005 for l in limits), f"{label}: the line's limit is its start + {wname} of the page (capped at {CAP:.0%} of the page)",
                      f"start {lines[0][1] / W:.1%}, limit {sorted({round(l / W, 3) for l in limits})}, want {want:.1%}")
            rep.check(all(want - 0.15 <= L[2] / W <= want + 0.06 for L in lines[:-1]), f"{label}: full lines end near it", f"line ends {[round(L[2] / W, 3) for L in lines]}, limit {want:.1%}")
            v, nl = views[0]
            rep.check(abs(lines[1][1] - lines[0][1]) / W < 0.04, f"{label}: the next line starts where the block's first line began",
                      f"first line {lines[0][1] / W:.1%}, second {lines[1][1] / W:.1%}")
            rep.check(v["x"] <= lines[0][1] <= v["x"] + v["w"] * 0.25, f"{label}: the next-line pan brings the view back to the block's start",
                      f"view {v['x'] / W:.1%}-{(v['x'] + v['w']) / W:.1%}, block start {lines[0][1] / W:.1%}")
        # Outside writing mode the page never moves: write past the middle of the page at 100%.
        ensure(app, "draw", False, "d"); app.press("n"); ensure(app, "writing", False, "w")
        app.cmd({"cmd": "menu", "action": "resetZoom"}); settle(app)
        ensure(app, "draw", True, "d")
        st = app.state(); W = st["pageW"]; nl0 = st["newLines"]; v0 = st["view"]
        old_h = hand.h; hand.h = 4.5
        top = app.cmd({"cmd": "toPagePt", "point": [0, st["padMM"][1] * 0.8]})["point"][1]
        write_rows(24500, (SENTENCE + " " + SENTENCE).split(), [W * 0.3, top])
        hand.h = old_h
        st2 = app.state()
        rep.check(st2["newLines"] == nl0 and abs(st2["view"]["x"] - v0["x"]) < 1 and abs(st2["view"]["y"] - v0["y"]) < 1 and max(b[2] for b in st2["pageBounds"]) > W * 0.85,
                  "writing mode off: writing across the page never moves it (no next-line pan)", f"new lines {st2['newLines'] - nl0}, view {v0['x']:.0f},{v0['y']:.0f} -> {st2['view']['x']:.0f},{st2['view']['y']:.0f}, ink to {max(b[2] for b in st2['pageBounds']) / W:.0%}")
        ensure(app, "draw", False, "d")

    @scenario("block-mid-page", "Karthik (29 Oct, 4988285): a block started at the middle of the page and written to the width marker or the page's right edge always goes to the next line at the block's start, and the guide line sits at the block's start + the width (capped at the right margin). Widths 50/75/100% at 100% and 300%, and after a pan to the middle.")
    def _():
        def case(width_idx, zoom, how):
            ensure(app, "draw", False, "d"); app.press("n")
            ensure(app, "writing", False, "w"); ensure(app, "writing", True, "w")
            app.click("writing", "chevron"); app.cmd({"cmd": "panelPick", "writing": width_idx}); app.press("esc")
            app.cmd({"cmd": "menu", "action": "resetZoom"}); settle(app)
            ensure(app, "draw", True, "d")
            st = app.state(); W = st["pageW"]; pad_w, pad_h = st["padMM"]
            if zoom != "100%":
                app.cmd({"cmd": "zoomMenu", "pick": zoom}); settle(app, limit=3)
                for _ in range(16): app.press("up")
                for _ in range(16): app.press("left")
                st = app.state()
                if how == "pan":   # two-finger pans to the middle of the page (by hand)
                    for _ in range(12):
                        if st["view"]["x"] >= W * 0.5 - st["view"]["w"] * 0.2: break
                        app.touch(two_finger(pad_w * 0.7, pad_h * 0.5, 25, 25, shift=(-pad_w * 0.25, 0), dur=0.4)); settle(app); st = app.state()
                else:
                    for _ in range(40):
                        if st["view"]["x"] >= W * 0.5 - st["view"]["w"] * 0.2 - 1: break
                        app.press("right"); settle(app); st = app.state()
            time.sleep(1.4)
            st = app.state(); n0 = st["strokes"]
            hh = 4.5 if zoom == "100%" else 9
            old_h = hand.h; hand.h = hh
            top = app.cmd({"cmd": "toPagePt", "point": [0, pad_h * 0.75]})["point"][1]
            views, lims = [], []
            def seen(w, s_, b_, a_):
                if a_ and a_["newLines"] == b_["newLines"] and a_.get("lineLimitX") is not None: lims.append((a_["lineLimitX"], a_.get("limitDrawn")))
                if s_["newLines"] > b_["newLines"]: views.append((s_["view"], s_.get("nextLine")))
            write_rows(25000 + width_idx * 300 + (0 if zoom == "100%" else 100) + (50 if how == "pan" else 0), (SENTENCE + " " + SENTENCE + " " + SENTENCE).split()[:18], [W * 0.5, top], on_word=seen, pause=0.8)
            hand.h = old_h
            s2 = app.state(); mine = s2["pageBounds"][n0:]
            lines = []
            for b in mine:
                y = (b[1] + b[3]) / 2
                for L in lines:
                    if abs(L[0] - y) < (12 if zoom == "100%" else 37): L[1] = min(L[1], b[0]); L[2] = max(L[2], b[2]); break
                else: lines.append([y, b[0], b[2]])
            lines.sort(key=lambda L: -L[0])
            lines = [L for L in lines if L[2] - L[1] > W * 0.04]   # a stray i-dot or comma alone isn't a line
            label = f"{['50%', '75%', '100%'][width_idx]} at zoom {zoom}{' after a pan' if how == 'pan' else ''}"
            start = lines[0][1] if lines else W * 0.5
            want = min(start + [0.5, 0.75, 1.0][width_idx] * W, W * CAP)
            rep.step(label, lines=[(round(L[1] / W, 3), round(L[2] / W, 3)) for L in lines], limits=sorted({round(l / W, 3) for l, _ in lims}),
                     afterNewLine=[(round(v["x"] / W, 3), round((v["x"] + v["w"]) / W, 3), nl and round(nl[0] / W, 3)) for v, nl in views])
            rep.check(views, f"{label}: writing to the marker / the page's edge moves to the next line (never stuck)", f"{len(views)} next-line moves, lines {[(round(L[1] / W, 2), round(L[2] / W, 2)) for L in lines]}")
            rep.check(lims and all(abs(l - want) < 0.01 * W for l, _ in lims), f"{label}: the guide line is at the block's start + the width (capped at {CAP:.0%} of the page)",
                      f"start {start / W:.1%}, limits {sorted({round(l / W, 3) for l, _ in lims})}, want {want / W:.1%}")
            if views:
                v, nl = views[0]
                rep.check(nl and abs(nl[0] - start) < 0.02 * W, f"{label}: the next line is at the block's start", f"next line at {nl and round(nl[0] / W, 3)}, block start {start / W:.1%}")
                rep.check(v["x"] - 1 <= start <= v["x"] + v["w"] * (0.6 if v["w"] >= W * 0.99 else 0.5), f"{label}: the view after the move shows the block's start", f"view {v['x'] / W:.1%}-{(v['x'] + v['w']) / W:.1%}")
                rep.check(len(lines) >= 2 and abs(lines[1][1] - start) < 0.04 * W, f"{label}: the second line starts at the block's start", f"{[round(L[1] / W, 3) for L in lines]}")
            rep.shot(app, label)
        for wi in (0, 1, 2):
            for z in ("100%", "300%"):
                case(wi, z, "keys")
        case(2, "300%", "pan"); case(0, "300%", "pan")
        ensure(app, "draw", False, "d")

    @scenario("block-edge-cases", "Karthik (29 Oct): writing a block from the middle of the page to the page's right side. (i) Ink that reaches about 93-95% of the page (where you can still write) brings the next line; it doesn't wait for ink right at the page's edge. (ii) After a next-line move, a pinch and a small pan, starting the new line a little right of the block's start keeps the block: the next move still goes back to its start. 300%, 100% width.")
    def _():
        ensure(app, "draw", False, "d"); app.press("n")
        ensure(app, "writing", False, "w"); ensure(app, "writing", True, "w")
        app.click("writing", "chevron"); app.cmd({"cmd": "panelPick", "writing": 2}); app.press("esc")
        app.cmd({"cmd": "menu", "action": "resetZoom"}); settle(app)
        ensure(app, "draw", True, "d")
        app.cmd({"cmd": "zoomMenu", "pick": "300%"}); settle(app, limit=3)
        for _ in range(16): app.press("up")
        st = app.state(); W = st["pageW"]; pad_w, pad_h = st["padMM"]
        for _ in range(40):
            if st["view"]["x"] >= W * 0.5 - st["view"]["w"] * 0.2 - 1: break
            app.press("right"); settle(app); st = app.state()
        time.sleep(1.4)
        p0 = app.cmd({"cmd": "toPagePt", "point": [10, 10]})["point"]; p1 = app.cmd({"cmd": "toPagePt", "point": [20, 10]})["point"]
        upm = (p1[0] - p0[0]) / 10
        old_h = hand.h; hand.h = 6
        cid = [27000]
        def word_at(w, x, y):
            (px, py), = app.cmd({"cmd": "toPad", "points": [[x, y]]})["points"]
            if px + hand.width(w) > pad_w * 0.9:   # out of pad: pan by hand first, as a person does
                app.touch(two_finger(pad_w / 2, pad_h / 2, 25, 25, shift=(-(pad_w * 0.4), 0), dur=0.5)); settle(app)
                (px, py), = app.cmd({"cmd": "toPad", "points": [[x, y]]})["points"]
            strokes = hand.word(w, px, py); fr, cid[0] = hand.frames(strokes, cid[0])
            n = app.state()["strokes"]
            app.touch(fr + [[0.008, []]] * int(1.0 / 0.008), settle=0.2)
            for _ in range(40):
                if not app.state().get("pendingMove"): break
                time.sleep(0.05)
            settle(app); s_ = app.state()
            return s_, max(b[2] for b in s_["pageBounds"][n:]) if s_["pageBounds"][n:] else x
        y = app.cmd({"cmd": "toPagePt", "point": [0, pad_h * 0.7]})["point"][1]
        words = ("the quick brown fox jumps over the lazy dog and keeps on going " * 3).split()
        # (i) write from 50% until the ink is at 95-97% of the page, then stop (the pad's edge guard and the page's
        # edge are close beyond that).
        x = W * 0.5; nl0 = app.state()["newLines"]; right = x; i = 0; s_ = app.state()
        while i < len(words) and s_["newLines"] == nl0 and right < W * 0.95:   # until the ink passes 95%, ending before 96.8%
            w_ = words[i]; sp = hand.h * 0.6 * upm
            if i > 0 and right + sp + hand.width(w_) * upm > W * 0.968:
                w_ = next((c for c in ("an", "a", "i") if right + sp + hand.width(c) * upm <= W * 0.968), None)
                if w_ is None: break
            s_, right = word_at(w_, x if i == 0 else right + sp, y); i += 1
        time.sleep(0.8); s_ = app.state()
        rep.step("(i)", inkRight=round(right / W, 3), limit=s_.get("lineLimitX") and round(s_["lineLimitX"] / W, 3), newLines=s_["newLines"] - nl0)
        rep.check(s_["newLines"] > nl0, "(i) ink at 95-96.5% of the page (a block from the middle, 100% width) brings the next line", f"ink to {right / W:.1%}, limit {s_.get('lineLimitX') and s_['lineLimitX'] / W:.1%}, new lines {s_['newLines'] - nl0}")
        block = W * 0.5
        if s_["newLines"] == nl0:   # let the rest of (ii) run: finish the line past the page's edge
            while s_["newLines"] == nl0 and i < len(words): s_, right = word_at(words[i], right + hand.h * 0.6 * upm, y); i += 1
        # (ii) after the move: a pinch and a small pan, then the new line starts 4% of the page right of the block's start.
        nl1 = s_["newLines"]; nlx = (s_.get("nextLine") or [block, y - 60])
        app.touch(two_finger(pad_w * 0.5, pad_h * 0.4, 25, 29, dur=0.4)); settle(app)   # a small pinch
        v0 = app.state()["view"]; app.press("right"); app.press("right"); settle(app)   # and a nudge right (> 10% of the view)
        rep.step("(ii) hand move", dx=round(app.state()["view"]["x"] - v0["x"]), viewW=round(v0["w"]))
        y2 = nlx[1]; x = block + W * 0.04; right = x; j = 0
        while j < 30 and app.state()["newLines"] == nl1:
            s_, right = word_at(words[(i + j) % len(words)], x if j == 0 else right + hand.h * 0.6 * upm, y2); j += 1
        s2 = app.state(); nl2 = s2.get("nextLine") or [None]
        rep.step("(ii)", nextLine=nl2[0] and round(nl2[0] / W, 3), newLines=s2["newLines"] - nl1)
        rep.check(s2["newLines"] > nl1 and nl2[0] is not None and abs(nl2[0] - block) < 0.02 * W,
                  "(ii) a pinch / small pan after the move and a line started 4% to the right keep the block: the next line is back at its start",
                  f"next line at {nl2[0] and nl2[0] / W:.1%}, block start {block / W:.1%}")
        # (iii) after a move, go back and finish the previous line (pan right with the arrows, a word after its end), then
        # write the next line at the block's start: the block stays, and its next move goes back to the start.
        s3 = app.state(); prev = [b for b in s3["pageBounds"] if abs((b[1] + b[3]) / 2 - y2) < 40]
        prev_end = max(b[2] for b in prev) if prev else W * 0.9
        prev_y = sum((b[1] + b[3]) / 2 for b in prev) / len(prev) if prev else y2
        nl3 = s3["newLines"]; nxt = (s3.get("nextLine") or [block, y2 - 60])
        for _ in range(12):
            v = app.state()["view"]
            if v["x"] + v["w"] * 0.85 > prev_end + 60 or v["x"] + v["w"] >= W - 1: break
            app.press("right"); settle(app)
        for _ in range(4): app.press("up")
        settle(app)
        s_, r3 = word_at("too", prev_end + hand.h * 0.6 * upm, prev_y - 6)
        time.sleep(0.8); s4 = app.state()
        rep.step("(iii) finished the previous line", prevEnd=round(prev_end / W, 3), wordTo=round(r3 / W, 3), newLines=s4["newLines"] - nl3, nextLine=s4.get("nextLine"))
        nlx4 = (s4.get("nextLine") or [None])[0]
        rep.check(s4["newLines"] == nl3 or (nlx4 is not None and abs(nlx4 - block) < 0.02 * W),
                  "(iii) finishing the previous line after a move doesn't start a block there (no move to the next line away from the block's start)",
                  f"new lines {s4['newLines'] - nl3}, next line at {nlx4 and nlx4 / W:.1%}, block start {block / W:.1%}")
        for _ in range(16): app.press("left")
        for _ in range(4): app.press("down")
        settle(app)
        x = nxt[0]; right = x; k = 0; nl4 = app.state()["newLines"]
        while k < 30 and app.state()["newLines"] == nl4:
            s_, right = word_at(words[k % len(words)], x if k == 0 else right + hand.h * 0.6 * upm, nxt[1]); k += 1
        s5 = app.state(); nl5 = s5.get("nextLine") or [None]
        rep.check(s5["newLines"] > nl4 and nl5[0] is not None and abs(nl5[0] - block) < 0.02 * W,
                  "(iii) finishing the previous line after a move, then going on below, keeps the block: the next line is back at its start",
                  f"next line at {nl5[0] and nl5[0] / W:.1%}, block start {block / W:.1%}")
        hand.h = old_h
        rep.shot(app, "block from the middle to the page's right side")
        ensure(app, "draw", False, "d")

    @scenario("block-pan-continue", "Karthik (29 Oct, 74c61cf, page 18): a block started at 22% of the page, 50% width, at 200%. He wrote, undid a word and rewrote it, then panned right by hand and went on writing the same line a word gap after its end: that started a new block there (the limit jumped to the page's edge and the move went back to where he'd panned to). Carrying on the line after a hand pan keeps the block; the move comes at its start + 50% and goes back to its start. Also: ink that stops at 93-95% of the page (blocks from 20/50/60%, widths 50/75/100%) always brings the next line at the block's start.")
    def _():
        def setup(width_idx, zoom, start):
            ensure(app, "draw", False, "d"); app.press("n")
            ensure(app, "writing", False, "w"); ensure(app, "writing", True, "w")
            app.click("writing", "chevron"); app.cmd({"cmd": "panelPick", "writing": width_idx}); app.press("esc")
            app.cmd({"cmd": "menu", "action": "resetZoom"}); settle(app)
            ensure(app, "draw", True, "d")
            st = app.state(); W = st["pageW"]
            if zoom != "100%":
                app.cmd({"cmd": "zoomMenu", "pick": zoom}); settle(app, limit=3)
                for _ in range(16): app.press("up")
                for _ in range(16): app.press("left")
                st = app.state()
                for _ in range(40):
                    if st["view"]["x"] >= W * start - st["view"]["w"] * 0.15 - 1: break
                    app.press("right"); settle(app); st = app.state()
            time.sleep(1.4)
            return app.state()
        cid = [29000]
        def word_at(w, x, y, wait=1.0, pan=True, poll=True):
            st = app.state(); pad_w, pad_h = st["padMM"]
            (px, py), = app.cmd({"cmd": "toPad", "points": [[x, y]]})["points"]
            if pan and px + hand.width(w) > pad_w * 0.9:   # out of pad: pan by hand first, as a person does
                app.touch(two_finger(pad_w / 2, pad_h / 2, 25, 25, shift=(-(pad_w * 0.4), 0), dur=0.5)); settle(app)
                (px, py), = app.cmd({"cmd": "toPad", "points": [[x, y]]})["points"]
            strokes = hand.word(w, px, py); fr, cid[0] = hand.frames(strokes, cid[0])
            n = app.state()["strokes"]
            app.touch(fr + [[0.008, []]] * int(wait / 0.008), settle=0.2)
            lifted[0] = time.time() - wait - 0.2
            for _ in range(60 if poll else 0):
                if not app.state().get("pendingMove"): break
                time.sleep(0.05)
            if poll: settle(app)
            s_ = app.state()
            return s_, max(b[2] for b in s_["pageBounds"][n:]) if s_["pageBounds"][n:] else x
        lifted = [0.0]
        words = ("the quick brown fox jumps over the lazy dog and keeps on going " * 4).split()
        old_h = hand.h

        # (a) His sequence: 22%, 50%, 200%: write, undo the last word and rewrite it, pan right by hand, carry on a word
        # gap (5% of the page, his was 4.9%) after the line's end.
        for variant in ("pan after rewriting", "pan right after the undo"):
            st = setup(0, "200%", 0.22); W = st["pageW"]; pad_w, pad_h = st["padMM"]
            p0 = app.cmd({"cmd": "toPagePt", "point": [10, 10]})["point"]; p1 = app.cmd({"cmd": "toPagePt", "point": [20, 10]})["point"]
            upm = (p1[0] - p0[0]) / 10; hand.h = 6; sp = hand.h * 0.6 * upm
            y = app.cmd({"cmd": "toPagePt", "point": [0, pad_h * 0.7]})["point"][1]
            start = W * 0.22; nl0 = st["newLines"]; lims = []; right = start; i = 0
            while right < W * 0.42 and i < 20:
                s_, right = word_at(words[i], start if i == 0 else right + sp, y, pan=False); i += 1
                if s_.get("lineLimitX") is not None: lims.append(s_["lineLimitX"])
            n_before = app.state()["strokes"]
            app.touch(double_tap(2, pad_w / 2, pad_h / 2)); settle(app)   # undo the last word's last stroke
            r_ = max(b[2] for b in app.state()["pageBounds"][-6:])
            if variant == "pan after rewriting":
                s_, right = word_at("dog", r_ + sp, y, pan=False)
            else:
                right = r_
            # His gap after the pan was 78 page units: 1.2x the old "somewhere new" gap for his line then (the rewritten
            # word alone, 42 high: max(1.5 x height, 8% of the view) = 64). The same here for this hand's line, under 9.5%.
            sb = app.state(); vw = sb["view"]["w"]
            rew = [b for b in sb["pageBounds"][-8:] if abs((b[1] + b[3]) / 2 - y) < 60 and b[0] > r_ - W * 0.08]
            lh = (max(b[3] for b in rew) - min(b[1] for b in rew)) if rew else 40
            gap_ = min(1.25 * max(1.5 * lh, 0.08 * vw), 0.095 * W)
            app.touch(two_finger(pad_w / 2, pad_h / 2, 25, 25, shift=(-(pad_w * 0.4), 0), dur=0.5)); settle(app)   # a hand pan right
            x = right + gap_; j = 0; first_move = None
            while j < 30 and app.state()["newLines"] == nl0:
                s_, r2 = word_at(words[(i + j) % len(words)], x, y); j += 1
                if s_.get("lineLimitX") is not None and s_["newLines"] == nl0: lims.append(s_["lineLimitX"])
                if s_["newLines"] > nl0: first_move = right
                right = r2; x = right + sp
            s2 = app.state(); nl = s2.get("nextLine") or [None]
            label = f"(a) 22%, 50%, 200%, {variant}"
            want = start + 0.5 * W
            rep.step(label, gapAfterPan=round(gap_ / W, 3), limits=sorted({round(l / W, 3) for l in lims}), inkAtMove=first_move and round(first_move / W, 3), nextLine=nl[0] and round(nl[0] / W, 3), newLines=s2["newLines"] - nl0, undone=n_before - app.state()["strokes"])
            rep.check(lims and all(abs(l - want) < 0.01 * W for l in lims), f"{label}: the limit stays at the block's start + 50% ({want / W:.0%}) after the pan", f"limits {sorted({round(l / W, 3) for l in lims})}")
            rep.check(s2["newLines"] > nl0 and first_move is not None and first_move < want + 0.12 * W, f"{label}: the next line comes once the ink crosses it (not at the page's edge)", f"ink at the move {first_move and first_move / W:.1%}, new lines {s2['newLines'] - nl0}")
            rep.check(nl[0] is not None and abs(nl[0] - start) < 0.02 * W, f"{label}: the next line is back at the block's start", f"next line at {nl[0] and nl[0] / W:.1%}, block start 22%")
            rep.shot(app, label)

        # (b) Ink that stops at 93-95% of the page (or the move came earlier, at the width): a next-line move to the block's
        # start, within 2.5 s of the lift. Zoom 100%.
        for start in (0.20, 0.50, 0.60):
            for wi, wname in ((0, "50%"), (1, "75%"), (2, "100%")):
                st = setup(wi, "100%", start); W = st["pageW"]; pad_w, pad_h = st["padMM"]
                p0 = app.cmd({"cmd": "toPagePt", "point": [10, 10]})["point"]; p1 = app.cmd({"cmd": "toPagePt", "point": [20, 10]})["point"]
                upm = (p1[0] - p0[0]) / 10; hand.h = 4.5; sp = hand.h * 0.6 * upm
                y = app.cmd({"cmd": "toPagePt", "point": [0, pad_h * 0.7]})["point"][1]
                x0 = W * start; nl0 = st["newLines"]; right = x0; i = 0; s_ = st; hi = W * 0.947
                while i < 40 and s_["newLines"] == nl0 and right < W * 0.93:
                    w_ = words[i % len(words)]
                    if i > 0 and right + sp + hand.width(w_) * upm > hi:
                        w_ = next((c for c in ("an", "a", "i") if right + sp + hand.width(c) * upm <= hi), None)
                        if w_ is None: break
                    s_, right = word_at(w_, x0 if i == 0 else right + sp, y, wait=0.6, pan=False, poll=False); i += 1
                # Karthik (b03bac2): the same 400 ms word-gap pause as at the width marker, not 1.5 s. The finger has been
                # up 0.6 s+ here; look by 0.9 s after the lift.
                while time.time() - lifted[0] < 0.9 and app.state()["newLines"] == nl0: time.sleep(0.03)
                s2 = app.state(); dt = time.time() - lifted[0]; nl = s2.get("nextLine") or [None]
                time.sleep(max(0, 2.0 - dt)); s3 = app.state()   # (and whether it came later)
                label = f"(b) {wname} from {start:.0%}"
                rep.step(label, inkRight=round(right / W, 3), limit=s_.get("lineLimitX") and round(s_["lineLimitX"] / W, 3), newLinesBy900ms=s2["newLines"] - nl0, newLinesBy2s=s3["newLines"] - nl0, nextLine=nl[0] and round(nl[0] / W, 3))
                rep.check(s2["newLines"] > nl0 and nl[0] is not None and abs(nl[0] - x0) < 0.02 * W,
                          f"{label}: the line (ink to {right / W:.1%}) brings the next line at the block's start at the 400 ms word gap (by 0.9 s after the lift)",
                          f"ink to {right / W:.1%}, new lines by {dt:.2f} s: {s2['newLines'] - nl0}, by 2 s: {s3['newLines'] - nl0}, next line at {nl[0] and nl[0] / W:.1%}")
        hand.h = old_h
        ensure(app, "draw", False, "d")

    @scenario("near-marker", "Karthik on 0.1.1 (fd5c559): a word that ends just inside the width marker (no room for another) brings the next line at the same 400 ms word gap as crossing it; ink that stops well before the marker (mid-line) doesn't. Widths 50/75/100% from the margin, at 100% and 300%.")
    def _():
        cid = [31000]
        def setup(width_idx, zoom):
            ensure(app, "draw", False, "d"); app.press("n")
            ensure(app, "writing", False, "w"); ensure(app, "writing", True, "w")
            app.click("writing", "chevron"); app.cmd({"cmd": "panelPick", "writing": width_idx}); app.press("esc")
            app.cmd({"cmd": "menu", "action": "resetZoom"}); settle(app)
            ensure(app, "draw", True, "d")
            if zoom != "100%":
                app.cmd({"cmd": "zoomMenu", "pick": zoom}); settle(app, limit=3)
                for _ in range(16): app.press("up")
                for _ in range(16): app.press("left")
            time.sleep(1.4)
            for _ in range(3):   # key delivery to the background app is flaky: make sure writing mode is on
                if app.state().get("lineLimitX") is not None: break
                ensure(app, "draw", False, "d"); ensure(app, "writing", True, "w"); ensure(app, "draw", True, "d"); time.sleep(0.5)
            return app.state()
        lifted = [0.0]
        def word_at(w, x, y):
            st = app.state(); pad_w, pad_h = st["padMM"]
            (px, py), = app.cmd({"cmd": "toPad", "points": [[x, y]]})["points"]
            if px + hand.width(w) > pad_w * 0.88:   # out of pad: pan right by hand, as a person does
                app.touch(two_finger(pad_w / 2, pad_h / 2, 25, 25, shift=(-(pad_w * 0.4), 0), dur=0.5)); settle(app)
                (px, py), = app.cmd({"cmd": "toPad", "points": [[x, y]]})["points"]
            strokes = hand.word(w, px, py); fr, cid[0] = hand.frames(strokes, cid[0])
            n = app.state()["strokes"]
            app.touch(fr + [[0.008, []]] * int(0.3 / 0.008), settle=0.0)   # lifted 0.3 s: under the 400 ms gap
            lifted[0] = time.time() - 0.3
            s_ = app.state()
            return s_, max(b[2] for b in s_["pageBounds"][n:]) if s_["pageBounds"][n:] else x
        words = ("the quick brown fox jumps over the lazy dog and keeps on going " * 4).split()
        def pct(v, W): return "none" if v is None else f"{v / W:.1%}"
        old_h = hand.h
        for zoom in ("100%", "300%"):
            for wi, wname, frac in ((0, "50%", 0.5), (1, "75%", 0.75), (2, "100%", 1.0)):
                for kind in ("just inside", "mid-line"):
                    st = setup(wi, zoom); W = st["pageW"]; pad_w, pad_h = st["padMM"]
                    p0 = app.cmd({"cmd": "toPagePt", "point": [10, 10]})["point"]; p1 = app.cmd({"cmd": "toPagePt", "point": [20, 10]})["point"]
                    upm = (p1[0] - p0[0]) / 10; hand.h = 4.5 if zoom == "100%" else 7; sp = hand.h * 0.7 * upm
                    y = app.cmd({"cmd": "toPagePt", "point": [0, pad_h * 0.7]})["point"][1]
                    x0 = st["view"]["x"] + st["view"]["w"] * 0.06; lw = frac * W
                    limit = min(x0 + lw, W * CAP)
                    # Where the ink should stop: just inside the marker (0.3-2.5% of the line width before it; at the
                    # page's edge, past 93% of the page), or mid-line (about 8% of the line width before it).
                    lo, hi = (limit - 0.025 * lw, limit - 0.003 * lw) if kind == "just inside" else (limit - 0.10 * lw, limit - 0.06 * lw)
                    if kind == "just inside" and limit >= W * CAP - 1: lo = max(lo, W * 0.932)
                    nl0 = st["newLines"]; right = x0; i = 0; s_ = st; done = False
                    while i < 60 and s_["newLines"] == nl0 and right < lo:
                        w_ = words[i % len(words)]; gap = sp
                        if i > 0 and right + sp + hand.width(w_) * upm > hi:
                            # A short last word to land in the band, with a tight space if a normal one won't fit.
                            w_, gap = next(((c, g) for g in (sp, sp * 0.4) for c in ("an", "a", "i") if right + g + hand.width(c) * upm <= hi), (None, 0))
                            if w_ is None: break
                        s_, right = word_at(w_, x0 if i == 0 else right + gap, y); i += 1
                        time.sleep(0.05)
                    lim_seen = s_.get("lineLimitX")
                    if lim_seen is None: rep.step("no limit reported", writing=s_.get("writing"), draw=s_.get("draw"))
                    lim_seen = lim_seen if lim_seen is not None else limit
                    label = f"{wname} at {zoom}, ink {kind}"
                    if kind == "just inside":
                        while time.time() - lifted[0] < 0.9 and app.state()["newLines"] == nl0: time.sleep(0.03)
                        s2 = app.state(); dt = time.time() - lifted[0]; nl = s2.get("nextLine") or [None]
                        rep.step(label, inkRight=round(right / W, 4), limit=lim_seen and round(lim_seen / W, 4), shortOfMarker=lim_seen and round((lim_seen - right) / lw * 100, 2), newLines=s2["newLines"] - nl0, nextLine=nl[0] and round(nl[0] / W, 3))
                        rep.check(lim_seen is not None and right < lim_seen and s2["newLines"] > nl0 and nl[0] is not None and abs(nl[0] - x0) < 0.02 * W,
                                  f"{label}: a word ending just inside the marker brings the next line at the 400 ms gap (by 0.9 s), back at the block's start",
                                  f"ink {right / W:.1%}, marker {lim_seen / W:.1%} ({(lim_seen - right) / lw * 100:.1f}% of the line short), new lines by {dt:.2f} s: {s2['newLines'] - nl0}, next line at {pct(nl[0], W)}")
                    else:
                        time.sleep(max(0, 1.5 - (time.time() - lifted[0]))); s2 = app.state()
                        rep.step(label, inkRight=round(right / W, 4), limit=lim_seen and round(lim_seen / W, 4), shortOfMarker=lim_seen and round((lim_seen - right) / lw * 100, 2), newLines=s2["newLines"] - nl0)
                        rep.check(lim_seen is not None and (lim_seen - right) > 0.04 * lw and s2["newLines"] == nl0,
                                  f"{label}: ink stopping well before the marker (mid-line) doesn't bring the next line (1.5 s later)",
                                  f"ink {right / W:.1%}, marker {lim_seen / W:.1%} ({(lim_seen - right) / lw * 100:.1f}% of the line short), new lines {s2['newLines'] - nl0}")
        hand.h = old_h
        ensure(app, "draw", False, "d")

    @scenario("half-line-hard-limit", "½-page lines at zoom 100% (Karthik's screenshot): ink never goes past 50% of the page; the word that would cross the mark goes to the next line.")
    def _():
        hard_limit(0.5, 0, "½-page")

    @scenario("three-quarter-line-hard-limit", "¾-page lines at zoom 100%: ink never goes past 75% of the page.")
    def _():
        hard_limit(0.75, 1, "¾-page")

    @scenario("undo-redo-taps", "Two-finger double tap undoes, three-finger double tap redoes; the view stays put and no ink is drawn.")
    def _():
        if not app.state()["draw"]: app.press("d", until=lambda s: s["draw"])
        st = app.state(); pad_w, pad_h = st["padMM"]
        fr, _ = hand.frames(hand.word("undo", pad_w * 0.3, pad_h * 0.4), 3000)
        app.touch(fr)
        a = app.state()
        app.touch(double_tap(2, pad_w / 2, pad_h / 2))
        b = app.state()
        rep.check(b["strokes"] == a["strokes"] - 1, "two-finger double tap: one stroke undone", f"{a['strokes']} -> {b['strokes']}")
        rep.check(b["view"] == a["view"], "view unchanged by the tap")
        rep.check("Undo" in b.get("toast", ""), "an 'Undo' note", b.get("toast"))
        rep.shot(app, "after the two-finger double tap")
        app.touch(double_tap(3, pad_w / 2, pad_h / 2))
        c = app.state()
        rep.check(c["strokes"] == a["strokes"], "three-finger double tap: redone", f"{b['strokes']} -> {c['strokes']}")

    @scenario("eraser", "Rub out a word with the eraser; then put the eraser on ink and start a two-finger pan at once, which must erase nothing.")
    def _():
        if not app.state()["draw"]: app.press("d", until=lambda s: s["draw"])
        st = app.state(); pad_w, pad_h = st["padMM"]
        fr, _ = hand.frames(hand.word("erase", pad_w * 0.3, pad_h * 0.3, hand.roman), 4000)
        app.touch(fr)
        a = app.state()
        app.press("e", until=lambda s: s["tool"] == "eraser")
        # The pan-erase case: the eraser lands on ink and a second finger joins 30 ms later (a pan).
        bx = app.cmd({"cmd": "toPad", "points": [a["lastStrokeMid"]]})["points"][0]   # right on the ink
        fr = [[0.008, [[5000, bx[0] + i * 0.3, bx[1], 15, 0.5, 7.5]]] for i in range(5)]
        fr += [[0.008, [[5000, bx[0] + i * 0.8, bx[1], 15, 0.5, 7.5], [5001, bx[0] + 25 + i * 0.8, bx[1], 15, 0.5, 7.5]]] for i in range(40)]
        fr += [[0.008, []], [0.3, []]]
        app.touch(fr)
        b = app.state()
        rep.check(b["strokes"] == a["strokes"], "eraser then a two-finger pan: nothing erased", f"{a['strokes']} -> {b['strokes']} strokes")
        # Rub across the word: it goes.
        st = app.state()
        x0, y0 = app.cmd({"cmd": "toPad", "points": [[min(s[0] for s in st["lastStrokes"][-5:]), min(s[1] for s in st["lastStrokes"][-5:])]]})["points"][0]
        x1, y1 = app.cmd({"cmd": "toPad", "points": [[max(s[2] for s in st["lastStrokes"][-5:]), max(s[3] for s in st["lastStrokes"][-5:])]]})["points"][0]
        rub = [[(x0 + (x1 - x0) * k / 12, y0 if k % 2 == 0 else y1) for k in range(13)]]
        fr, _ = hand.frames(rub, 5100, speed=60)
        app.touch(fr)
        c = app.state()
        rep.check(c["strokes"] < b["strokes"], "rubbing over the word erases it", f"{b['strokes']} -> {c['strokes']}")
        rep.shot(app, "after rubbing out")
        app.press("e", until=lambda s: s["tool"] == "pen")

    @scenario("scratch-out", "Write two words, scratch out the first with a quick zig-zag: it goes, the second stays, and one two-finger double tap brings it back. A zig-zag on blank paper stays ink.")
    def _():
        if not app.state()["draw"]: app.press("d", until=lambda s: s["draw"])
        app.press("n", until=lambda s: s["strokes"] == 0)   # a fresh page
        st = app.state(); pad_w, pad_h = st["padMM"]
        n0 = st["strokes"]
        fr, cid = hand.frames(hand.word("wrong", pad_w * 0.2, pad_h * 0.45, hand.roman), 9000)
        app.touch(fr); a = app.state()
        fr, cid = hand.frames(hand.word("kept", pad_w * 0.55, pad_h * 0.45, hand.roman), cid)
        app.touch(fr); b = app.state()
        word = b["lastStrokes"][-(b["strokes"] - n0):-(b["strokes"] - a["strokes"])]
        lo = app.cmd({"cmd": "toPad", "points": [[min(w[0] for w in word), min(w[1] for w in word)]]})["points"][0]
        hi = app.cmd({"cmd": "toPad", "points": [[max(w[2] for w in word), max(w[3] for w in word)]]})["points"][0]
        rep.shot(app, "two words")
        zig = [[(lo[0] + (hi[0] - lo[0]) * (k % 2), lo[1] + (hi[1] - lo[1]) * (0.25 + 0.5 * k / 6)) for k in range(7)]]
        fr, cid = hand.frames(zig, cid, speed=140)
        app.touch(fr); c = app.state()
        rep.check(c["strokes"] == b["strokes"] - (a["strokes"] - n0), "the scratched word is gone, the other word stays, no zig-zag left",
                  f"{b['strokes']} -> {c['strokes']} strokes (the word had {a['strokes'] - n0})")
        rep.check("Scratched out" in c.get("toast", ""), "a 'Scratched out' note", c.get("toast"))
        rep.shot(app, "after the scratch-out")
        app.touch(double_tap(2, pad_w / 2, pad_h / 2)); d = app.state()
        rep.check(d["strokes"] == b["strokes"], "one two-finger double tap brings the word back", f"{c['strokes']} -> {d['strokes']}")
        rep.shot(app, "after one undo")
        blank = [[(pad_w * 0.3 + 25 * (k % 2), pad_h * 0.15 + k * 0.6) for k in range(7)]]
        fr, cid = hand.frames(blank, cid, speed=140)
        app.touch(fr); e = app.state()
        rep.check(e["strokes"] == d["strokes"] + 1, "a zig-zag on blank paper stays as ink", f"{d['strokes']} -> {e['strokes']}")

    @scenario("undo-scrub", "Write five words, then two-finger double tap and keep the second tap down: sliding left steps back through them live, sliding right brings them back. A plain double tap still undoes one step.")
    def _():
        if not app.state()["draw"]: app.press("d", until=lambda s: s["draw"])
        settle(app)   # draw mode may glide back to the last word first
        st = app.state(); pad_w, pad_h = st["padMM"]
        cid, counts = 9500, [st["strokes"]]
        for i, w in enumerate(["one", "two", "six", "ten", "zen"]):
            fr, cid = hand.frames(hand.word(w, pad_w * (0.12 + 0.16 * i), pad_h * 0.3, hand.roman), cid)
            app.touch(fr); counts.append(app.state()["strokes"])
        top = counts[-1]
        cx, cy = pad_w * 0.5, pad_h * 0.55
        tap = [[0.008, [[9900, cx - 9, cy, 12, 0.5, 7.5], [9901, cx + 9, cy, 12, 0.5, 7.5]]]] * 10 + [[0.008, []]] * 18
        hold = [[0.008, [[9910, cx - 9, cy, 12, 0.5, 7.5], [9911, cx + 9, cy, 12, 0.5, 7.5]]]] * 40
        left = [[0.008, [[9910, cx - 9 - i * 0.5, cy, 12, 0.5, 7.5], [9911, cx + 9 - i * 0.5, cy, 12, 0.5, 7.5]]] for i in range(1, 80)]
        right = [[0.008, [[9910, cx - 49 + i * 0.5, cy, 12, 0.5, 7.5], [9911, cx - 31 + i * 0.5, cy, 12, 0.5, 7.5]]] for i in range(1, 30)]
        r = app.touch(tap + hold + left + right + [[0.008, []], [0.3, []]])
        f = app.state()
        trace = r.get("strokeTrace", [])
        rep.step("strokes on the page while sliding", trace=trace)
        low = min(trace) if trace else top
        rep.check(len(trace) >= 4 and low < top and trace.index(low) > 0, "sliding left steps back live (the page changes as the fingers move)", f"{trace}")
        rep.check(top > f["strokes"] > low, "sliding back right brings strokes back; what's shown on release stays", f"lowest {low}, kept {f['strokes']} of {top}")
        rep.check(f["view"] == st["view"] or abs(f["view"]["x"] - st["view"]["x"]) < 1e-6, "the page didn't pan while scrubbing")
        rep.shot(app, "after the scrub")
        app.touch(double_tap(2, cx, cy)); g = app.state()
        rep.check(g["strokes"] < f["strokes"], "a plain double tap still undoes one step", f"{f['strokes']} -> {g['strokes']}")

    @scenario("pages-overview", "New pages, the overview (G), arrow keys move the selection, Return opens; ⌘[ and ⌘] stop at the ends.")
    def _():
        if app.state()["draw"]: app.press("d", until=lambda s: not s["draw"])
        st = app.state()
        while st["pages"] < 4: app.press("n"); st = app.state()
        prev = lambda: (app.cmd({"cmd": "menu", "action": "prevPageAction"}), time.sleep(0.2), app.state())[2]
        nxt = lambda: (app.cmd({"cmd": "menu", "action": "nextPageAction"}), time.sleep(0.2), app.state())[2]
        for _ in range(st["pages"]): s = prev()
        rep.check(s["page"] == 0, "Go › Previous Page back to the first page", f"page {s['page'] + 1}")
        s2 = prev(); rep.check(s2["page"] == 0, "Previous Page on the first page does nothing (the item is disabled)")
        for _ in range(s["pages"]): s3 = nxt()
        rep.check(s3["page"] == s3["pages"] - 1, "Next Page to the last page")
        s4 = nxt(); rep.check(s4["page"] == s3["page"] and s4["pages"] == s3["pages"], "Next Page on the last page does nothing (no new page)")
        s, ms = app.press("g", until=lambda s: s["gallery"] >= 0, wait=3)
        rep.step("G opens the overview", ms=round(ms or -1))
        rep.check(s["gallery"] == s4["page"], "G: overview open, selection on the current page", f"selected {s['gallery']}, {ms and round(ms)} ms")
        time.sleep(0.6); rep.shot(app, "pages overview")
        app.press("left"); app.press("left"); s = app.state()
        rep.check(s["gallery"] == s4["page"] - 2, "← ← moves the selection two pages back", f"selected {s['gallery']}")
        s, ms = app.press("return", until=lambda s: s["gallery"] == -2, wait=3)
        time.sleep(0.5)
        s = app.state()
        rep.check(s["page"] == s4["page"] - 2, "Return opens the selected page", f"page {s['page'] + 1}, {ms and round(ms)} ms")
        rep.step("Return opens a page", ms=round(ms or -1))

    @scenario("window-shapes", "Portrait, wide and small windows: write a word in each and check the ink shows inside the window.")
    def _():
        for w, h in [(700, 900), (1500, 520), (640, 440), (1100, 760)]:
            app.cmd({"cmd": "window", "w": w, "h": h})
            if not app.state()["draw"]: app.press("d", until=lambda s: s["draw"])
            st = app.state(); pad_w, pad_h = st["padMM"]
            fr, _ = hand.frames(hand.word("shape", pad_w * 0.35, pad_h * 0.5, hand.roman), 6000 + w)
            time.sleep(3.5)   # the draw-mode banner fades
            pre = app.shot(os.path.join(rep.out, f"pre-{w}x{h}.png"))
            a = st["strokes"]; app.touch(fr); b = app.state()
            p = rep.shot(app, f"{w}x{h}")
            dink = ink_pixels(p) - ink_pixels(pre)
            rep.check(b["strokes"] > a and dink > 20, f"{w}x{h}: the word is drawn and shows in the window", f"{b['strokes'] - a} strokes, +{dink} ink pixels on screen")

    @scenario("busy-notebook", "A notebook with ~9,000 strokes: write steadily for ~8 s while autosave runs. Frames must keep coming (no stall over 50 ms).")
    def _():
        if app.state()["draw"]: app.press("d", until=lambda s: not s["draw"])
        app.cmd({"cmd": "seed", "pages": 20, "perPage": 450}, timeout=300)
        app.press("d", until=lambda s: s["draw"])
        st = app.state(); pad_w, pad_h = st["padMM"]
        app.cmd({"cmd": "mark"})
        words = SENTENCE.split()
        x, y, cid, fr = pad_w * 0.1, pad_h * 0.7, 8000, []
        for w in words:
            if x + hand.width(w) > pad_w * 0.9: x, y = pad_w * 0.1, y - hand.h * 2.4
            f, cid = hand.frames(hand.word(w, x, y), cid, speed=20)
            fr += f + [[0.008, []]] * 12
            x += hand.width(w) + hand.h
        app.touch(fr)
        s = app.state()
        m = s["mainThread"]
        rep.step("writing on a busy notebook", **m, presentedFrames=s["frames"]["count"])
        rep.check(m["ticks"] > 500 and m["over50"] == 0, "the ink never freezes while writing (main thread)",
                  f"longest stall {m['maxStallMs']:.0f} ms, {m['over50']} over 50 ms, {m['over20']} over 20 ms in {m['ticks']} ticks")
        lat = latest_latency(app.data)
        if lat: rep.step("ink latency", **lat)
        rep.shot(app, "busy notebook")

    @scenario("recorded-session", "Karthik's own touch frames (palms and all) from a recorded session, replayed through the trackpad callback; then OCR of the screen vs OCR of the same ink exported.")
    def _():
        ensure(app, "draw", False, "d"); app.press("n")   # a fresh page (not the busy notebook's)
        app.cmd({"cmd": "menu", "action": "resetZoom"}); settle(app)
        ensure(app, "draw", True, "d")
        fr, info = session_frames(os.path.join(ROOT, "data"), 45)
        if not fr: rep.check(False, "a recorded session to replay", "none found in data/"); return
        rep.step("source", **info)
        a = app.state()
        app.cmd({"cmd": "touch", "frames": fr, "settle": 1.0, "norm": True})
        b = app.state()
        rep.check(b["strokes"] - a["strokes"] >= info["commits"] * 0.9, "strokes kept like in the session",
                  f"{b['strokes'] - a['strokes']} new, the session committed {info['commits']}")
        app.cmd({"cmd": "menu", "action": "resetZoom"}); settle(app); time.sleep(2.5)   # the whole page, like the export
        p = rep.shot(app, "recorded session replayed (whole page)")
        ref = os.path.join(rep.out, "shots", "recorded-export.png")
        app.cmd({"cmd": "exportPNG", "path": ref})
        o_s, o_r = ocr(p, ""), ocr(ref, "")
        rep.step("OCR", screen=o_s.get("text", "")[:120], stored=o_r.get("text", "")[:120])
        words_s, words_r = set(o_s.get("text", "").lower().split()), set(o_r.get("text", "").lower().split())
        common = len(words_s & words_r)
        if len(words_r) >= 3:
            rep.check(common >= 0.6 * len(words_r), "the screen reads like the stored ink",
                      f"{common} of {len(words_r)} words OCR found in the export are also read off the screen")
        else:
            rep.step("OCR not applicable", why=f"the replayed part is a drawing: OCR reads {len(words_r)} words in the stored ink")

    @scenario("usage-counts", "Usage counts: using the app writes events like session_start, draw_mode, tool, undo and overview to the local log at quit, with only small allow-listed props and never what was written. Turned off in Settings, that session records nothing more.")
    def _():
        log = os.path.join(app.data, "events.jsonl")
        def events():
            out = []
            if os.path.exists(log):
                for line in open(log):
                    try: out.append(json.loads(line))
                    except ValueError: pass
            return out
        if app.state()["draw"]: app.press("d", until=lambda s: not s["draw"])
        sess = app.state().get("analyticsSession")
        app.press("d", until=lambda s: s["draw"])
        st = app.state(); pad_w, pad_h = st["padMM"]
        fr, cid = hand.frames(hand.word("secret", pad_w * 0.3, pad_h * 0.5), 10800); app.touch(fr)
        app.press("e", until=lambda s: s["tool"] == "eraser"); app.press("e", until=lambda s: s["tool"] == "pen")
        app.touch(double_tap(2, pad_w / 2, pad_h * 0.3))
        app.press("d", until=lambda s: not s["draw"])
        app.press("g", until=lambda s: s["gallery"] >= 0, wait=3); app.press("esc", until=lambda s: s["gallery"] == -2, wait=3)
        app.quit(); app.launch()
        ev = [e for e in events() if e.get("session") == sess]
        names = {e["event"] for e in ev}
        want = {"session_start", "draw_mode", "first_stroke", "tool", "undo", "strokes", "overview", "session_end"}
        rep.check(want <= names, "using the app writes the expected events to the local log", f"missing {sorted(want - names)}; {len(ev)} events")
        allowed = {"source", "tool", "on", "kind", "steps", "count", "seconds", "pages", "strokes", "zoom", "tip", "step", "key", "format", "result", "category", "minutes", "words", "page"}
        bad = [e for e in events() if not set(e.get("props", {})) <= allowed or any(len(str(v)) > 32 for v in e.get("props", {}).values())]
        raw = open(log).read() if os.path.exists(log) else ""
        rep.check(not bad and "secret" not in raw, "only small allow-listed props, and never what was written", f"{len(bad)} bad events; 'secret' in the log: {'secret' in raw}")
        rep.step("events in that session", events=sorted(names))
        # Off: nothing more from this session.
        sess2 = app.state().get("analyticsSession")
        sw = app.state().get("settingsSwitches") or []
        ai = next((i for i, x in enumerate(sw) if x[0].startswith("Share anonymous")), None)
        rep.check(ai is not None, "Settings has the usage-counts switch", str([x[0] for x in sw]))
        if ai is None: return
        app.cmd({"cmd": "settingsSwitch", "index": ai, "on": False})
        app.press("d", until=lambda s: s["draw"])
        fr, cid = hand.frames(hand.word("off", pad_w * 0.3, pad_h * 0.5), cid); app.touch(fr)
        app.press("d", until=lambda s: not s["draw"])
        app.quit(); app.launch()
        ev2 = [e["event"] for e in events() if e.get("session") == sess2]
        rep.check(not ({"draw_mode", "first_stroke", "strokes", "session_end"} & set(ev2)), "turned off: nothing after that point is written", f"events from that session: {ev2}")

    @scenario("delete-page", "Delete pages: the Delete key on the overview's highlighted tile, the tile's context menu, and Edit › Delete Page on the open page. Undo brings a deleted page back with its ink; deleting the last page leaves one blank page; the deletion survives a relaunch.")
    def _():
        ensure(app, "draw", False, "d")
        if app.state()["gallery"] >= 0: app.press("esc", until=lambda s: s["gallery"] == -2, wait=3)
        cid = 11000
        base = app.state()["pages"]
        for w in ["one", "two", "three"]:
            app.press("n"); ensure(app, "draw", True, "d")
            st = app.state(); pad_w, pad_h = st["padMM"]
            fr, cid = hand.frames(hand.word(w, pad_w * 0.3, pad_h * 0.6, hand.roman), cid); app.touch(fr)
            ensure(app, "draw", False, "d")
        s0 = app.state(); n = s0["pages"]; spp = s0["strokesPerPage"]
        two = n - 2   # the page with "two"
        app.press("g", until=lambda s: s["gallery"] >= 0, wait=3)
        while app.state()["gallery"] > two: app.press("left")
        time.sleep(0.3)
        rep.shot(app, "before: 'two' highlighted")
        app.key("delete"); time.sleep(0.6)
        s1 = app.state()
        rep.check(s1["pages"] == n - 1 and s1["strokesPerPage"] == spp[:two] + spp[two + 1:], "Delete on the highlighted tile deletes that page", f"{n} -> {s1['pages']} pages")
        rep.check(s1["gallery"] == min(two, s1["pages"] - 1), "the highlight moves to the next page", f"selected {s1['gallery']}")
        rep.check("Undo" in s1.get("toast", "") or "⌘Z" in s1.get("toast", ""), "a note says how to undo (no confirm dialog)", s1.get("toast", ""))
        rep.shot(app, "after Delete: page gone, undo note")
        app.cmd({"cmd": "menu", "action": "undo"}); time.sleep(0.5)
        s2 = app.state()
        rep.check(s2["pages"] == n and s2["strokesPerPage"] == spp, "⌘Z brings it back, ink and all, in its place", f"{s1['pages']} -> {s2['pages']} pages")
        r = app.cmd({"cmd": "tileMenu", "index": two})
        time.sleep(0.5); s3 = app.state()
        rep.check("Delete Page" in (r.get("items") or []) and s3["pages"] == n - 1, "the tile's context menu has Delete Page, and it works", f"menu {r.get('items')}, pages {s3['pages']}")
        app.cmd({"cmd": "menu", "action": "undo"}); time.sleep(0.4)
        app.press("esc", until=lambda s: s["gallery"] == -2, wait=3)
        # The open page.
        cur = app.state()["page"]
        app.cmd({"cmd": "menu", "action": "deletePageAction"}); time.sleep(0.5)
        s4 = app.state()
        rep.check(s4["pages"] == n - 1 and s4["page"] == min(cur, s4["pages"] - 1), "Edit › Delete Page deletes the open page and shows the next", f"page {cur + 1} of {n} -> page {s4['page'] + 1} of {s4['pages']}")
        rep.check(s4.get("pageArrows") == [s4["page"] > 0, s4["page"] < s4["pages"] - 1], "the page arrows dim right away", str(s4.get("pageArrows")))
        app.cmd({"cmd": "menu", "action": "undo"}); time.sleep(0.4)
        # Down to the last page: one blank page stays.
        before_all = app.state()["strokesPerPage"]
        k = len(before_all)
        for _ in range(k): app.cmd({"cmd": "menu", "action": "deletePageAction"}); time.sleep(0.15)
        s5 = app.state()
        rep.check(s5["pages"] == 1 and s5["strokes"] == 0, "deleting the last page leaves one blank page", f"{s5['pages']} page, {s5['strokes']} strokes")
        rep.shot(app, "every page deleted: one blank page")
        for _ in range(k): app.cmd({"cmd": "menu", "action": "undo"}); time.sleep(0.15)
        s6 = app.state()
        rep.check(s6["strokesPerPage"] == before_all, "undoing each delete brings the whole notebook back, in order", f"{before_all} -> {s6['strokesPerPage']}")
        # Then delete one for real and check it stays deleted after a relaunch.
        app.cmd({"cmd": "menu", "action": "deletePageAction"}); time.sleep(0.4)
        s6 = app.state()
        app.quit(); app.launch()
        s7 = app.state()
        rep.check(s7["strokesPerPage"] == s6["strokesPerPage"], "the result survives a relaunch", f"{s6['strokesPerPage']} -> {s7['strokesPerPage']}")

    @scenario("gallery-thumbs", "A notebook of 9 pages full of writing (some seeded, some handwritten in this build), reopened from disk like after a relaunch: G opens the overview at once and every thumbnail shows within about half a second, none left blank. Editing a page refreshes its thumbnail.")
    def _():
        ensure(app, "draw", False, "d")
        if app.state()["gallery"] >= 0: app.press("esc", until=lambda s: s["gallery"] == -2, wait=3)
        app.cmd({"cmd": "seed", "pages": 6, "perPage": 450}, timeout=300)
        cid = 13800
        for w in ["seven", "eight", "nine"]:
            app.press("n"); ensure(app, "draw", True, "d")
            st = app.state(); pad_w, pad_h = st["padMM"]
            for row in range(3):
                fr, cid = hand.frames(hand.word(w + " " + w, pad_w * 0.15, pad_h * (0.75 - 0.2 * row)), cid); app.touch(fr, settle=0.1)
            ensure(app, "draw", False, "d")
        app.quit(); app.launch()   # nothing cached: like opening the overview after a relaunch
        n = app.state()["pages"]
        t0 = time.time()
        app.key("g")
        seen_open, first_all, timeline = None, None, []
        while time.time() - t0 < 15:
            s = app.state()
            if s["gallery"] >= 0 and seen_open is None: seen_open = (time.time() - t0) * 1000
            th = s.get("thumbs") or []
            if th: timeline.append((round((time.time() - t0) * 1000), sum(1 for x in th if x == 0)))
            if th and all(x == 2 for x in th) and first_all is None: first_all = (time.time() - t0) * 1000; break
            time.sleep(0.03)
        open_ms = app.state().get("galleryOpenMs", 0)
        rep.step("timeline (ms, blank tiles)", points=timeline[:12] + timeline[-2:], pages=n)
        rep.check(open_ms < 250, "the overview opens at once (its own work under 250 ms)", f"{open_ms:.0f} ms of the app's work; seen open after {seen_open and round(seen_open)} ms")
        rep.check(first_all is not None and first_all - (seen_open or 0) <= 600, "every thumbnail shows within about half a second of opening",
                  f"all {n} up to date {round(first_all - (seen_open or 0)) if first_all else 'never (15 s)'} ms after the overview appeared")
        rep.shot(app, "overview right after opening, 9 full pages")
        # The worst case: nothing rendered yet when the overview opens (G right after launch).
        app.press("esc", until=lambda s: s["gallery"] == -2, wait=3)
        app.cmd({"cmd": "dropThumbnails"})
        t2 = time.time(); app.key("g"); opened = None; done_ms = None
        while time.time() - t2 < 15:
            s = app.state()
            if s["gallery"] >= 0 and opened is None: opened = time.time()
            th = s.get("thumbs") or []
            if th and all(x == 2 for x in th): done_ms = (time.time() - (opened or t2)) * 1000; break
            time.sleep(0.03)
        rep.check(done_ms is not None and done_ms <= 600, "with nothing cached, every thumbnail still renders within about half a second of opening",
                  f"all {n} in {round(done_ms) if done_ms is not None else 'never'} ms")
        # Edit a page: its thumbnail refreshes.
        app.press("esc", until=lambda s: s["gallery"] == -2, wait=3)
        ensure(app, "draw", True, "d")
        st = app.state(); pad_w, pad_h = st["padMM"]
        fr, cid = hand.frames(hand.word("new", pad_w * 0.6, pad_h * 0.2, hand.roman), cid); app.touch(fr)
        ensure(app, "draw", False, "d")
        app.key("g"); t1 = time.time(); ok = False
        while time.time() - t1 < 3:
            th = app.state().get("thumbs") or []
            if th and th[app.state()["page"]] == 2: ok = True; break
            time.sleep(0.03)
        rep.check(ok, "after editing a page its thumbnail is up to date when the overview opens", f"{round((time.time() - t1) * 1000)} ms")
        app.press("esc", until=lambda s: s["gallery"] == -2, wait=3)

    @scenario("click-to-draw", "Click to draw (Settings): a touch only aims (the blue aim mark). A click turns drawing on and starts the stroke where the finger is; let go of the click and keep drawing; lift and touch again to draw more strokes, no more clicks. 3 s (2-5 s in Settings) after the last lift with no writing it turns off and a touch only aims again; while writing it never does. A light finger the sensor briefly reports as lifting doesn't break the stroke. Two- and three-finger gestures never draw; the eraser works the same way.")
    def _():
        ensure(app, "draw", False, "d")
        if app.state()["gallery"] >= 0: app.press("esc", until=lambda s: s["gallery"] == -2, wait=3)
        app.press("n"); ensure(app, "writing", False, "w")
        app.cmd({"cmd": "menu", "action": "showSettings"}); time.sleep(0.4)
        sw = app.state().get("settingsSwitches") or []
        ci = next((i for i, x in enumerate(sw) if x[0].lower().startswith("click to draw")), None)
        rep.check(ci is not None, "Settings has a Click to draw switch (off by default)", str([x[0] for x in sw]))
        if ci is None: app.cmd({"cmd": "closeSettings"}); return
        rep.check(not sw[ci][1], "the switch starts off", str(sw[ci]))
        app.cmd({"cmd": "settingsSwitch", "index": ci, "on": True}); app.cmd({"cmd": "closeSettings"})
        ensure(app, "draw", True, "d")
        st = app.state(); pad_w, pad_h = st["padMM"]; n0 = st["strokes"]
        rep.check(st["draw"], "in draw mode", "")
        cid = 16000
        def line(y, click_at=None, n=60, x0=0.25, flicker_at=None, dt=0.008):
            """One finger sliding right; a trackpad click (down and straight up) at frame `click_at`; with
            `flicker_at`, the sensor reports the light finger as lifting (5, then 6 for 40 ms) and touching
            again (3, 4), as Karthik's trackpad did. Returns the pad points."""
            nonlocal cid
            cid += 1
            pts = [(pad_w * x0 + i * 0.35, pad_h * y) for i in range(n)]
            fr = [[dt, [[cid, x, yy, 40, 0.5, 7.5, 4]]] for x, yy in pts]
            if flicker_at is not None:
                for k, s_ in zip(range(flicker_at, flicker_at + 7), [5, 6, 6, 6, 6, 3, 4]):
                    fr[k][1][0][6] = s_; fr[k][1][0][3] = 3
            if click_at is not None:   # a real click: the finger presses firmly (the sensor reads 100-150) as it clicks
                for k in range(max(0, click_at - 4), click_at + 1): fr[k][1][0][3] = 130
                fr[click_at] = fr[click_at] + ["click"]
            app.touch(fr + [[0.008, [[cid, *pts[-1], 0, 0.5, 7.5, 5]]], [0.008, [[cid, *pts[-1], 0, 0.5, 7.5, 7]]], [0.008, []], [0.1, []]], settle=0.1)
            return pts
        line(0.7)
        a = app.state(); cap = (a.get("chrome") or {}).get("capsule", "")
        rep.check(a["strokes"] == n0 and not a.get("clickDrawOn"), "before a click a touch only aims: nothing is drawn", f"{a['strokes'] - n0} strokes")
        rep.check("arm" not in cap.lower(), "no extra label in the capsule", cap)
        rep.check(a.get("aimRing") == [0.10, 0.45, 0.91, 0.8], "the aim mark is the blue one from before", str(a.get("aimRing")))
        # (a) Click, release the click, keep moving, lift: one stroke from the click point to the lift.
        pts = line(0.6, click_at=12)
        b = app.state()
        rep.check(b["strokes"] == n0 + 1, "the click starts one stroke", f"{b['strokes'] - n0} strokes")
        ends = b.get("lastStrokeEnds") or []
        exp = app.cmd({"cmd": "toPage", "points": [list(pts[12]), list(pts[-1])]})["points"]
        if len(ends) == 2:
            span = math.dist(exp[0], exp[1])
            rep.check(math.dist(ends[0], exp[0]) < span * 0.08, "the stroke starts where the finger was at the click", f"{math.dist(ends[0], exp[0]):.1f} from the click point, span {span:.0f}")
            rep.check(math.dist(ends[1], exp[1]) < span * 0.08, "with the click released, the stroke follows the finger to where it lifts", f"{math.dist(ends[1], exp[1]):.1f} from the lift point")
        else: rep.check(False, "the stroke follows the finger from the click to the lift", str(ends))
        rep.check(b.get("clickDrawOn"), "drawing stays on after the lift", str(b.get("clickDrawOn")))
        # Touch again within 3 s: a second stroke, no click.
        time.sleep(1.0); line(0.5)
        c = app.state()
        rep.check(c["strokes"] == b["strokes"] + 1, "(a) lift and touch again within 3 s: a second stroke with no click", f"{c['strokes'] - b['strokes']} strokes")
        rep.shot(app, "click to draw: the first line started by a click, the second with no click")
        # (c) Writing on for more than 3 s, pauses under 3 s, never turns it off; nor does one long stroke.
        t0 = time.time()
        for k in range(4): time.sleep(0.9); line(0.45 - 0.03 * k, n=25)
        line(0.3, n=500)   # a 4 s stroke
        d = app.state()
        rep.check(d["strokes"] == c["strokes"] + 5 and d.get("clickDrawOn"), "(c) writing on for more than 3 s never turns it off (pauses under 3 s, and a 4 s stroke)", f"{d['strokes'] - c['strokes']} of 5 strokes in {time.time() - t0:.1f} s, on {d.get('clickDrawOn')}")
        # The sensor's brief 'lifting' report for a light finger doesn't break the stroke.
        line(0.25, flicker_at=25)
        e = app.state()
        rep.check(e["strokes"] == d["strokes"] + 1, "a light finger reported as lifting for 40 ms stays one stroke", f"{e['strokes'] - d['strokes']} strokes")
        # (b) More than 3 s without writing: off; a touch only aims.
        time.sleep(3.4)
        f = app.state()
        rep.check(not f.get("clickDrawOn"), "(b) 3 s after the last lift it turns off", str(f.get("clickDrawOn")))
        line(0.2)
        g = app.state()
        rep.check(g["strokes"] == e["strokes"], "(b) then a touch draws nothing until the next click", f"{g['strokes'] - e['strokes']} strokes")
        # Gestures never draw: a two-finger double tap undoes, a pan (even with a click) draws nothing, three fingers redo.
        line(0.15, click_at=0, n=10)
        g0 = app.state()
        app.touch(double_tap(2, pad_w / 2, pad_h * 0.3)); g1 = app.state()
        pan = two_finger(pad_w / 2, pad_h * 0.4, 25, 25, shift=(-10, 0), dur=0.4); pan[5] = pan[5] + ["click"]
        app.touch(pan); g2 = app.state()
        rep.check(g1["strokes"] == g0["strokes"] - 1 and g2["strokes"] == g1["strokes"], "a two-finger double tap undoes; a pan draws nothing, even with a click", f"{g0['strokes']} -> {g1['strokes']} -> {g2['strokes']}")
        app.touch(double_tap(3, pad_w / 2, pad_h * 0.3)); g3 = app.state()
        rep.check(g3["strokes"] == g0["strokes"], "a three-finger double tap redoes, no ink", f"{g2['strokes']} -> {g3['strokes']}")
        # The eraser: off, rubbing erases nothing; a click and rub erases, and so does the next rub with no click.
        app.press("e", until=lambda s: s["tool"] == "eraser"); time.sleep(3.4)
        def rub(click):
            nonlocal cid
            ink = app.state()["lastStrokeMid"]; (ex, ey), = app.cmd({"cmd": "toPad", "points": [ink]})["points"]
            cid += 1
            fr = [[0.008, [[cid, ex - 6 + 12 * (k % 2) * (j / 4), ey - 2 + k * 0.5, 40, 0.5, 7.5]]] for k in range(9) for j in range(4)]
            if click: fr[0][1][0][3] = 130; fr[0] = fr[0] + ["click"]
            app.touch(fr + [[0.008, []], [0.2, []]])
        e0 = app.state(); rub(False); e1 = app.state()
        rep.check(e1["strokes"] == e0["strokes"], "eraser, off: rubbing erases nothing", f"{e0['strokes']} -> {e1['strokes']}")
        rub(True); e2 = app.state()
        rep.check(e2["strokes"] < e1["strokes"], "eraser: a click and rub erases", f"{e1['strokes']} -> {e2['strokes']}")
        rub(False); e3 = app.state()
        rep.check(e3["strokes"] < e2["strokes"], "eraser: the next rub within 3 s erases with no click", f"{e2['strokes']} -> {e3['strokes']}")
        app.press("p", until=lambda s: s["tool"] == "pen")
        # The time is a setting (2-5 s): at 2 s it turns off after 2 s.
        app.cmd({"cmd": "clickDrawTimeout", "seconds": 2})
        line(0.1, click_at=0, n=10); time.sleep(1.5)
        on15 = app.state().get("clickDrawOn"); time.sleep(0.8)
        rep.check(on15 and not app.state().get("clickDrawOn"), "with the setting at 2 s it turns off 2 s after the lift", f"on at 1.5 s {on15}")
        app.cmd({"cmd": "clickDrawTimeout", "seconds": 3})
        # Off again: a touch draws as usual.
        app.cmd({"cmd": "menu", "action": "showSettings"}); time.sleep(0.3)
        app.cmd({"cmd": "settingsSwitch", "index": ci, "on": False}); app.cmd({"cmd": "closeSettings"})
        ensure(app, "draw", True, "d")
        h0 = app.state(); line(0.3); h1 = app.state()
        rep.check(h1["strokes"] == h0["strokes"] + 1, "with the switch off, a touch draws as before", f"{h1['strokes'] - h0['strokes']} strokes")
        ensure(app, "draw", False, "d")

    @scenario("click-to-draw-aim", "Click to draw, aiming and arming: taps (macOS tap-to-click sends a click as the finger lifts) never turn drawing on, only a firm press does; the blue aim mark moves like a cursor, carrying on from where it stopped after a lift, and the ink starts exactly at it; with the time set to 0 s every lift turns drawing off.")
    def _():
        ensure(app, "draw", False, "d")
        if app.state()["gallery"] >= 0: app.press("esc", until=lambda s: s["gallery"] == -2, wait=3)
        app.press("n"); ensure(app, "writing", False, "w")
        app.cmd({"cmd": "menu", "action": "showSettings"}); time.sleep(0.4)
        sw = app.state().get("settingsSwitches") or []
        ci = next((i for i, x in enumerate(sw) if x[0].lower().startswith("click to draw")), None)
        if ci is None: rep.check(False, "Settings has a Click to draw switch"); app.cmd({"cmd": "closeSettings"}); return
        app.cmd({"cmd": "settingsSwitch", "index": ci, "on": True}); app.cmd({"cmd": "closeSettings"})
        ensure(app, "draw", True, "d")
        st = app.state(); pad_w, pad_h = st["padMM"]; n0 = st["strokes"]
        cid = 17000
        def slide(x0, y0, x1, y1, n=30, p=30, click_at=None, lift=True):
            nonlocal cid
            cid += 1
            pts = [(x0 + (x1 - x0) * i / (n - 1), y0 + (y1 - y0) * i / (n - 1)) for i in range(n)]
            fr = [[0.008, [[cid, x, y, p, 0.5, 7.5, 4]]] for x, y in pts]
            if click_at is not None:
                for k in range(max(0, click_at - 4), click_at + 1): fr[k][1][0][3] = 130
                fr[click_at] = fr[click_at] + ["click"]
            app.touch(fr + ([[0.008, [[cid, *pts[-1], 0, 0.5, 7.5, 7]]], [0.008, []], [0.1, []]] if lift else []), settle=0.1)
            return pts
        # 1) Rapid taps: light touches; tap-to-click's click comes as the finger lifts (and sometimes while it's still light on the pad).
        for k in range(6):
            cid += 1
            x, y = pad_w * (0.3 + 0.05 * k), pad_h * 0.5
            fr = [[0.008, [[cid, x, y, 25 + 5 * (k % 3), 0.5, 7.5, 4]]] for _ in range(7)]
            if k % 2: fr[5] = fr[5] + ["click"]   # the click while the light finger is still down
            fr += [[0.008, [[cid, x, y, 0, 0.5, 7.5, 7]]], [0.008, []] + ([] if k % 2 else ["click"]), [0.05, []]]
            app.touch(fr, settle=0.05)
        slide(pad_w * 0.3, pad_h * 0.4, pad_w * 0.6, pad_h * 0.4)
        a = app.state()
        rep.check(a["strokes"] == n0 and not a.get("clickDrawOn"), "1) rapid taps (tap-to-click clicks) never start drawing; the next touch only aims", f"{a['strokes'] - n0} strokes, on {a.get('clickDrawOn')}")
        # 1b) Hard quick taps all across the pad (Karthik, 27 Oct): a fast tap can press 90-155 on the sensor, and
        # tap-to-click sends its click as the finger lifts - sometimes a few ms before the lift reaches the app.
        for k in range(12):
            cid += 1
            x, y = pad_w * (0.12 + 0.07 * k), pad_h * (0.25 + 0.5 * ((k * 7) % 5) / 4)
            fr = [[0.008, [[cid, x, y, p_, 0.5, 7.5, 4]]] for p_ in (40, 95, 135, 120, 70)]
            if k % 2: fr[-1] = fr[-1] + ["click"]   # the click before the lift arrives
            fr += [[0.008, [[cid, x, y, 0, 0.5, 7.5, 7]]], [0.008, []] + ([] if k % 2 else ["click"]), [0.04, []]]
            app.touch(fr, settle=0.02)
        time.sleep(0.3)
        b1 = app.state()
        rep.check(b1["strokes"] == n0 and not b1.get("clickDrawOn"), "1b) rapid hard taps across the pad (tap-to-click, no press) put down no ink and don't turn drawing on", f"{b1['strokes'] - n0} strokes, on {b1.get('clickDrawOn')}")
        slide(pad_w * 0.3, pad_h * 0.35, pad_w * 0.6, pad_h * 0.35)
        b2 = app.state()
        rep.check(b2["strokes"] == n0, "1b) and the next touch only aims", f"{b2['strokes'] - n0} strokes")
        # 2) Aiming as with the old pan-and-place: the mark starts where the finger lands (left or right of the pad)
        # and follows it like a cursor while it stays down; the click's ink starts exactly at the mark.
        tol = st["pageW"] * 0.01
        def page(x, y): return app.cmd({"cmd": "toPage", "points": [[x, y]]})["points"][0]
        def near(a_, b_): return bool(a_) and bool(b_) and math.dist(a_, b_) < tol
        def down(x, y, p=30, extra=None):
            fr = [[0.008, [[cid, x, y, p, 0.5, 7.5, 4]]]]
            if extra: fr[0] = fr[0] + extra
            app.touch(fr, settle=0.08)
        def move(x0_, y0_, x1, y1, n=20, p=30):
            app.touch([[0.008, [[cid, x0_ + (x1 - x0_) * i / n, y0_ + (y1 - y0_) * i / n, p, 0.5, 7.5, 4]]] for i in range(1, n + 1)], settle=0.08)
        def lift(x, y): app.touch([[0.008, [[cid, x, y, 0, 0.5, 7.5, 7]]], [0.008, []], [0.1, []]], settle=0.1)
        cid += 1; down(pad_w * 0.2, pad_h * 0.5); move(pad_w * 0.2, pad_h * 0.5, pad_w * 0.3, pad_h * 0.5)
        m1 = app.state().get("aimMark")
        rep.check(near(m1, page(pad_w * 0.3, pad_h * 0.5)), "2) on the left of the pad the mark is under the finger", f"mark {m1}, finger {page(pad_w * 0.3, pad_h * 0.5)}")
        lift(pad_w * 0.3, pad_h * 0.5)
        gone = app.state().get("aimMark")
        rep.check(gone is None, "2) when the finger lifts the mark goes away", str(gone))
        cid += 1; x0, y0 = pad_w * 0.75, pad_h * 0.3; down(x0, y0)
        m2 = app.state().get("aimMark")
        rep.check(near(m2, page(x0, y0)), "2) touch down on the right: the mark starts there (it doesn't carry on from the left)", f"mark {m2}, finger {page(x0, y0)}")
        move(x0, y0, x0 + pad_w * 0.05, y0 + pad_h * 0.05)
        x1, y1 = x0 + pad_w * 0.05, y0 + pad_h * 0.05
        m3 = app.state().get("aimMark")
        rep.check(near(m3, page(x1, y1)), "2) while the finger stays down the mark follows it", f"mark {m3}, finger {page(x1, y1)}")
        # Press and click right there, let go of the click and keep drawing, lift.
        app.touch([[0.008, [[cid, x1, y1, 130, 0.5, 7.5, 4]]] for _ in range(3)] + [[0.008, [[cid, x1, y1, 130, 0.5, 7.5, 4]], "click"]], settle=0.05)
        move(x1, y1, x1 - pad_w * 0.1, y1, n=30); lift(x1 - pad_w * 0.1, y1)
        c = app.state(); ends = c.get("lastStrokeEnds") or []
        rep.check(c["strokes"] == n0 + 1 and len(ends) == 2 and near(ends[0], m3), "2) a click starts the ink exactly at the mark", f"{c['strokes'] - n0} strokes; ink starts {ends[:1]}, mark {m3}")
        rep.check(len(ends) == 2 and near(ends[1], page(x1 - pad_w * 0.1, y1)), "2) the ink follows the finger to where it lifts", f"{ends[1:]} vs {page(x1 - pad_w * 0.1, y1)}")
        rep.shot(app, "click to draw: the mark starts where the finger lands; the ink starts at the mark")
        # The next stroke (drawing still on, no click) starts under its finger too.
        cid += 1; down(pad_w * 0.4, pad_h * 0.6); move(pad_w * 0.4, pad_h * 0.6, pad_w * 0.5, pad_h * 0.6); lift(pad_w * 0.5, pad_h * 0.6)
        d = app.state(); e2 = d.get("lastStrokeEnds") or []
        rep.check(d["strokes"] == n0 + 2 and e2 and near(e2[0], page(pad_w * 0.4, pad_h * 0.6)), "2) the next stroke, no click, starts under its finger", f"{e2[:1]} vs {page(pad_w * 0.4, pad_h * 0.6)}")
        # 3) The time can be 0 s: every lift turns drawing off, so each stroke needs its own click.
        app.cmd({"cmd": "menu", "action": "showSettings"}); time.sleep(0.3)
        rng = app.state().get("clickDrawRange")
        app.cmd({"cmd": "closeSettings"}); ensure(app, "draw", True, "d")
        rep.check(rng == [0, 5], "3) the Settings slider goes from 0 to 5 s", str(rng))
        app.cmd({"cmd": "clickDrawTimeout", "seconds": 0})
        time.sleep(3.2)
        e0 = app.state()["strokes"]
        slide(pad_w * 0.3, pad_h * 0.3, pad_w * 0.5, pad_h * 0.3, click_at=3)
        e1 = app.state()
        rep.check(e1["strokes"] == e0 + 1 and not e1.get("clickDrawOn"), "3) at 0 s: the click draws one stroke and the lift turns drawing off", f"{e1['strokes'] - e0} strokes, on {e1.get('clickDrawOn')}")
        time.sleep(0.15); slide(pad_w * 0.3, pad_h * 0.25, pad_w * 0.5, pad_h * 0.25)
        e2_ = app.state()
        rep.check(e2_["strokes"] == e1["strokes"], "3) at 0 s: the next touch, right after, only aims", f"{e2_['strokes'] - e1['strokes']} strokes")
        app.cmd({"cmd": "clickDrawTimeout", "seconds": 3})
        slide(pad_w * 0.3, pad_h * 0.2, pad_w * 0.5, pad_h * 0.2, click_at=3); time.sleep(1.0)
        f0 = app.state()["strokes"]; slide(pad_w * 0.3, pad_h * 0.15, pad_w * 0.5, pad_h * 0.15); f1 = app.state()
        rep.check(f1["strokes"] == f0 + 1, "3) at 3 s: a touch 1 s after the lift still draws", f"{f1['strokes'] - f0} strokes")
        app.cmd({"cmd": "menu", "action": "showSettings"}); time.sleep(0.3)
        app.cmd({"cmd": "settingsSwitch", "index": ci, "on": False}); app.cmd({"cmd": "closeSettings"})
        ensure(app, "draw", False, "d")

    @scenario("click-to-draw-pan", "Panning is the same with click to draw on as off: the same two-finger pan, a pan into the page's edge, a pinch and an arrow-key pan move the view exactly the same, before a click and while drawing is on.")
    def _():
        def switch(on):
            app.cmd({"cmd": "menu", "action": "showSettings"}); time.sleep(0.3)
            sw = app.state().get("settingsSwitches") or []
            i = next((k for k, x in enumerate(sw) if x[0].lower().startswith("click to draw")), None)
            if i is not None: app.cmd({"cmd": "settingsSwitch", "index": i, "on": on})
            app.cmd({"cmd": "closeSettings"}); return i is not None
        def run(mode):
            ensure(app, "draw", False, "d")
            if app.state()["gallery"] >= 0: app.press("esc", until=lambda s: s["gallery"] == -2, wait=3)
            app.press("n")   # an empty page: nothing for draw mode to resume to, so every run starts from the same view
            ok = switch(mode != "off")
            ensure(app, "draw", True, "d"); ensure(app, "writing", False, "w"); settle(app, limit=3)
            app.cmd({"cmd": "menu", "action": "resetZoom"}); settle(app, limit=3)
            app.cmd({"cmd": "zoomMenu", "pick": "300%"}); settle(app, limit=3)
            st = app.state(); pw, ph = st["padMM"]
            if mode == "armed":   # a click turns drawing on (a short stroke); the pans come while it's on
                fr = [[0.008, [[18001, pw * 0.5, ph * 0.9, 130, 0.5, 7.5]]] for _ in range(4)]
                fr[3] = fr[3] + ["click"]
                app.touch(fr + [[0.008, [[18001, pw * 0.5 + i * 0.3, ph * 0.9, 30, 0.5, 7.5]]] for i in range(10)] + [[0.008, []], [0.1, []]], settle=0.1)
                settle(app)
            out = {"on": app.state().get("clickDrawOn"), "ok": ok}
            v = lambda: app.state()["view"]
            v0 = v(); out["start"] = [round(v0["x"], 1), round(v0["y"], 1), round(v0["zoom"], 3)]
            app.touch(two_finger(pw / 2, ph / 2, 25, 25, shift=(-12, -6), dur=0.4)); settle(app); v1 = v()
            for _ in range(2): app.touch(two_finger(pw * 0.7, ph / 2, 25, 25, shift=(-70, 0), dur=0.5)); settle(app)
            v2 = v(); out["pageW"] = app.state()["pageW"]
            app.touch(two_finger(pw / 2, ph / 2, 20, 34, dur=0.4)); settle(app); v3 = v()
            app.press("right"); settle(app); v4 = v()
            out["moves"] = [[round(b["x"] - a["x"], 2), round(b["y"] - a["y"], 2), round(b["zoom"] / a["zoom"], 4)] for a, b in [(v0, v1), (v1, v2), (v2, v3), (v3, v4)]]
            out["edgeX"] = round(v2["x"] + v2["w"], 2)
            return out
        off = run("off"); on = run("on"); armed = run("armed")
        switch(False); ensure(app, "draw", False, "d")
        rep.check(on["ok"] and bool(armed["on"]), "click to draw switched on for the comparison", f"{on['ok']}, drawing on during the armed run: {armed['on']}")
        moved = all(abs(m[0]) + abs(m[1]) > 1 or abs(m[2] - 1) > 0.01 for m in off["moves"])
        rep.check(off["start"] == on["start"] == armed["start"], "the three runs start from the same view", f"{off['start']}, {on['start']}, {armed['start']}")
        rep.check(moved, "each move (pan, pan into the edge, pinch, arrow) moves the view with click to draw off", str(off["moves"]))
        rep.check(abs(off["edgeX"] - off["pageW"]) < 0.5 and on["edgeX"] == off["edgeX"] and armed["edgeX"] == off["edgeX"], "the pan into the edge stops at the page's right edge, on and off", f"view right edge {off['edgeX']}, {on['edgeX']}, {armed['edgeX']} (page {off['pageW']})")
        def same(a_, b_): return all(abs(x - y) <= 0.5 for m, n in zip(a_["moves"], b_["moves"]) for x, y in zip(m[:2], n[:2])) and all(abs(m[2] - n[2]) < 1e-3 for m, n in zip(a_["moves"], b_["moves"]))
        rep.check(same(off, on), "before a click, the pans, the edge, the pinch and the arrow move the view exactly as with click to draw off", f"off {off['moves']}  on {on['moves']}")
        rep.check(same(off, armed) and armed["on"], "while drawing is on, they still move the view exactly as with it off", f"off {off['moves']}  armed {armed['moves']}")

    @scenario("crash-no-dialog", "An unexpected crash during a robot run (a bug in the app or the hook) is reported as a failure here and never puts a 'quit unexpectedly' dialog on the screen of the person using the Mac.")
    def _():
        reports = os.path.expanduser("~/Library/Logs/DiagnosticReports")
        before, pid = set(glob.glob(reports + "/TrackpadDraw-*.ips")), app.pid
        crashed = False
        try: app.cmd({"cmd": "trap"}, timeout=10)
        except RuntimeError as e: crashed = "exited" in str(e)
        rep.check(crashed, "the robot sees the app crash", f"exit {app.proc.poll()}")
        # macOS writes the report (and shows the dialog) up to ~30 s after the crash: watch 40 s, closing any dialog at once.
        dialogs, ours, t0 = set(getattr(app, "dialogs", [])), [], time.time()
        while time.time() - t0 < 40 and not ours:
            dialogs |= set(close_crash_dialogs())
            for f in set(glob.glob(reports + "/TrackpadDraw-*.ips")) - before:
                try: body = json.loads(open(f).read().split("\n", 1)[1])
                except Exception: continue
                if body.get("pid") == pid: ours.append(f)
        rep.check(not dialogs, "no crash dialog appeared", f"dialogs closed: {sorted(dialogs)}")
        rep.check(not ours, "no crash report written", ", ".join(os.path.basename(f) for f in ours))
        for f in ours: os.remove(f)   # ours, from this test
        app.launch()

    @scenario("quit-relaunch", "Quit, start again: every page and stroke is back, on the same page.")
    def _():
        a = app.state()
        rep.shot(app, "before quitting")
        app.quit()
        app.launch()
        b = app.state()
        rep.check(b["strokesPerPage"] == a["strokesPerPage"], "every page's strokes back after relaunch",
                  f"{sum(a['strokesPerPage'])} strokes on {a['pages']} pages -> {sum(b['strokesPerPage'])} on {b['pages']}")
        rep.check(b["page"] == a["page"], "same page open", f"{a['page'] + 1} -> {b['page'] + 1}")
        rep.shot(app, "after relaunch")

    names = list(S)
    if only: names = [n for n in names if any(n == o or n.startswith(o) for o in only)]
    return S, names


def flow_metrics(recs):
    """What the writer can see after each page move: words of the line still on screen after a pan, the size
    of the jump, and whether the line just finished is still in view after a new line."""
    pans, lines = [], []
    for i, r in enumerate(recs):
        b, a = r["before"], r["view"]
        if r["newLine"]:
            # Lines written so far (split where the page went to a new line), and how many are still in view.
            groups, g = [], []
            for x in recs[:i + 1]:
                if x["bounds"]: g.append(x["bounds"])
                if x["newLine"]: groups.append(g); g = []
            visible = sum(1 for gr in groups if any(pb[1] >= a["y"] - 1e-6 and pb[3] <= a["y"] + a["h"] + 1e-6 for pb in gr))
            lines.append({"prevLineVisible": visible > 0, "linesVisible": visible, "linesWritten": len(groups)})
        elif a["x"] > b["x"] + 1e-6:
            words = 0
            for x in reversed(recs[:i + 1]):
                bb = x["bounds"]
                if bb is None or x["newLine"] and x is not r: break
                if bb[0] >= a["x"] - 1e-6 and bb[2] <= a["x"] + a["w"] + 1e-6: words += 1
                else: break
            pans.append({"wordsVisible": words, "jump": (a["x"] - b["x"]) / b["w"]})
    return pans, lines


def judge_writing(app, rep, recs, st, text, ocr_check=True):
    mid = [r["word"] for r in recs if r["midWordMove"]]
    rep.check(not mid, "the page never moved inside a word", f"moved inside: {mid}" if mid else f"{len(recs)} words")
    seen = [r["word"] for r in recs if r.get("mapSeen") and not r.get("handMoved")]
    if any(r["newLine"] or r["view"] != r["before"] for r in recs):
        rep.check(not seen, "the page map stays hidden while writing (auto-pans and new lines don't show it)", f"shown while writing: {seen}" if seen else f"{len(recs)} words")
    pans, lines = flow_metrics(recs)
    rep.step("page moves", pans=[(p["wordsVisible"], round(p["jump"], 2)) for p in pans], newLines=len(lines))
    rep.check(not pans, "no sideways pan along the line (only the next-line move)", f"{len(pans)} sideways pans, jumps {[round(p['jump'], 2) for p in pans]}")
    if lines:
        seen = sum(l["prevLineVisible"] for l in lines)
        rep.check(seen == len(lines), "after a new line the line just written is still in view", f"{seen} of {len(lines)} new lines")
        two = [l for l in lines if l["linesWritten"] >= 2]
        if two:
            ok2 = sum(l["linesVisible"] >= 2 for l in two)
            rep.check(ok2 == len(two), "with two lines written, both are still in view after the next new line", f"{ok2} of {len(two)} new lines (lines in view: {[l['linesVisible'] for l in two]})")
    lines = sum(r["newLine"] for r in recs)
    rep.step("words", n=len(recs), newLines=lines, strokes=st["strokes"])
    p = rep.shot(app, "after writing")
    if ocr_check:
        exp = os.path.join(rep.out, "shots", f"{rep.cur['name']}-export.png")
        if "error" in app.cmd({"cmd": "exportPNG", "path": exp}):
            rep.step("OCR skipped", why="this build has no export"); app.press("d", until=lambda s: not s["draw"]); return
        o = ocr(exp, text)
        rep.check(o.get("accuracy", 0) >= 0.5, "the page reads back (OCR of the exported page)", f"{o.get('accuracy', 0):.0%}: {o.get('text', '')[:80]!r}")
    app.press("d", until=lambda s: not s["draw"])


def latest_latency(data):
    files = sorted(glob.glob(os.path.join(data, "strokes-*.jsonl")))
    if not files: return None
    lat = []
    for line in open(files[-1]):
        try: d = json.loads(line)
        except ValueError: continue
        lat += d.get("latencyMs", [])
    lat = sorted(x for x in lat if x > 0)
    if not lat: return None
    return {"inkLatencyMedianMs": round(lat[len(lat) // 2], 1), "inkLatencyP95Ms": round(lat[int(len(lat) * 0.95)], 1), "samples": len(lat)}


def session_frames(data, secs):
    """The busiest `secs` seconds of drawing in the longest recorded session: its raw touch frames (0...1
    pad positions, every contact including palms and thumbs), with the recorded timing."""
    files = sorted(glob.glob(os.path.join(data, "session-2*.jsonl")), key=os.path.getsize)
    if not files: return [], {}
    rows = []
    for line in open(files[-1]):
        try: rows.append(json.loads(line))
        except ValueError: pass
    commits = [r["m"] for r in rows if r.get("k") == "act" and r.get("a") == "commit"]
    if not commits: return [], {}
    best, start, j = 0, commits[0], 0
    for i, m in enumerate(commits):
        while commits[j] < m - secs: j += 1
        if i - j > best: best, start = i - j, commits[j]
    t0 = start - 1.0
    fr, prev = [], None
    for r in rows:
        if r.get("k") != "touch" or not (t0 <= r["m"] <= t0 + secs): continue
        dt = 0.008 if prev is None else max(0.004, min(r["m"] - prev, 0.05))
        prev = r["m"]
        fr.append([dt, [[c[0] + 20000, c[2], c[3], c[4] or 10, 0.5, 7.5] for c in r["c"] if c[1] in (3, 4)]])
    fr.append([0.008, []])
    n_commit = sum(1 for m in commits if t0 <= m <= t0 + secs)
    return fr, {"session": os.path.basename(files[-1]), "from_s": round(t0 - rows[0]["m"], 1), "secs": secs, "frames": len(fr), "commits": n_commit}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--app", default=os.path.join(ROOT, "build/Scrawl.app/Contents/MacOS/TrackpadDraw"))
    ap.add_argument("--out", default=os.path.join(ROOT, "build/robot"))
    ap.add_argument("--only", default="")
    ap.add_argument("--label", default="main")
    ap.add_argument("--list", action="store_true")
    a = ap.parse_args()
    out = a.out
    shutil.rmtree(out, ignore_errors=True)
    os.makedirs(os.path.join(out, "shots"))
    tool = os.path.join(ROOT, "build/robot-input")
    app = App(a.app, out, os.path.join(out, "data"), tool, "app")
    rep = Report(out)
    hand = Hand(seed=7)
    S, names = run_scenarios(app, rep, [o for o in a.only.split(",") if o], hand)
    if a.list:
        for n in S: print(n, "-", S[n][0])
        return 0
    t0 = time.time()
    commit = subprocess.run(["git", "-C", ROOT, "rev-parse", "--short", "HEAD"], capture_output=True, text=True).stdout.strip()
    app.launch()
    try:
        for n in names:
            about, f = S[n]
            print(f"== {n}", flush=True)
            rep.begin(n, about)
            try: f()
            except Exception as e:  # a scenario that crashes the app or times out fails, the rest still run
                rep.cur["error"] = f"{type(e).__name__}: {e}"
                print("  ERROR", rep.cur["error"], flush=True)
                if app.proc.poll() is not None: app.launch()
            rep.end()
    finally:
        app.kill()
    ok, n = rep.write({"label": a.label, "commit": commit, "when": time.strftime("%Y-%m-%d %H:%M"), "secs": round(time.time() - t0),
                       "note": "Touches go in through the trackpad callback, keys as CGEvents to the app, clicks through AppKit. Not covered: the sensor and driver, macOS gestures that take touches before the app, full screen (it would take over the screen), and how it feels."})
    errors = sum(1 for s in rep.scenarios if s["error"])
    print(f"RESULT: {'PASS' if ok == n and not errors else 'FAIL'} {ok}/{n} checks, {errors} scenario errors  report: {os.path.join(out, 'report.html')}")
    return 0 if ok == n and not errors else 1


if __name__ == "__main__":
    sys.exit(main())
