// Pictures on the open page: inserting one (⌘V, a drop, Insert Image…), and, with the Select tool, selecting one (a
// click on it: an outline and four corner handles), moving it (drag it), resizing it (drag a corner: its proportions
// stay; with Shift held they're free), deleting it (⌫), and bringing it forward or sending it back (⌥⌘] / ⌥⌘[).
// Every change is one undo step of the page (⌘Z, the two-finger double tap, the scrub). The ink never moves with a
// picture. A picture is never edited in place: each change is a new image object (new id) with the same stored file,
// like a stroke, so the undo history and the notebook keep every earlier frame exactly.
import AppKit

/// A move or resize in progress: where the pointer went down, the picture as it was, and which corner (nil: a move).
struct ImageDrag {
    let start: CGPoint
    let original: ImageObject
    let corner: Int?          // 0 bottom-left, 1 bottom-right, 2 top-right, 3 top-left (page units, y up)
    var current: ImageObject
    var moved = false
}

extension ImageObject {
    /// The same picture with another frame (a new object: a new id).
    func with(frame f: CGRect, id newId: Int) -> ImageObject { ImageObject(id: newId, asset: asset, frame: f, source: source, added: added) }
    var corners: [CGPoint] { [CGPoint(x: frame.minX, y: frame.minY), CGPoint(x: frame.maxX, y: frame.minY), CGPoint(x: frame.maxX, y: frame.maxY), CGPoint(x: frame.minX, y: frame.maxY)] }
}

extension CanvasView {
    /// View points per page unit at the current zoom.
    private var pointsPerUnit: Double { ptPerUnit * camera.zoom }
    /// Handles: 10 pt squares at the corners, grabbed within 8 pt of the corner.
    static let handleSizePt = 10.0, handleGrabPt = 8.0, minImagePt = 16.0

    var selectedImage: ImageObject? { selectedImageId.flatMap { id in doc.images.first { $0.id == id } } }

    // MARK: inserting

    /// A picture placed on the open page: centred on `center` (page units; default the view's centre), at most 60% of the
    /// view's width and height and never larger than its own pixels on screen, above the page's other pictures, under the
    /// ink. One undo step. Returns the new object.
    @discardableResult
    func insertImage(_ p: PreparedImagePage, center: CGPoint? = nil) -> ImageObject {
        let v = camera.visible, a = p.asset
        let backing = Double(window?.backingScaleFactor ?? 2)
        let natural = CGSize(width: Double(a.pixelWidth) / backing / pointsPerUnit, height: Double(a.pixelHeight) / backing / pointsPerUnit)
        let s = min(1, v.width * 0.6 / natural.width, v.height * 0.6 / natural.height)
        let size = CGSize(width: natural.width * s, height: natural.height * s)
        let c = center ?? CGPoint(x: v.midX, y: v.midY)
        let o = ImageObject(id: takeImageId(), asset: a, frame: CGRect(x: c.x - size.width / 2, y: c.y - size.height / 2, width: size.width, height: size.height),
                            source: p.request.source, added: Document.clock())
        doc.setImages(doc.images + [o], undoable: true)
        act("insertImage", ["id": o.id, "px": [a.pixelWidth, a.pixelHeight], "kind": p.request.source.kind.rawValue])
        markDirty(); setNeedsRender()
        return o
    }

    // MARK: the Select tool on pictures

    /// The picture (topmost first) and corner under `p`: a handle of the selected picture first, then any picture.
    func imageHit(at p: CGPoint) -> (image: ImageObject, corner: Int?)? {
        let grab = Self.handleGrabPt / pointsPerUnit
        if let s = selectedImage, let k = s.corners.firstIndex(where: { abs($0.x - p.x) <= grab && abs($0.y - p.y) <= grab }) { return (s, k) }
        if let top = doc.images.last(where: { $0.frame.contains(p) }) { return (top, nil) }
        return nil
    }

    /// A pointer press with the Select tool: on a picture, it's selected and a move (or, on a handle, a resize) starts.
    /// False if there's no picture there (the press is the box selection's).
    func imageMouseDown(at p: CGPoint) -> Bool {
        guard let (img, corner) = imageHit(at: p) else { return false }
        setSelection(nil, "image")
        selectedImageId = img.id
        imageDrag = ImageDrag(start: p, original: img, corner: corner, current: img)
        return true
    }

    func imageMouseDragged(to p: CGPoint, freeAspect: Bool) {
        guard var d = imageDrag, let i = doc.images.firstIndex(where: { $0 === d.current }) else { imageDrag = nil; return }
        let o = d.original.frame, dx = p.x - d.start.x, dy = p.y - d.start.y
        var f: CGRect
        if let k = d.corner {
            // The opposite corner stays; the dragged one follows the pointer.
            let anchor = d.original.corners[(k + 2) % 4], moving = d.original.corners[k]
            let sx: Double = moving.x >= anchor.x ? 1 : -1, sy: Double = moving.y >= anchor.y ? 1 : -1
            let minU = Self.minImagePt / pointsPerUnit
            var w = max((moving.x + dx - anchor.x) * sx, minU), h = max((moving.y + dy - anchor.y) * sy, minU)
            if !freeAspect {   // proportions kept: the larger of the two changes wins
                let s = max(w / o.width, h / o.height, minU / min(o.width, o.height))
                w = o.width * s; h = o.height * s
            }
            f = CGRect(x: sx > 0 ? anchor.x : anchor.x - w, y: sy > 0 ? anchor.y : anchor.y - h, width: w, height: h)
        } else {
            f = o.offsetBy(dx: dx, dy: dy)
        }
        guard f != d.current.frame else { return }
        let n = d.current.with(frame: f, id: takeImageId())
        var list = doc.images; list[i] = n
        doc.setImages(list, undoable: !d.moved)   // the drag's one undo step, taken as it starts moving
        d.moved = true; d.current = n
        imageDrag = d
        selectedImageId = n.id
        setNeedsRender()
    }

    func imageMouseUp() {
        guard let d = imageDrag else { return }
        imageDrag = nil
        guard d.moved else { return }   // a click: just the selection
        act(d.corner == nil ? "imageMove" : "imageResize", ["id": d.current.id, "x": d.current.frame.minX, "y": d.current.frame.minY,
                                                          "w": d.current.frame.width, "h": d.current.frame.height])
        markDirty()
    }

    /// ⌫ with a picture selected: it goes (one undo step). The stored file stays while the undo history needs it.
    func deleteSelectedImage() {
        guard let s = selectedImage else { return }
        doc.setImages(doc.images.filter { $0 !== s }, undoable: true)
        selectedImageId = nil
        act("imageDelete", ["id": s.id]); markDirty(); setNeedsRender()
    }

    /// Bring forward (+1) or send back (-1) one place among the page's pictures (always under the ink).
    func reorderSelectedImage(_ step: Int) {
        guard let s = selectedImage, let i = doc.images.firstIndex(where: { $0 === s }) else { return }
        let j = min(max(i + step, 0), doc.images.count - 1)
        guard j != i else { return }
        var list = doc.images; list.remove(at: i); list.insert(s, at: j)
        doc.setImages(list, undoable: true)
        act("imageOrder", ["id": s.id, "to": j]); markDirty(); setNeedsRender()
    }

    /// The selected picture's outline (1 pt) and corner handles (white squares with a blue edge), at any zoom.
    func imageSelectionItems(vis: CGRect) -> [Renderer.DrawItem] {
        guard tools.tool == .select, let s = selectedImage, s.frame.intersects(vis.insetBy(dx: -20, dy: -20)) else { return [] }
        let k = 1 / pointsPerUnit
        func quad(_ r: CGRect) -> [SIMD2<Float>] {
            let a = SIMD2<Float>(Float(r.minX), Float(r.minY)), b = SIMD2<Float>(Float(r.maxX), Float(r.minY))
            let c = SIMD2<Float>(Float(r.maxX), Float(r.maxY)), d = SIMD2<Float>(Float(r.minX), Float(r.maxY))
            return [a, b, c, a, c, d]
        }
        func premul(_ c: SIMD4<Float>) -> SIMD4<Float> { SIMD4(c.x * c.w, c.y * c.w, c.z * c.w, c.w) }
        let f = s.frame, w = 1.5 * k
        var line: [SIMD2<Float>] = []
        for r in [CGRect(x: f.minX, y: f.minY - w / 2, width: f.width, height: w), CGRect(x: f.minX, y: f.maxY - w / 2, width: f.width, height: w),
                  CGRect(x: f.minX - w / 2, y: f.minY, width: w, height: f.height), CGRect(x: f.maxX - w / 2, y: f.minY, width: w, height: f.height)] { line += quad(r) }
        let h = Self.handleSizePt * k, hi = (Self.handleSizePt - 3) * k
        var edge: [SIMD2<Float>] = [], fill: [SIMD2<Float>] = []
        for c in s.corners {
            edge += quad(CGRect(x: c.x - h / 2, y: c.y - h / 2, width: h, height: h))
            fill += quad(CGRect(x: c.x - hi / 2, y: c.y - hi / 2, width: hi, height: hi))
        }
        let blue = premul(Self.selectionLine)
        selectedImageDrawnForTest = f
        return [.init(mesh: Mesh(), verts: line, color: blue), .init(mesh: Mesh(), verts: edge, color: blue), .init(mesh: Mesh(), verts: fill, color: SIMD4(1, 1, 1, 1))]
    }
}
