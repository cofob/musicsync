import Foundation

/// MilkDrop's motion vectors (`mv_x` × `mv_y` short lines), as butterchurn's `drawMotionVectors`: each starts on a
/// grid point and points along where the warp mesh moves that spot.
enum MotionVectors {
    static let maxX = 64, maxY = 48

    /// `values`: the (mixed) per-frame values; `mesh`: this frame's warp mesh.
    static func add(to batch: GeometryBatch, values: [String: Double], mesh: WarpMesh, frame: FrameGlobals) {
        func v(_ name: String) -> Double { values[name] ?? 0 }
        let alpha = v("mv_a")
        guard alpha > 0.001, var nx = v("mv_x").floorInt, var ny = v("mv_y").floorInt, nx > 0, ny > 0 else { return }
        var fx = v("mv_x") - Double(nx), fy = v("mv_y") - Double(ny)
        if nx > maxX { (nx, fx) = (maxX, 0) }
        if ny > maxY { (ny, fy) = (maxY, 0) }
        let dx = v("mv_dx"), dy = v("mv_dy"), length = v("mv_l"), minimum = 1 / Double(frame.pixels.x)
        let color = SIMD4(Float(v("mv_r")), Float(v("mv_g")), Float(v("mv_b")), Float(alpha))
        let start = batch.vertices.count
        for row in 0..<ny {
            let y = (Double(row) + 0.25) / (Double(ny) + fy + 0.25 - 1) - dy
            guard y > 1e-4, y < 0.9999 else { continue }
            for col in 0..<nx {
                let x = (Double(col) + 0.25) / (Double(nx) + fx + 0.25 - 1) + dx
                guard x > 1e-4, x < 0.9999 else { continue }
                let to = direction(mesh, x, y)
                var mx = (to.x - x) * length, my = (to.y - y) * length
                let d = (mx * mx + my * my).squareRoot()
                if d < minimum, d > 1e-8 {
                    mx *= minimum / d
                    my *= minimum / d
                } else {
                    mx = minimum  // as butterchurn: sets x twice and leaves y
                }
                batch.append(GeometryVertex(position: SIMD2(Float(2 * x - 1), Float(2 * y - 1)), color: color))
                batch.append(GeometryVertex(position: SIMD2(Float(2 * (x + mx) - 1), Float(2 * (y + my) - 1)), color: color))
            }
        }
        batch.draw(.line, from: start, additive: false)
    }

    /// Butterchurn's `getMotionDir`: the mesh's warped uv at (x, y), bilinear, v turned to y.
    private static func direction(_ mesh: WarpMesh, _ x: Double, _ y: Double) -> SIMD2<Double> {
        let (w, h) = (mesh.size.x, mesh.size.y)
        let row = Int(y * Double(h)), fy = y * Double(h) - Double(row)
        let col = Int(x * Double(w)), fx = x * Double(w) - Double(col)
        let stride = w + 1
        func uv(_ r: Int, _ c: Int) -> SIMD2<Double> {
            let p = mesh.uvs[min(r * stride + c, mesh.uvs.count - 1)]
            return SIMD2(Double(p.x), Double(p.y))
        }
        let s = uv(row, col) * (1 - fx) * (1 - fy) + uv(row, col + 1) * fx * (1 - fy)
            + uv(row + 1, col) * (1 - fx) * fy + uv(row + 1, col + 1) * fx * fy
        return SIMD2(s.x, 1 - s.y)
    }
}
