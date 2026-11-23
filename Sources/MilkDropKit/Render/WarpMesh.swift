import Foundation

/// The warp mesh: per vertex, where the last frame is sampled from (zoom, rotation, stretch, warp waves, per-pixel
/// code), as butterchurn's `runPixelEquations`. Vertices go out as `MDVertex` (12 floats) for the warp shader.
struct WarpMesh {
    static let floatsPerVertex = 12
    let size: SIMD2<Int>
    /// Warped uv per vertex; while blending, already mixed with the old preset's.
    private(set) var uvs: [SIMD2<Float>]
    /// Per vertex: 1, or while blending the new preset's share (vertex alpha of its warp pass).
    private(set) var alphas: [Float]

    init(size: SIMD2<Int>) {
        self.size = size
        let count = (size.x + 1) * (size.y + 1)
        uvs = Array(repeating: .zero, count: count)
        alphas = Array(repeating: 1, count: count)
    }

    /// Computes the uvs of `eq` (its per-frame `values`); runs its per-pixel code when it has any.
    /// `blend`: this is the old preset; mix its uvs into those there (the new preset's) by the new one's share.
    mutating func update(_ eq: PresetEquations, time: Double, aspect: SIMD2<Double>, blend: (BlendPattern, Float)? = nil) {
        let v = eq.values, scope = eq.scope
        let (w, h) = (size.x, size.y), (ax, ay) = (aspect.x, aspect.y)
        let t = time * (v["warpanimspeed"] ?? 1), scale = 1 / (v["warpscale"] ?? 1)
        let f0 = 11.68 + 4 * cos(1.413 * t + 10), f1 = 8.77 + 3 * cos(1.113 * t + 7)
        let f2 = 10.54 + 3 * cos(1.233 * t + 3), f3 = 11.49 + 4 * cos(0.933 * t + 5)
        let names = ["zoom", "zoomexp", "rot", "warp", "cx", "cy", "dx", "dy", "sx", "sy"]
        let slots = names.map(scope.slot), frame = names.map { v[$0] ?? 0 }
        let xs = scope.slot("x"), ys = scope.slot("y"), rads = scope.slot("rad"), angs = scope.slot("ang")
        let runs = !eq.preset.pixelCode.isEmpty
        var i = 0
        for row in 0...h {
            for col in 0...w {
                let px = Double(col) / Double(w) * 2 - 1, py = Double(row) / Double(h) * 2 - 1
                let rad = (px * px * ax * ax + py * py * ay * ay).squareRoot()
                var p = frame
                if runs {
                    var ang = atan2(py * ay, px * ax)
                    if ang < 0 { ang += 2 * .pi }
                    if row * 2 == h && col * 2 == w { ang = 0 }
                    scope[xs] = 0.5 * px * ax + 0.5
                    scope[ys] = -0.5 * py * ay + 0.5
                    scope[rads] = rad
                    scope[angs] = ang
                    for (slot, value) in zip(slots, frame) { scope[slot] = value }
                    scope.run(eq.pixel)
                    p = slots.map { scope[$0] }
                }
                let (zoom, zoomexp, rot, warp, cx, cy, dx, dy, sx, sy) = (p[0], p[1], p[2], p[3], p[4], p[5], p[6], p[7], p[8], p[9])
                let z = 1 / pow(zoom, pow(zoomexp, 2 * rad - 1))
                var u = 0.5 * px * ax * z + 0.5, vv = -0.5 * py * ay * z + 0.5
                u = (u - cx) / sx + cx
                vv = (vv - cy) / sy + cy
                if warp != 0 {
                    u += 0.0035 * warp * sin(0.333 * t + scale * (px * f0 - py * f3))
                    vv += 0.0035 * warp * cos(0.375 * t - scale * (px * f2 + py * f1))
                    u += 0.0035 * warp * cos(0.753 * t - scale * (px * f1 - py * f2))
                    vv += 0.0035 * warp * sin(0.825 * t + scale * (px * f0 + py * f3))
                }
                let du = u - cx, dv = vv - cy, c = cos(rot), s = sin(rot)
                u = du * c - dv * s + cx
                vv = du * s + dv * c + cy
                u = (u - dx - 0.5) / ax + 0.5
                vv = (vv - dy - 0.5) / ay + 0.5
                let uv = SIMD2(Float(u), Float(vv))
                if let (pattern, progress) = blend {
                    let share = pattern.newShare(i, progress: progress)
                    uvs[i] = uvs[i] * share + uv * (1 - share)
                    alphas[i] = share
                } else {
                    uvs[i] = uv
                    alphas[i] = 1
                }
                i += 1
            }
        }
        if runs { eq.endPixels() }
    }

    /// Triangle vertices for the warp pass (two per cell), clip y flipped for the offscreen target.
    /// `alpha`: vertex alpha per vertex, or 1 everywhere.
    func vertices(aspect: SIMD2<Double>, alpha: Bool) -> [Float] {
        var out: [Float] = []
        out.reserveCapacity(size.x * size.y * 6 * Self.floatsPerVertex)
        let stride = size.x + 1
        func vertex(_ col: Int, _ row: Int) {
            let i = row * stride + col
            let px = Float(col) / Float(size.x) * 2 - 1, py = 1 - Float(row) / Float(size.y) * 2
            let x = px * Float(aspect.x), y = py * Float(aspect.y)
            var ang = atan2(y, x)
            if ang < 0 { ang += 2 * .pi }
            out += [px, -py, uvs[i].x, uvs[i].y, px * 0.5 + 0.5, py * 0.5 + 0.5, (x * x + y * y).squareRoot(), ang,
                    1, 1, 1, alpha ? alphas[i] : 1]
        }
        for row in 0..<size.y {
            for col in 0..<size.x {
                vertex(col, row); vertex(col, row + 1); vertex(col + 1, row)
                vertex(col, row + 1); vertex(col + 1, row + 1); vertex(col + 1, row)
            }
        }
        return out
    }
}
