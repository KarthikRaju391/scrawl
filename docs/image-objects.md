# Image objects (0.1.6)

Pictures on a page, under the ink. A picture comes in as a **new page** with the picture at the page's width, at its
top (dragged onto the window, ⌘V, File › New Page from Image… ⇧⌘N, or a web snapshot from the browser extension).
You write on it with every tool; exports, Copy as Image, thumbnails and the page map show it.

## Model

An **image object** is an id, an **asset** (the picture's bytes) and a **frame** in page units (y up, the same space as
the ink). A page holds any number of them in z-order, all under its ink. Nothing assumes a frame lies inside the page's
column (x in 0…1600, y below the page's top): the infinite canvas (step 2) needs no format change. Objects are immutable
like strokes; a move or resize (step 3) will be a new object with a new id, so undo works the same way as for ink.

Undo: a page's undo steps hold its strokes **and** its image objects (`Document.State`). Making a picture page is undone
like a page delete (⌘Z right after: the page goes). Clear Page clears the ink, not pictures. Scratch-out and the eraser
only ever act on strokes.

## Storage

- **The picture's file, unchanged.** `Images/<sha256, 32 hex>.<ext>` next to `Notebook.tdnb`: the original bytes
  (no resampling, no re-encoding). The same picture imported twice is stored once.
- **The notebook refers to it.** The file holds the image objects (id, asset hash, type, pixel size, frame, source), a
  few hundred bytes each. An autosave writes the same few kilobytes as before however large the pictures are, and the
  main-thread snapshot is unchanged (references only).
- **Order on disk (kill -9).** The picture file is written (atomically) before the page that shows it exists, so any
  notebook that refers to it is saved after it.
- **Deleting.** After a save, picture files nothing refers to are removed: not the saved notebook, not its undo
  history, not a deleted page ⌘Z can still bring back, and never a file written in the last minute (an import in
  flight). Deleting a page therefore deletes its picture once that page can't come back. Only pictures the running app
  has seen in use are removed: a file no page referred to when the notebook was opened stays (see Compatibility). When
  the notebook on disk is unreadable (kept aside), nothing is removed.
- **Limits.** 65,536 px on a side, 120 megapixels, 200 MB of file. Larger pictures are refused with a message.
- **Decoded pixels** are a cache: `~/Library/Caches/Scrawl/Images/` (or `$TRACKPAD_DRAW_DATA/ImageCache`), raw
  premultiplied RGBA, memory-mapped (the system can drop the pages; they're not dirty memory). Each picture is decoded
  once. Up to 3 GB; the least recently used files go first and are decoded again when needed.

## Drawing

Metal draws each picture under the ink:

- a **preview** texture (the picture reduced to at least ¼ of its size, at most 8,192 px on its long side; the whole
  picture when it's ≤ 2,048 px), mipmapped: used whenever it has as many pixels as the screen shows;
- otherwise **tiles** of 1,024 px (with a 4 px border copied from their neighbours, so filtering is seamless), each
  mipmapped, loaded on a background queue from the mapped pixels as they come into view (one ring ahead). A tile not
  loaded yet is drawn from the preview: never a hole.
- Textures beyond 256 MB are released, least recently drawn first.
- Paper: the page's pattern (grid, dots, ruled) stops at a picture's frame; under it is plain white paper, so the
  pattern never shows through a transparent picture. Around and below the picture the paper is as before. The dashed
  screen-height lines aren't drawn on pages with pictures, and those pages never show the "filled a screen" note.

The overview's transition snapshots load what they need synchronously, so the moving picture is exactly what the canvas
then draws.

## Exports

- **PNG** (Export Page, Copy as Image, Copy Page, Share): the picture under the ink at the export's scale. Paper or
  White: white under the picture; Transparent: the picture's own transparency.
- **SVG**: the picture is embedded in the file as a base64 `data:` URI (one self-contained file, no folder beside
  it). PNG, JPEG and GIF are embedded as their original bytes; HEIC as JPEG (quality 0.92) and TIFF or PDF as PNG,
  since browsers can't show those.
- **PDF** (Export All Pages, Copy's PDF): a JPEG goes in as its own JPEG data; a PDF picture as vectors.
- "Page" area on a picture page: the page's width, from its top down to the lowest picture edge (or 20 units below the
  lowest ink, if that's lower).

## Formats in

PNG, JPEG, HEIC/HEIF, TIFF, GIF (first frame), BMP, WebP, PDF (first page, drawn 4,000 px wide for the screen and as
vectors in PDF exports), and screenshots (Display P3 PNGs; colours are converted to sRGB for drawing). EXIF orientation
is applied.

## The Inbox (for other programs: the browser extension)

A writer adds a page by putting a folder into `<data folder>/Inbox/` (data folder: `$TRACKPAD_DRAW_DATA`, else
`~/Library/Application Support/Scrawl`):

1. write `Inbox/.tmp-<id>/` with `page.json` and the picture;
2. rename it to `Inbox/<id>.scrawlpage` (the app never sees a half-written item);
3. optionally post the distributed notification `<bundle id>.inbox` (`com.karthikraju.scrawl` release,
   `local.trackpad-draw` dev). The app watches the folder anyway; if it isn't running, the item is imported at the next
   launch. `open -g -b <bundle id>` starts it without taking focus.

```json
{"version": 1,
 "image": "page.png",
 "source": {"url": "https://…", "title": "…", "fileName": null, "capturedAt": "2026-11-03T19:40:00Z"},
 "coordinateScale": 2,
 "strokes": [{"tool": "pen", "color": "#1a73e8", "size": 3, "points": [[x, y, pressure], …]}]}
```

- Points: the picture's own coordinates, x right, y down from its top-left corner, in units of `coordinateScale`
  pixels (a web page's CSS px with `coordinateScale` = devicePixelRatio). Pressure 0…1. `size`: the diameter at full
  pressure in the same units. Tools: pen, marker, highlighter (alpha from the tool, 35% for the highlighter).
- The page is added after the last page. It opens unless you're drawing (then a note says it was added).
- When the notebook with the page is saved, the app writes `Inbox/<id>.done.json`:
  `{"ok": true, "page": N, "pages": M}` or `{"ok": false, "error": "…"}`, and removes the item (a failed item is kept
  as `<id>.failed`). Result files are removed after a day. The page records `<id>`, so a crash between the save and
  the removal never makes a second page.
- `tools/inbox_write.py` is a reference writer (the tests use it).

## Compatibility

- **A notebook without pictures is written exactly as before**: every new key is optional and left out (checked byte for
  byte against 0.1.5's file structure).
- **0.1.5 and older open a notebook with pictures** without crashing: the pictures' keys are skipped and every page
  and stroke is there. Pictures don't show there. If an older version then saves the notebook, the pages lose their
  pictures (it doesn't write those keys back); the files stay in Images/ (0.1.6 never removes a file it didn't see in
  use), so a backup of the notebook still has them.
- **0.1.6 opens older notebooks unchanged.**
