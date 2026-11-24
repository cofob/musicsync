import Foundation

/// One custom shape of a preset (`shapecode_N`), as butterchurn's `drawCustomShape`: per-frame code runs once per
/// instance, each instance starts again from the file's position, size and colors, and the other variables carry
/// over from instance to instance and frame to frame. Drawn as a triangle fan with an optional border line.
final class CustomShape {
    /// Variables read after per-frame code; all but `sides` come back to the file values before each instance.
    private enum Key: Int, CaseIterable {
        case sides, x, y, rad, ang, r, g, b, a, r2, g2, b2, a2, border_r, border_g, border_b, border_a
        case thickoutline, textured, tex_zoom, tex_ang, additive
    }

    let eq: ElementEquations
    private let frameCode: EELProgram
    private let slots: [Int]
    private let resets: [(slot: Int, value: Double)]
    private let instanceSlot: Int, numInstSlot: Int
    private var ring = [GeometryVertex](repeating: GeometryVertex(position: .zero, color: .zero), count: 102)

    init(_ shape: Preset.Shape, globals: EELGlobals, frame: FrameGlobals, random: @escaping () -> Double) throws {
        eq = try ElementEquations(values: shape.values, initCode: shape.initCode, globals: globals, frame: frame, random: random)
        let scope = eq.scope
        frameCode = scope.compileOrSkip(shape.frameCode)
        slots = Key.allCases.map { scope.slot("\($0)") }
        resets = Key.allCases.dropFirst().map { (scope.slot("\($0)"), shape.values["\($0)"] ?? 0) }
        instanceSlot = scope.slot("instance")
        numInstSlot = scope.slot("num_inst")
    }

    /// Adds all instances. `q`: the main preset's; `wrap`: its `wrap` (textured shapes); `alpha`: the preset's share.
    func add(to batch: GeometryBatch, q: [Double], wrap: Bool, frame: FrameGlobals, alpha: Double) {
        eq.beginFrame(q: q, frame: frame)
        let scope = eq.scope
        guard let count = scope[numInstSlot].clamped(1, 1024).floorInt else { return }
        let aspect = frame.aspect.y
        for n in 0..<count {
            scope[instanceSlot] = Double(n)
            for (slot, value) in resets { scope[slot] = value }
            scope.run(frameCode)
            let v = { (key: Key) in scope[self.slots[key.rawValue]] }
            guard let sides = v(.sides).clamped(3, 100).floorInt else { continue }
            let rad = v(.rad), ang = v(.ang), cx = 2 * v(.x) - 1, cy = -2 * v(.y) + 1
            let textured = abs(v(.textured)) >= 1, thick = abs(v(.thickoutline)) >= 1, additive = abs(v(.additive)) >= 1
            let border = SIMD4(Float(v(.border_r)), Float(v(.border_g)), Float(v(.border_b)), Float(v(.border_a) * alpha))
            let texZoom = v(.tex_zoom), texAng = v(.tex_ang)
            let outer = SIMD4(Float(v(.r2)), Float(v(.g2)), Float(v(.b2)), Float(v(.a2) * alpha))
            ring[0] = GeometryVertex(position: SIMD2(Float(cx), Float(cy)), uv: SIMD2(0.5, 0.5),
                                     color: SIMD4(Float(v(.r)), Float(v(.g)), Float(v(.b)), Float(v(.a) * alpha)))
            for k in 1...sides + 1 {
                let t = 2 * (Double(k - 1) / Double(sides)) * .pi, p = t + ang + 0.25 * .pi
                var uv = SIMD2<Float>(0.5, 0.5)
                if textured {
                    let u = t + texAng + 0.25 * .pi
                    uv = SIMD2(Float(0.5 + 0.5 * cos(u) / texZoom * aspect), Float(0.5 + 0.5 * sin(u) / texZoom))
                }
                ring[k] = GeometryVertex(position: SIMD2(Float(cx + rad * cos(p) * aspect), Float(cy + rad * sin(p))), uv: uv, color: outer)
            }
            let start = batch.vertices.count
            for k in 1...sides {
                batch.append(ring[0]); batch.append(ring[k]); batch.append(ring[k + 1])
            }
            batch.draw(.triangle, from: start, additive: additive, sampling: textured ? (wrap ? .wrap : .clamp) : .none)
            if border.w > 0 {
                let start = batch.vertices.count
                for k in 1...sides + 1 { batch.append(GeometryVertex(position: ring[k].position, color: border)) }
                // The fan's blending stays on. Butterchurn takes the border's thickOffset from the wrong program,
                // so the four thick passes do not move.
                batch.draw(.lineStrip, from: start, additive: additive, thick: thick ? .zero : nil)
            }
        }
    }
}
