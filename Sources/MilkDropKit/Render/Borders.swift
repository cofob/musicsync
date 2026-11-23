/// MilkDrop's darken center (a faint dark diamond in the middle) and the outer and inner borders, as butterchurn's
/// `drawDarkenCenter` and `drawBorder`.
enum Borders {
    /// `values`: the (mixed) per-frame values.
    static func add(to batch: GeometryBatch, values: [String: Double], frame: FrameGlobals) {
        func v(_ name: String) -> Double { values[name] ?? 0 }
        if v("darken_center") != 0 { darkenCenter(batch, aspectY: Float(frame.aspect.y)) }
        border(batch, color: [v("ob_r"), v("ob_g"), v("ob_b"), v("ob_a")], size: v("ob_size"), inside: 0)
        border(batch, color: [v("ib_r"), v("ib_g"), v("ib_b"), v("ib_a")], size: v("ib_size"), inside: v("ob_size"))
    }

    /// A fan from the center (alpha 3/32) to four points 0.05 away (alpha 0).
    private static func darkenCenter(_ batch: GeometryBatch, aspectY: Float) {
        let rim: [SIMD2<Float>] = [[-0.05 * aspectY, 0], [0, -0.05], [0.05 * aspectY, 0], [0, 0.05], [-0.05 * aspectY, 0]]
        let start = batch.vertices.count
        for i in 0..<rim.count - 1 {
            batch.append(GeometryVertex(position: .zero, color: [0, 0, 0, 3 / 32]))
            batch.append(GeometryVertex(position: rim[i], color: .zero))
            batch.append(GeometryVertex(position: rim[i + 1], color: .zero))
        }
        batch.draw(.triangle, from: start, additive: false)
    }

    /// A frame `size` wide (in 0…1 of the picture) that starts `inside` from the edge.
    private static func border(_ batch: GeometryBatch, color: SIMD4<Double>, size: Double, inside: Double) {
        guard size > 0, color.w > 0 else { return }
        let s = Float(inside / 2), r = Float(size / 2) + s
        let a = 2 * s, o = 2 * r
        let c = SIMD4<Float>(color)
        let quads: [[SIMD2<Float>]] = [
            [[-1 + a, -1 + o], [-1 + a, 1 - o], [-1 + o, 1 - o], [-1 + o, -1 + o]],  // left
            [[1 - a, -1 + o], [1 - a, 1 - o], [1 - o, 1 - o], [1 - o, -1 + o]],  // right
            [[-1 + a, -1 + a], [-1 + a, o - 1], [1 - a, o - 1], [1 - a, -1 + a]],  // bottom
            [[-1 + a, 1 - a], [-1 + a, 1 - o], [1 - a, 1 - o], [1 - a, 1 - a]],  // top
        ]
        let start = batch.vertices.count
        for q in quads {
            for i in [0, 1, 3, 1, 2, 3] { batch.append(GeometryVertex(position: q[i], color: c)) }
        }
        batch.draw(.triangle, from: start, additive: false)
    }
}
