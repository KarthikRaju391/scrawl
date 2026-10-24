// The reduced stroke mesh must draw the same pixels as the reference (circle at every point).
import CoreGraphics
import Foundation
import Metal
import ImageIO

func meshEquivalence(_ check: (Bool, String) -> Void, strokesPath: String?) {
    guard let path = strokesPath, let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
    let dev = MTLCreateSystemDefaultDevice()!, r = Renderer(device: dev)!
    let W = 1600, H = 1000
    func render(_ items: [Renderer.DrawItem]) -> [UInt8] {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: W, height: H, mipmapped: false)
        d.usage = .renderTarget; d.storageMode = .shared
        let out = dev.makeTexture(descriptor: d)!
        let md = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: W, height: H, mipmapped: false)
        md.usage = .renderTarget; md.storageMode = .private; md.textureType = .type2DMultisample; md.sampleCount = Renderer.sampleCount
        let sd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .stencil8, width: W, height: H, mipmapped: false)
        sd.usage = .renderTarget; sd.storageMode = .private; sd.textureType = .type2DMultisample; sd.sampleCount = Renderer.sampleCount
        let p = MTLRenderPassDescriptor()
        p.colorAttachments[0].texture = dev.makeTexture(descriptor: md); p.colorAttachments[0].resolveTexture = out
        p.colorAttachments[0].loadAction = .clear; p.colorAttachments[0].storeAction = .multisampleResolve
        p.stencilAttachment.texture = dev.makeTexture(descriptor: sd); p.stencilAttachment.loadAction = .clear
        let cb = r.queue.makeCommandBuffer()!
        r.encode(cb, p, visible: CGRect(x: 0, y: 0, width: W, height: H), background: 0, spacing: 48, pxPerUnit: 1, items: items)
        cb.commit(); cb.waitUntilCompleted()
        var px = [UInt8](repeating: 0, count: W * H * 4)
        out.getBytes(&px, bytesPerRow: W * 4, from: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0)
        return px
    }
    // Recorded strokes, laid out in a grid, each scaled to ~180 px, interpolated like the app.
    var shapes: [[StrokePoint]] = []
    for line in text.split(separator: "\n") {
        guard let s = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              s["committed"] as? Bool == true, let sm = s["samples"] as? [[Double]], sm.count > 2 else { continue }
        let minX = sm.map { $0[1] }.min()!, minY = sm.map { $0[2] }.min()!
        let w = max(sm.map { $0[1] }.max()! - minX, sm.map { $0[2] }.max()! - minY, 1)
        let k = shapes.count
        let ox = Double(k % 8) * 195 + 10, oy = Double(k / 8) * 240 + 20
        let raw = sm.map { StrokePoint(p: CGPoint(x: ox + ($0[1] - minX) / w * 180, y: oy + ($0[2] - minY) / w * 180), pressure: $0[7]) }
        shapes.append(catmullRom(raw, maxStep: 3))   // 1.5 pt at 2x backing
    }
    for (tool, size) in [(ToolKind.pen, 6.0), (.marker, 26.0), (.highlighter, 40.0)] {
        var refItems: [Renderer.DrawItem] = [], newItems: [Renderer.DrawItem] = []
        var vRef = 0, vNew = 0
        let color = SIMD4<Float>(0, 0, 0, Float(Brush.of(tool).alpha))
        for sh in shapes {
            let radii = strokeRadii(sh, size: size, brush: Brush.of(tool))
            let a = strokeMeshCircles(sh, radii: radii), b = strokeMesh(sh, radii: radii, pxPerUnit: 1)
            vRef += a.count; vNew += b.count
            refItems.append(.init(mesh: r.makeMesh(a), verts: nil, color: color))
            newItems.append(.init(mesh: r.makeMesh(b), verts: nil, color: color))
        }
        let pa = render(refItems), pb = render(newItems)
        var ink = 0, diff = 0, maxD = 0
        for i in stride(from: 0, to: pa.count, by: 4) {
            if pa[i] < 250 || pb[i] < 250 { ink += 1 }
            let d = abs(Int(pa[i]) - Int(pb[i]))
            maxD = max(maxD, d)
            if d > 64 { diff += 1 }
        }
        let frac = Double(diff) / Double(max(ink, 1))
        if let dir = ProcessInfo.processInfo.environment["DIFF_DIR"] {  // red = only in reference, blue = only in new
            var img = [UInt8](repeating: 255, count: W * H * 4)
            var where_: [String] = []
            for i in stride(from: 0, to: pa.count, by: 4) {
                let a = Int(pa[i]), b = Int(pb[i])
                if a < 250 || b < 250 { img[i] = 200; img[i+1] = 200; img[i+2] = 200 }
                if abs(a - b) > 64 {
                    if a < b { img[i] = 255; img[i+1] = 0; img[i+2] = 0 } else { img[i] = 0; img[i+1] = 0; img[i+2] = 255 }
                    if where_.count < 12 { where_.append("(\(i / 4 % W),\(i / 4 / W))") }
                }
            }
            print("  \(tool.rawValue) diff pixels at:", where_.joined(separator: " "))
            let ctx = CGContext(data: &img, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            let url = URL(fileURLWithPath: dir + "/diff-\(tool.rawValue).png") as CFURL
            let dst = CGImageDestinationCreateWithURL(url, "public.png" as CFString, 1, nil)!
            CGImageDestinationAddImage(dst, ctx.makeImage()!, nil); CGImageDestinationFinalize(dst)
        }
        check(frac < 0.002, String(format: "%@ size %.0f px: reduced mesh matches reference, %d of %d ink pixels differ by >25%% (%.3f%%), max diff %d/255; vertices %d -> %d (%.1fx fewer)",
                                  tool.rawValue, size, diff, ink, frac * 100, maxD, vRef, vNew, Double(vRef) / Double(vNew)))
    }
}
