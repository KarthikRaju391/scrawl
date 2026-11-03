#!/usr/bin/env python3
"""Put an image page into Scrawl's Inbox, the way the browser extension's native host does (see app/Inbox.swift).

    tools/inbox_write.py --data <data folder> --id <id> --image page.png [--url U] [--title T] [--scale 2] [--strokes strokes.json]

<data folder> is $TRACKPAD_DRAW_DATA, or ~/Library/Application Support/Scrawl. The item is written under a dot-name and
renamed into place, so the app never sees it half-written. strokes.json: a list of
{"tool": "pen"|"marker"|"highlighter", "color": "#rrggbb", "size": 3, "points": [[x, y, pressure], ...]} in the
picture's coordinates (x right, y down from its top-left), in units of --scale pixels (CSS px with --scale = dpr).
Prints the path of the result file the app writes when the page is saved (<id>.done.json)."""
import argparse, json, os, shutil, sys, uuid

a = argparse.ArgumentParser()
a.add_argument("--data", required=True); a.add_argument("--id", default=None); a.add_argument("--image", required=True)
a.add_argument("--url"); a.add_argument("--title"); a.add_argument("--file-name"); a.add_argument("--captured-at")
a.add_argument("--scale", type=float, default=1.0); a.add_argument("--strokes")
o = a.parse_args()
item = o.id or str(uuid.uuid4())
inbox = os.path.join(o.data, "Inbox")
os.makedirs(inbox, exist_ok=True)
tmp = os.path.join(inbox, ".tmp-" + item)
shutil.rmtree(tmp, ignore_errors=True); os.makedirs(tmp)
name = "page" + os.path.splitext(o.image)[1].lower()
shutil.copyfile(o.image, os.path.join(tmp, name))
page = {"version": 1, "image": name, "coordinateScale": o.scale,
        "source": {k: v for k, v in {"url": o.url, "title": o.title, "fileName": o.file_name, "capturedAt": o.captured_at}.items() if v},
        "strokes": json.load(open(o.strokes)) if o.strokes else []}
with open(os.path.join(tmp, "page.json"), "w") as f: json.dump(page, f)
os.rename(tmp, os.path.join(inbox, item + ".scrawlpage"))
print(os.path.join(inbox, item + ".done.json"))
