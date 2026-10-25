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
       "i": 34, "p": 35, "return": 36, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46, "space": 49, "esc": 53,
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
        recs.append({"word": w, "midWordMove": moved, "newLine": new_line, "view": after["view"]})
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
        p = rep.shot(app, "recorded session replayed")
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


def judge_writing(app, rep, recs, st, text, ocr_check=True):
    mid = [r["word"] for r in recs if r["midWordMove"]]
    rep.check(not mid, "the page never moved inside a word", f"moved inside: {mid}" if mid else f"{len(recs)} words")
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
