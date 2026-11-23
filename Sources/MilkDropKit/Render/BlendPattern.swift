import Foundation

/// How a new preset replaces the old one across the screen while they blend: per mesh vertex, the new preset's
/// share is `clamp(a * progress + c, 0, 1)`. One of butterchurn's patterns: a sweep, plasma, or a circle in or out.
struct BlendPattern {
    private(set) var a: [Float], c: [Float]
    private let width: Int, height: Int

    /// `width`×`height` mesh cells, so (width + 1)×(height + 1) vertices.
    init(width: Int, height: Int, aspect: SIMD2<Float>, random: () -> Double = { .random(in: 0..<1) }) {
        self.width = width
        self.height = height
        let count = (width + 1) * (height + 1)
        a = Array(repeating: 1, count: count)
        c = Array(repeating: 0, count: count)
        let ax = Double(aspect.x), ay = Double(aspect.y)
        switch 1 + Int(3 * random()) {
        case 1:
            let angle = 6.28 * random(), cosA = cos(angle), sinA = sin(angle), band = 0.1 + 0.2 * random(), inv = 1 / band
            fill { x, y in
                let d = ((x * ax - 0.5) * cosA + (y * ay - 0.5) * sinA + 0.5 - 0.5) / 2.0.squareRoot() + 0.5
                return (inv * (1 + band), inv * d - inv)
            }
        case 2:
            let band = 0.12 + 0.13 * random(), inv = 1 / band
            var plasma = Array(repeating: 0.0, count: count)
            for corner in [0, width, height * (width + 1), height * (width + 1) + width] { plasma[corner] = random() }
            Self.plasma(&plasma, 0, width, 0, height, 0.25, stride: width + 1, aspect: (ax, ay), random: random)
            let lo = plasma.min() ?? 0, hi = plasma.max() ?? 1, scale = hi > lo ? 1 / (hi - lo) : 1
            var i = 0
            fill { _, _ in
                defer { i += 1 }
                return (inv * (1 + band), inv * (plasma[i] - lo) * scale - inv)
            }
        default:
            let band = 0.02 + 0.14 * random() + 0.34 * random(), inv = 1 / band, inward = random() < 0.5
            fill { x, y in
                let dx = (x - 0.5) * ax, dy = (y - 0.5) * ay
                let d = 1.41421 * (dx * dx + dy * dy).squareRoot()
                return (inv * (1 + band), inv * (inward ? 1 - d : d) - inv)
            }
        }
    }

    func newShare(_ vertex: Int, progress: Float) -> Float { min(max(a[vertex] * progress + c[vertex], 0), 1) }

    /// Calls `value(x, y)` (0…1 across the mesh) for each vertex, rows first.
    private mutating func fill(_ value: (Double, Double) -> (Double, Double)) {
        var i = 0
        for row in 0...height {
            for col in 0...width {
                let (va, vc) = value(Double(col) / Double(width), Double(row) / Double(height))
                a[i] = Float(va)
                c[i] = Float(vc)
                i += 1
            }
        }
    }

    /// Diamond-square noise between the four corners of the cell range, as butterchurn's `genPlasma`.
    private static func plasma(_ v: inout [Double], _ x0: Int, _ x1: Int, _ y0: Int, _ y1: Int, _ amount: Double,
                               stride w: Int, aspect: (Double, Double), random: () -> Double) {
        let mx = (x0 + x1) / 2, my = (y0 + y1) / 2
        var a = v[y0 * w + x0], b = v[y0 * w + x1], c = v[y1 * w + x0], d = v[y1 * w + x1]
        func jitter(_ scale: Double) -> Double { (2 * random() - 1) * amount * scale }
        if y1 - y0 >= 2 {
            if x0 == 0 { v[my * w + x0] = 0.5 * (a + c) + jitter(aspect.1) }
            v[my * w + x1] = 0.5 * (b + d) + jitter(aspect.1)
        }
        if x1 - x0 >= 2 {
            if y0 == 0 { v[y0 * w + mx] = 0.5 * (a + b) + jitter(aspect.0) }
            v[y1 * w + mx] = 0.5 * (c + d) + jitter(aspect.0)
        }
        guard y1 - y0 >= 2, x1 - x0 >= 2 else { return }
        a = v[my * w + x0]; b = v[my * w + x1]; c = v[y0 * w + mx]; d = v[y1 * w + mx]
        v[my * w + mx] = 0.25 * (c + d + a + b) + jitter(1)
        plasma(&v, x0, mx, y0, my, 0.5 * amount, stride: w, aspect: aspect, random: random)
        plasma(&v, mx, x1, y0, my, 0.5 * amount, stride: w, aspect: aspect, random: random)
        plasma(&v, x0, mx, my, y1, 0.5 * amount, stride: w, aspect: aspect, random: random)
        plasma(&v, mx, x1, my, y1, 0.5 * amount, stride: w, aspect: aspect, random: random)
    }
}
