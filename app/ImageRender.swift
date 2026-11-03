// Pictures on the GPU. Each picture has a preview texture (the reduced copy, mipmapped) and, when the preview is smaller
// than the picture, full-resolution tiles of 1,024 px (plus a 4 px border copied from the neighbours, so filtering is
// seamless across tile edges), each mipmapped. A frame draws, per picture in view:
//   - the preview, when it has at least as many pixels as the screen shows (zoomed out, or a small picture);
//   - else the tiles in view, and the preview's part for any tile not loaded yet (never a hole, never drawn twice).
// Textures are made on a background queue from the memory-mapped decoded pixels (no decode on the main thread), and the
// least recently drawn ones go when they use more than `budget` bytes. Drawing a picture is one quad per tile in view
// (at most a few dozen): the ink's own drawing is unchanged.
import Metal
import QuartzCore

final class ImageTextures {
    let device: MTLDevice
    private let uploads: MTLCommandQueue
    private let work = DispatchQueue(label: "scrawl.images.upload", qos: .userInitiated)
    /// A texture finished loading (main queue): draw again.
    var onReady: (() -> Void)?
    static let tile = 1024, gutter = 4
    /// GPU memory for pictures' textures; the least recently drawn are released beyond it (they load again when needed).
    nonisolated(unsafe) static var budget = 256 << 20

    private struct Key: Hashable { let asset: String; let tile: Int }   // tile -1: the preview
    private final class Entry { var texture: MTLTexture?; var bytes = 0; var lastUsed = 0; var loading = false; var failed = false }
    private var entries: [Key: Entry] = [:]
    private var frame = 0
    private(set) var residentBytes = 0
    /// Last frame: tiles drawn, previews drawn (whole or for missing tiles), textures still loading.
    private(set) var stats = (tiles: 0, previews: 0, loading: 0)
    var loadingCount: Int { entries.values.filter(\.loading).count }

    init(device: MTLDevice) {
        self.device = device
        uploads = device.makeCommandQueue()!
    }

    /// What to draw for `objects` (bottom first) in `visible` (page units) at `pxPerUnit` device pixels per page unit.
    /// `sync`: everything needed is loaded now, decoding if it has to (snapshots for the overview's transition, exports
    /// of the view, tests); otherwise missing textures load in the background and `onReady` is called.
    /// At most this many tiles are made synchronously in one call (~5 ms each): the rest load in the background and the
    /// preview stands in for them, the same in the snapshot and in the frames after it.
    static let maxSyncTiles = 6
    private var syncLeft = 0

    func draws(_ objects: [ImageObject], visible: CGRect, pxPerUnit: Double, sync: Bool = false) -> Renderer.ImageDraws {
        frame += 1
        syncLeft = Self.maxSyncTiles
        var out = Renderer.ImageDraws()
        var st = (tiles: 0, previews: 0, loading: 0)
        for o in objects {
            let F = o.frame
            guard F.width > 0, F.height > 0, F.intersects(visible) else { continue }
            out.under.append(F)
            let a = o.asset, W = Double(a.pixelWidth), H = Double(a.pixelHeight)
            let preview = texture(a, tile: -1, sync: sync)
            let shown = F.intersection(visible)
            /// The canvas rect `r` (inside F) and its place in the picture (0...1, v from the top).
            func uv(_ r: CGRect) -> CGRect {
                CGRect(x: (r.minX - F.minX) / F.width, y: (F.maxY - r.maxY) / F.height, width: r.width / F.width, height: r.height / F.height)
            }
            let k = pxPerUnit * F.width / W                         // device pixels per picture pixel
            let previewScale = Double(a.previewSize.width) / W
            if !a.tiled || k <= previewScale * 1.01 {
                if let p = preview { out.quads.append(.init(texture: p, rect: shown, uv: uv(shown))); st.previews += 1 } else { st.loading += 1 }
                continue
            }
            // Tiles in view (in picture pixels, rows from the top), and a ring of one more around them (loaded ahead).
            let T = Double(Self.tile)
            let cols = Int((W / T).rounded(.up)), rows = Int((H / T).rounded(.up))
            let px0 = (shown.minX - F.minX) / F.width * W, px1 = (shown.maxX - F.minX) / F.width * W
            let py0 = (F.maxY - shown.maxY) / F.height * H, py1 = (F.maxY - shown.minY) / F.height * H
            let c0 = max(Int(px0 / T), 0), c1 = min(Int((px1 - 1e-6) / T), cols - 1)
            let r0 = max(Int(py0 / T), 0), r1 = min(Int((py1 - 1e-6) / T), rows - 1)
            guard c0 <= c1, r0 <= r1 else { continue }
            for r in max(r0 - 1, 0)...min(r1 + 1, rows - 1) {
                for c in max(c0 - 1, 0)...min(c1 + 1, cols - 1) {
                    let inView = r >= r0 && r <= r1 && c >= c0 && c <= c1
                    let t = texture(a, tile: r * cols + c, sync: sync && inView)
                    guard inView else { continue }
                    let x0 = Double(c) * T, x1 = min(Double(c + 1) * T, W), y0 = Double(r) * T, y1 = min(Double(r + 1) * T, H)
                    let core = CGRect(x: F.minX + x0 / W * F.width, y: F.maxY - y1 / H * F.height, width: (x1 - x0) / W * F.width, height: (y1 - y0) / H * F.height)
                    if let t {
                        let tx0 = max(x0 - Double(Self.gutter), 0), ty0 = max(y0 - Double(Self.gutter), 0)
                        let tuv = CGRect(x: (x0 - tx0) / Double(t.width), y: (y0 - ty0) / Double(t.height),
                                         width: (x1 - x0) / Double(t.width), height: (y1 - y0) / Double(t.height))
                        out.quads.append(.init(texture: t, rect: core, uv: tuv)); st.tiles += 1
                    } else if let p = preview {
                        out.quads.append(.init(texture: p, rect: core, uv: uv(core))); st.previews += 1; st.loading += 1
                    } else { st.loading += 1 }
                }
            }
        }
        stats = st
        trim()
        return out
    }

    /// A tile's (or the preview's) texture if it's loaded; starts loading it if not.
    private func texture(_ a: ImageAsset, tile: Int, sync: Bool) -> MTLTexture? {
        let key = Key(asset: a.key, tile: tile)
        let e = entries[key] ?? { let e = Entry(); entries[key] = e; return e }()
        e.lastUsed = frame
        if let t = e.texture { return t }
        if e.failed { return nil }
        // The preview whose pixels are already mapped is made now (a few ms, once): a page never shows white where its
        // picture is. Tiles beyond the synchronous allowance load in the background.
        var sync = sync && (tile < 0 || syncLeft > 0)
        if tile < 0 && a.previewMapped { sync = true }
        if sync && tile >= 0 { syncLeft -= 1 }
        if sync {
            if let t = make(a, tile: tile, wait: true) { e.texture = t; e.bytes = Self.bytes(t); residentBytes += e.bytes; e.loading = false } else { e.failed = true }
            return e.texture
        }
        guard !e.loading else { return nil }
        e.loading = true
        work.async { [weak self] in
            let t = self?.make(a, tile: tile, wait: true)
            DispatchQueue.main.async {
                guard let self, let e = self.entries[key], e.texture == nil else { return }
                e.loading = false
                if let t { e.texture = t; e.bytes = Self.bytes(t); self.residentBytes += e.bytes } else { e.failed = true }
                self.onReady?()
            }
        }
        return nil
    }

    private static func bytes(_ t: MTLTexture) -> Int { t.width * t.height * 4 * 4 / 3 }

    /// Make a texture from the decoded pixels (decoding first if they aren't cached), with its mipmaps.
    private func make(_ a: ImageAsset, tile: Int, wait: Bool) -> MTLTexture? {
        let raster: Raster?, x0: Int, y0: Int, w: Int, h: Int
        if tile < 0 {
            raster = a.preview(); x0 = 0; y0 = 0; w = raster?.width ?? 0; h = raster?.height ?? 0
        } else {
            raster = a.full()
            let cols = (a.pixelWidth + Self.tile - 1) / Self.tile, c = tile % cols, r = tile / cols, G = Self.gutter
            x0 = max(c * Self.tile - G, 0); y0 = max(r * Self.tile - G, 0)
            w = min((c + 1) * Self.tile + G, a.pixelWidth) - x0; h = min((r + 1) * Self.tile + G, a.pixelHeight) - y0
        }
        guard let raster, w > 0, h > 0, x0 + w <= raster.width, y0 + h <= raster.height else { return nil }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: true)
        d.usage = .shaderRead
        d.storageMode = device.hasUnifiedMemory ? .shared : .managed
        guard let t = device.makeTexture(descriptor: d) else { return nil }
        t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: raster.base + y0 * raster.bytesPerRow + x0 * 4, bytesPerRow: raster.bytesPerRow)
        if t.mipmapLevelCount > 1, let cb = uploads.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: t); blit.endEncoding(); cb.commit()
            if wait { cb.waitUntilCompleted() }
        }
        return t
    }

    /// Release the least recently drawn textures beyond the budget (never one drawn this frame).
    private func trim() {
        guard residentBytes > Self.budget else { return }
        for (k, e) in entries.sorted(by: { $0.value.lastUsed < $1.value.lastUsed }) where e.lastUsed < frame && e.texture != nil {
            residentBytes -= e.bytes; entries[k] = nil
            if residentBytes <= Self.budget { break }
        }
    }
    /// Release everything (tests).
    func dropAll() { entries = entries.filter(\.value.loading); residentBytes = 0 }
}
