// Metal renderer. Strokes are triangle meshes (a fan per point + a quad per segment, same shape
// as strokePath). Everything is redrawn every frame on the GPU, so zoom/pan need no caches.
// A per-stroke stencil reference makes each stroke cover a pixel once: the highlighter's alpha
// is applied once per stroke, like the CPU union fill.
import Metal
import MetalKit
import simd

private let shaderSource = """
#include <metal_stdlib>
using namespace metal;
struct VOut { float4 pos [[position]]; float2 canvas; };
struct Xf { float4 m; };   // ndc = canvas * m.xy + m.zw

vertex VOut stroke_v(const device float2* v [[buffer(0)]], constant Xf& xf [[buffer(1)]], uint vid [[vertex_id]]) {
    VOut o; o.canvas = v[vid]; o.pos = float4(v[vid] * xf.m.xy + xf.m.zw, 0, 1); return o;
}
fragment float4 stroke_f(constant float4& color [[buffer(0)]]) { return color; }   // premultiplied

vertex VOut bg_v(uint vid [[vertex_id]], constant Xf& xf [[buffer(1)]]) {
    float2 ndc = float2(float((vid << 1) & 2), float(vid & 2)) * 2 - 1;
    VOut o; o.pos = float4(ndc, 0, 1); o.canvas = (ndc - xf.m.zw) / xf.m.xy; return o;
}
struct BG { float kind; float spacing; float pxPerUnit; float pageWidth; float pageTop; float hasPage; float _a; float _b; };
fragment float4 bg_f(VOut in [[stage_in]], constant BG& bg [[buffer(0)]]) {
    // Off the page (left/right of it, above its top; it is endless downwards): a plain grey desk with a
    // soft shadow along the page edge, so it can't be mistaken for writing space.
    if (bg.hasPage > 0) {
        float dx = max(max(-in.canvas.x, in.canvas.x - bg.pageWidth), 0.0);
        float dy = max(in.canvas.y - bg.pageTop, 0.0);
        float d = length(float2(dx, dy)) * bg.pxPerUnit;   // device pixels outside the page
        if (d > 0) {
            float4 desk = float4(0.80, 0.82, 0.85, 1);
            float4 shadow = float4(0.55, 0.57, 0.61, 1);
            return mix(desk, shadow, exp(-d / 10.0) * 0.6);
        }
    }
    float4 paper = float4(1, 1, 1, 1);
    float4 line = float4(0.82, 0.84, 0.87, 1);
    float2 c = in.canvas / bg.spacing;
    float2 w = fwidth(c);
    float a = 0;
    if (bg.kind == 1) {            // square grid, 1 px lines
        float2 g = abs(fract(c - 0.5) - 0.5) / w; a = 1 - min(min(g.x, g.y), 1.0);
    } else if (bg.kind == 2) {     // dot grid, ~1.5 px dots
        float2 d = (fract(c + 0.5) - 0.5) * bg.spacing * bg.pxPerUnit;
        a = clamp(2.0 - length(d), 0.0, 1.0);
        line = float4(0.65, 0.68, 0.72, 1);
    } else if (bg.kind == 3) {     // ruled
        float g = abs(fract(c.y - 0.5) - 0.5) / w.y; a = 1 - min(g, 1.0);
    }
    return mix(paper, line, a);
}
"""

struct Mesh {
    var buffer: MTLBuffer?
    var count = 0
}

/// Reference tessellation (a full circle at every point + a quad per segment). Exact union shape,
/// but ~66 vertices per point; kept for the bench's pixel comparison.
func strokeMeshCircles(_ pts: [StrokePoint], radii: [Double], segments: Int = 20) -> [SIMD2<Float>] {
    var v: [SIMD2<Float>] = []
    guard !pts.isEmpty else { return v }
    v.reserveCapacity(pts.count * (segments * 3 + 6))
    let unit = (0..<segments).map { i -> SIMD2<Float> in
        let a = Float(i) / Float(segments) * 2 * .pi
        return SIMD2(cos(a), sin(a))
    }
    for i in pts.indices {
        let c = SIMD2<Float>(Float(pts[i].p.x), Float(pts[i].p.y)), r = Float(radii[i])
        for k in 0..<segments {
            v.append(c); v.append(c + unit[k] * r); v.append(c + unit[(k + 1) % segments] * r)
        }
        if i > 0 {
            let a = SIMD2<Float>(Float(pts[i - 1].p.x), Float(pts[i - 1].p.y)), ra = Float(radii[i - 1])
            let d = c - a, len = simd_length(d)
            if len > 1e-6 {
                let n = SIMD2(-d.y, d.x) / len
                let a0 = a - n * ra, a1 = a + n * ra, b0 = c - n * r, b1 = c + n * r
                v += [a0, b0, b1, a0, b1, a1]
            }
        }
    }
    return v
}

/// Triangles for a stroke, same filled shape as strokeMeshCircles at a fraction of the vertices:
/// a quad per segment; at gentle bends two bevel triangles close the joint (the only difference
/// from a round join is a sliver of r(1-cos(theta/2)), kept under 0.25 px on screen); full
/// circles at the ends and wherever that sliver would show, with segments sized to the on-screen radius
/// (`pxPerUnit` = device pixels per canvas unit, with headroom for zooming in).
func strokeMesh(_ pts: [StrokePoint], radii: [Double], pxPerUnit: Double = 8) -> [SIMD2<Float>] {
    var v: [SIMD2<Float>] = []
    guard !pts.isEmpty else { return v }
    v.reserveCapacity(pts.count * 14 + 120)
    func P(_ i: Int) -> SIMD2<Float> { SIMD2(Float(pts[i].p.x), Float(pts[i].p.y)) }
    func circle(_ c: SIMD2<Float>, _ r: Float) {
        let segs = min(max(Int((Double(r) * pxPerUnit * 1.2).rounded(.up)), 8), 32)
        var prev = c + SIMD2(r, 0)
        for k in 1...segs {
            let a = Float(k) / Float(segs) * 2 * .pi
            let q = c + SIMD2(cos(a), sin(a)) * r
            v.append(c); v.append(prev); v.append(q)
            prev = q
        }
    }
    // Segment normals (nil for zero-length segments).
    var normals: [SIMD2<Float>?] = [nil]
    for i in 1..<pts.count {
        let d = P(i) - P(i - 1), len = simd_length(d)
        normals.append(len > 1e-6 ? SIMD2(-d.y, d.x) / len : nil)
    }
    circle(P(0), Float(radii[0]))
    var lastN: SIMD2<Float>?  // normal of the previous non-degenerate segment
    for i in 1..<pts.count {
        let a = P(i - 1), b = P(i), ra = Float(radii[i - 1]), rb = Float(radii[i])
        guard let n = normals[i] else { continue }
        // Joint at point i-1 between the previous segment and this one.
        if let pn = lastN {
            // A bevel misses a sliver of r(1 - cos(theta/2)) on the outside of the turn; round the
            // joint when that would exceed a quarter pixel on screen.
            // Also round it where the radius changes fast (pressure rising into a slow corner):
            // the circle at the wider end bulges past the tapering quads.
            let cosHalf = sqrt(max(0, (1 + Double(simd_dot(pn, n))) / 2))
            let dr = max(abs(radii[i - 1] - radii[max(i - 2, 0)]), abs(radii[i] - radii[i - 1]))
            if Double(ra) * pxPerUnit * (1 - cosHalf) > 0.25 || dr * pxPerUnit > 0.25 {
                circle(a, ra)
            } else {                      // gentle bend: bevel both sides
                v += [a, a + pn * ra, a + n * ra, a, a - pn * ra, a - n * ra]
            }
        }
        let a0 = a - n * ra, a1 = a + n * ra, b0 = b - n * rb, b1 = b + n * rb
        v += [a0, b0, b1, a0, b1, a1]
        lastN = n
    }
    if pts.count > 1 { circle(P(pts.count - 1), Float(radii[pts.count - 1])) }
    return v
}

final class Renderer {
    let device: MTLDevice
    let queue: MTLCommandQueue
    private let strokePSO: MTLRenderPipelineState
    private let bgPSO: MTLRenderPipelineState
    private let stencilOnce: MTLDepthStencilState
    static let sampleCount = 4

    let colorFormat: MTLPixelFormat = .bgra8Unorm
    let stencilFormat: MTLPixelFormat = .stencil8

    convenience init?(view: MTKView) {
        guard let device = view.device ?? MTLCreateSystemDefaultDevice() else { return nil }
        self.init(device: device)
        view.device = device
        view.colorPixelFormat = colorFormat
        view.depthStencilPixelFormat = stencilFormat
        view.sampleCount = Self.sampleCount
    }

    init?(device: MTLDevice) {
        guard let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        do {
            let lib = try device.makeLibrary(source: shaderSource, options: nil)
            func pso(_ vfn: String, _ ffn: String, blend: Bool) throws -> MTLRenderPipelineState {
                let d = MTLRenderPipelineDescriptor()
                d.vertexFunction = lib.makeFunction(name: vfn)
                d.fragmentFunction = lib.makeFunction(name: ffn)
                d.rasterSampleCount = Self.sampleCount
                d.colorAttachments[0].pixelFormat = .bgra8Unorm
                d.stencilAttachmentPixelFormat = .stencil8
                if blend {
                    let c = d.colorAttachments[0]!
                    c.isBlendingEnabled = true
                    c.sourceRGBBlendFactor = .one; c.sourceAlphaBlendFactor = .one
                    c.destinationRGBBlendFactor = .oneMinusSourceAlpha; c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
                }
                return try device.makeRenderPipelineState(descriptor: d)
            }
            strokePSO = try pso("stroke_v", "stroke_f", blend: true)
            bgPSO = try pso("bg_v", "bg_f", blend: false)
        } catch {
            NSLog("trackpad-draw: Metal setup failed: \(error)")
            return nil
        }
        let s = MTLStencilDescriptor()
        s.stencilCompareFunction = .notEqual   // draw where this stroke hasn't drawn yet
        s.depthStencilPassOperation = .replace
        let ds = MTLDepthStencilDescriptor()
        ds.frontFaceStencil = s; ds.backFaceStencil = s
        stencilOnce = device.makeDepthStencilState(descriptor: ds)!
    }

    func makeMesh(_ verts: [SIMD2<Float>]) -> Mesh {
        guard !verts.isEmpty else { return Mesh() }
        return Mesh(buffer: device.makeBuffer(bytes: verts, length: verts.count * MemoryLayout<SIMD2<Float>>.stride, options: .storageModeShared), count: verts.count)
    }

    struct DrawItem { var mesh: Mesh; var verts: [SIMD2<Float>]?; var color: SIMD4<Float> }

    /// `items` in paint order. `verts` (instead of a mesh) is for small per-frame geometry.
    /// Time the last frame waited for a drawable from the window server (not our work).
    private(set) var lastDrawableWaitMs = 0.0
    func render(in view: MTKView, visible: CGRect, background: Int, spacing: Double, pxPerUnit: Double, page: CGRect? = nil,
                items: [DrawItem], presented: ((Double) -> Void)?, gpuMs: ((Double) -> Void)? = nil) {
        let w0 = CACurrentMediaTime()
        guard let rpd = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let cb = queue.makeCommandBuffer() else { return }
        lastDrawableWaitMs = (CACurrentMediaTime() - w0) * 1000
        encode(cb, rpd, visible: visible, background: background, spacing: spacing, pxPerUnit: pxPerUnit, page: page, items: items)
        if let presented { drawable.addPresentedHandler { d in presented(d.presentedTime) } }
        if let gpuMs { cb.addCompletedHandler { cb in gpuMs((cb.gpuEndTime - cb.gpuStartTime) * 1000) } }
        if view.presentsWithTransaction {
            // Shown in the same Core Animation transaction as the window's other changes (the overview's handoff).
            cb.commit(); cb.waitUntilScheduled(); drawable.present()
        } else {
            cb.present(drawable)
            cb.commit()
        }
    }

    func encode(_ cb: MTLCommandBuffer, _ rpd: MTLRenderPassDescriptor, visible: CGRect, background: Int, spacing: Double,
                pxPerUnit: Double, page: CGRect? = nil, items: [DrawItem]) {
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }
        var xf = SIMD4<Float>(Float(2 / visible.width), Float(2 / visible.height),
                              Float(-1 - 2 * visible.minX / visible.width), Float(-1 - 2 * visible.minY / visible.height))
        enc.setRenderPipelineState(bgPSO)
        var bg: [Float] = [Float(background), Float(spacing), Float(pxPerUnit), Float(page?.width ?? 0), Float(page?.maxY ?? 0), page == nil ? 0 : 1, 0, 0]
        enc.setVertexBytes(&xf, length: 16, index: 1)
        enc.setFragmentBytes(&bg, length: 32, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        enc.setRenderPipelineState(strokePSO)
        enc.setDepthStencilState(stencilOnce)
        enc.setVertexBytes(&xf, length: 16, index: 1)
        // Stencil refs 1...255 cycle; a stroke only collides with the one 255 strokes earlier.
        for (i, item) in items.enumerated() {
            enc.setStencilReferenceValue(UInt32(i % 255 + 1))
            var c = item.color
            enc.setFragmentBytes(&c, length: 16, index: 0)
            if let b = item.mesh.buffer {
                enc.setVertexBuffer(b, offset: 0, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: item.mesh.count)
            } else if let v = item.verts, !v.isEmpty {
                let len = v.count * MemoryLayout<SIMD2<Float>>.stride
                if len <= 4096 {
                    enc.setVertexBytes(v, length: len, index: 0)
                } else if let b = device.makeBuffer(bytes: v, length: len, options: .storageModeShared) {
                    enc.setVertexBuffer(b, offset: 0, index: 0)
                } else { continue }
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: v.count)
            }
        }
        enc.endEncoding()
    }
}
