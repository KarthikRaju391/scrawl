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
            if self.proc.poll() is not None: raise RuntimeError(f"app exited during {c.get('cmd')}")
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


def write_words(app, hand, words, line_y, x0, cid, rep, font=None):
    """Write `words` like a person in writing mode. Each word goes just after the last word, where that is
    on the screen now (the page may have moved); when the page has gone to a new line, the next word starts
    that line, below the line's first word. With no room left on the pad and no page move (No pan), the
    person pans with two fingers. Returns one record per word."""
    pad_w, pad_h = app.state()["padMM"]
    line = None   # this line in page units: left x, baseline y, ink height
    recs = []
    for w in words:
        settle(app)
        st = app.state()
        width = hand.width(w, font)
        if line is None:
            x, y = x0, line_y
        else:
            last = st["lastStrokes"][-1]
            (x, y), = app.cmd({"cmd": "toPad", "points": [[last[2], line["y"]]]})["points"]
            x += hand.h * 0.9
            if x + width > pad_w * 0.95:
                app.touch(two_finger(pad_w / 2, pad_h / 2, 25, 25, shift=(-(pad_w * 0.45), 0), dur=0.5))
                settle(app)
                (x, y), = app.cmd({"cmd": "toPad", "points": [[last[2], line["y"]]]})["points"]
                x += hand.h * 0.9
        strokes = hand.word(w, x, y, font)
        fr, cid = hand.frames(strokes, cid)
        fr += [[0.008, []]] * int(0.55 / 0.008)   # the pause after the word (> 400 ms: the page may move now)
        before = app.state()["view"]
        r = app.touch(fr, settle=0.05)
        after_view = settle(app)
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
        recs.append({"word": w, "midWordMove": moved, "newLine": new_line, "view": after["view"], "before": before, "bounds": wb})
        if new_line and line:
            # The next word starts the new line: below this line's first word.
            nl = {"x": line["x"], "y": line["y"] - max(line["h"] * 1.6, after["view"]["h"] * 0.12), "h": line["h"]}
            (x0, line_y), = app.cmd({"cmd": "toPad", "points": [[nl["x"], nl["y"]]]})["points"]
            line = None
    return recs, cid


def scenario_writing(app, rep, hand, zoom, width_index, pan, words):
    """Writing mode at `zoom`, line width ½/¾/full, pan none/centre/left: a sentence across the line, a pause,
    the next line."""
    st = app.state()
    pad_w, pad_h = st["padMM"]
    # Set up the way a person does: the writing panel (chevron) for width and pan, W for writing mode.
    if not st["writing"]: app.press("w", until=lambda s: s["writing"])
    app.click("writing", "chevron")
    app.cmd({"cmd": "panelPick", "writing": width_index})
    app.cmd({"cmd": "panelPick", "writing": 3 + pan})
    app.press("esc")
    s, ms = app.press("d", until=lambda s: s["draw"])
    if not s["draw"]: app.click("draw"); s = app.state()   # builds from before D entered draw mode
    rep.step("D enters draw mode", ms=round(ms or -1))
    if zoom > 1:
        app.touch(two_finger(pad_w / 2, pad_h * 0.6, 15, 15 * zoom, dur=0.6))
    st = app.state()
    rep.step("view", zoom=round(st["view"]["zoom"], 2), lineWidth=st["lineWidth"], autoPan=st["autoPan"])
    app.cmd({"cmd": "mark"})
    recs, _ = write_words(app, hand, words, pad_h * 0.62, pad_w * 0.12, 1000, rep)
    st = app.state()
    return recs, st


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

    @scenario("write-zoom1", "Writing mode at zoom 1, full width, centre pan: a sentence across the line, pauses, the next line. The page must never move inside a word.")
    def _():
        words = (SENTENCE + " " + SENTENCE).split()
        recs, st = scenario_writing(app, rep, hand, 1, 2, 1, words)
        judge_writing(app, rep, recs, st, " ".join(words))

    @scenario("write-zoom3", "The same at zoom 3 (pinched in with two fingers): writing mode pans along the line and goes to the next line.")
    def _():
        app.press("n", until=lambda s: s["page"] > 0 or True)
        words = (SENTENCE + " " + SENTENCE).split()
        recs, st = scenario_writing(app, rep, hand, 3, 2, 1, words)
        judge_writing(app, rep, recs, st, " ".join(words))

    for wi, wname in enumerate(["half", "three-quarter", "full"]):
        for pi, pname in enumerate(["no-pan", "centre", "left"]):
            if (wi, pi) == (2, 1): continue   # write-zoom3 covers full + centre
            def make(wi=wi, pi=pi, wname=wname, pname=pname):
                def f():
                    app.press("n")
                    recs, st = scenario_writing(app, rep, hand, 3, wi, pi, SENTENCE.split()[:7])
                    judge_writing(app, rep, recs, st, " ".join(SENTENCE.split()[:7]), ocr_check=False)
                return f
            S[f"write-{wname}-{pname}"] = (f"Writing mode at zoom 3, {wname} line width, {pname.replace('-', ' ')}: seven words, with the new line where the width runs out.", make())

    @scenario("pan-right-by-hand", "Karthik's case: start a line, pan right with two fingers past the line width, keep writing there and pause. The page must stay where he put it (no jump back to the margin).")
    def _():
        app.press("n")
        st = app.state()
        if not st["writing"]: app.press("w", until=lambda s: s["writing"])
        app.click("writing", "chevron"); app.cmd({"cmd": "panelPick", "writing": 0}); app.cmd({"cmd": "panelPick", "writing": 4}); app.press("esc")
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
        app.touch(two_finger(pad_w / 2, pad_h * 0.6, 15, 45, dur=0.6))   # zoom 3
        settle(app); time.sleep(0.6)
        s1 = app.state()
        rep.check(bool(s1.get("pageMap")) and s1["view"]["zoom"] > 1.5, "zoomed in: the page map shows", f"zoom {s1['view']['zoom']:.1f}, map {s1.get('pageMap')}")
        rep.shot(app, "page map at zoom 3 (top right)")
        app.press("d", until=lambda s: not s["draw"])
        v0 = app.state()["view"]
        app.cmd({"cmd": "clickMap", "x": 0.85, "y": 0.5}); time.sleep(0.2)
        v1 = app.state()["view"]
        rep.check(v1["x"] > v0["x"] + v0["w"] * 0.3, "clicking the map's right side moves the view there", f"view x {v0['x']:.0f} -> {v1['x']:.0f}")
        app.cmd({"cmd": "clickMap", "x": 0.85, "y": 0.5, "to": [0.15, 0.5]}); time.sleep(0.2)
        v2 = app.state()["view"]
        rep.check(v2["x"] < v1["x"] - v1["w"] * 0.3, "dragging on the map moves the view along", f"view x {v1['x']:.0f} -> {v2['x']:.0f}")
        rep.shot(app, "after dragging on the map")
        app.cmd({"cmd": "menu", "action": "togglePageMapAction"}); time.sleep(0.3)
        rep.check(not app.state().get("pageMap"), "View › Page Map turns it off")
        app.cmd({"cmd": "menu", "action": "togglePageMapAction"}); time.sleep(0.3)
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
        rep.check(len(tips) > 0 and all(tips) and len(tips) <= 14, "every toolbar button has a tooltip; 14 buttons or fewer", f"{sum(1 for t in tips if t)}/{len(tips)} buttons")
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
        # The pending move: write to the right part of the view in writing mode, then look during the pause.
        ensure(app, "writing", True, "w")
        fr, cid = hand.frames(hand.word("edge", pad_w * 0.66, pad_h * 0.5, hand.roman), cid)
        app.touch(fr + [[0.008, []]] * 12, settle=0.0)
        p0 = app.state().get("pendingMove", "")
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
            rep.check(b["strokes"] > a and dink > 100, f"{w}x{h}: the word is drawn and shows in the window", f"{b['strokes'] - a} strokes, +{dink} ink pixels on screen")

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
        if not app.state()["draw"]: app.press("d", until=lambda s: s["draw"])
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
    pans, lines = flow_metrics(recs)
    rep.step("page moves", pans=[(p["wordsVisible"], round(p["jump"], 2)) for p in pans], newLines=len(lines))
    if pans:
        few = min(p["wordsVisible"] for p in pans)
        big = max(p["jump"] for p in pans)
        rep.check(few >= 2, "after every pan the last 2-3 words are still on screen", f"fewest words visible after a pan: {few} ({len(pans)} pans)")
        rep.check(big <= 0.52, "no pan jumps more than half a screen", f"largest jump {big:.0%} of the view")
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
