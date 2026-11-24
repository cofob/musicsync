import Foundation

/// What every equation block sees each frame besides the preset's own variables.
struct FrameGlobals {
    var time = 0.0, fps = 60.0, frame = 0.0
    var bass = 1.0, mid = 1.0, treb = 1.0, bassAtt = 1.0, midAtt = 1.0, trebAtt = 1.0
    var meshSize = SIMD2<Int>(48, 36)
    /// Butterchurn's `aspectx`/`aspecty` (≤ 1); presets get their inverses under these names.
    var aspect = SIMD2<Double>(1, 1)
    var pixels = SIMD2<Int>(1, 1)

    var named: [(String, Double)] {
        [("time", time), ("fps", fps), ("frame", frame), ("bass", bass), ("mid", mid), ("treb", treb),
         ("bass_att", bassAtt), ("mid_att", midAtt), ("treb_att", trebAtt),
         ("meshx", Double(meshSize.x)), ("meshy", Double(meshSize.y)), ("aspectx", 1 / aspect.x), ("aspecty", 1 / aspect.y),
         ("pixelsx", Double(pixels.x)), ("pixelsy", Double(pixels.y))]
    }
}

/// The main preset's init, per-frame and per-pixel code over one variable scope, with butterchurn's lifetimes:
/// the file's values come back every frame, q1…q32 come back to their values after init, the preset's own
/// variables carry over, and per-pixel changes do not reach the next frame.
final class PresetEquations {
    static let qNames = (1...32).map { "q\($0)" }
    let preset: Preset
    let scope: EELScope
    let memory = EELMemory()
    let pixel: EELProgram
    private let frame: EELProgram
    private let base: [(slot: Int, value: Double)]
    private let qSlots: [Int]
    private var qInit: [Double]
    /// q1…q32 after this frame's per-frame code, for waves, shapes and shaders.
    private(set) var q: [Double]
    /// The variables after per-frame code, read by name; per-pixel code changes the scope but not these.
    private(set) var values: [String: Double] = [:]
    private var valueSlots: [(String, Int)] = []
    private var afterFrame: [Double] = []

    init(_ preset: Preset, globals: EELGlobals, frame now: FrameGlobals, random: @escaping () -> Double = { .random(in: 0..<1) }) throws {
        self.preset = preset
        let scope = EELScope(memory: memory, globals: globals, random: random)
        self.scope = scope
        let initCode = scope.compileOrSkip(preset.initCode)
        frame = scope.compileOrSkip(preset.frameCode)
        pixel = scope.compileOrSkip(preset.pixelCode)
        base = preset.values.map { (scope.slot($0.key), $0.value) }
        qSlots = Self.qNames.map(scope.slot)
        valueSlots = (Set(preset.values.keys).union(PresetKeys.preset.keys).union(Self.qNames).union(["old_wave_mode"]))
            .map { ($0, scope.slot($0)) }
        qInit = Array(repeating: 0, count: 32)
        q = qInit
        setBase(now)
        scope.run(initCode)
        qInit = qSlots.map { scope[$0] }
        runFrame(now)
    }

    /// Runs per-frame code; `values` and `q` then hold its results.
    func runFrame(_ now: FrameGlobals) {
        setBase(now)
        for (slot, value) in zip(qSlots, qInit) { scope[slot] = value }
        scope.run(frame)
        q = qSlots.map { scope[$0] }
        values = Dictionary(uniqueKeysWithValues: valueSlots.map { ($0.0, scope[$0.1]) })
        afterFrame = scope.snapshot()
    }

    /// Undoes what per-pixel code changed, so the next frame starts from the per-frame results.
    func endPixels() { scope.restore(afterFrame) }

    private func setBase(_ now: FrameGlobals) {
        for (slot, value) in base { scope[slot] = value }
        for (name, value) in now.named { scope[name] = value }
    }
}
