import Foundation
import JavaScriptCore
@testable import MilkDropKit
import Testing

/// Runs the presets that butterchurnPresets.min.js holds as compiled JavaScript next to the same bundled .milk files,
/// with fixed inputs and random, and compares every variable.
@Suite struct EELOracleTests {
    private static let visualizer = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appending(path: "Sources/MusicSyncApp/Resources/Visualizer")
    /// Its .milk has the typo `wave_mysyery`; butterchurn's copy does not.
    private static let knownDifferences: Set = ["Idiot - Star Of Annon"]

    /// butterchurn's EEL helpers, with Math.random fixed and `randint` following our `rand` rule for n < 1
    /// (butterchurn gives 0 there).
    private static func context() throws -> JSContext {
        let context = try #require(JSContext())
        context.exceptionHandler = { _, error in Issue.record("JavaScript: \(error?.toString() ?? "?")") }
        let butterchurn = try String(contentsOf: visualizer.appending(path: "butterchurn.min.js"), encoding: .utf8)
        let start = try #require(butterchurn.range(of: "window.sqr=function"))
        let memcpy = try #require(butterchurn.range(of: "window.memcpy=", range: start.upperBound..<butterchurn.endIndex))
        let end = try #require(butterchurn.range(of: ",e}", range: memcpy.upperBound..<butterchurn.endIndex))
        context.evaluateScript("var window = this, self = this; Math.random = function () { return 0.5 };")
        context.evaluateScript(String(butterchurn[start.lowerBound..<end.upperBound]))
        context.evaluateScript("window.randint = function (t) { var e = Math.floor(t); return e < 1 ? Math.random() : Math.floor(Math.random() * e) };")
        context.evaluateScript(try String(contentsOf: visualizer.appending(path: "butterchurnPresets.min.js"), encoding: .utf8))
        context.evaluateScript("""
        function setUp(p, keys) {
            a = Object.assign({}, p.baseVals, {time: 1, frame: 0, fps: 60, bass: 1.2, mid: 0.9, treb: 1.1,
                bass_att: 1.1, mid_att: 0.95, treb_att: 1.05, meshx: 48, meshy: 36, aspectx: 1, aspecty: 1,
                pixelsx: 1024, pixelsy: 768, x: 0.3, y: 0.6, rad: 0.4, ang: 1.2, sample: 0.25, value1: 0.3, value2: -0.2});
            for (var i = 1; i <= 32; i++) a['q' + i] = 0;
            a.megabuf = new Array(1048576).fill(0); a.gmegabuf = new Array(1048576).fill(0);
            var code = keys.map(function (k) { return p[k] || ''; });
            code.join(' ').replace(/a\\.([A-Za-z_][A-Za-z0-9_]*)/g, function (m, k) { if (a[k] === undefined) a[k] = 0; });
            run = code.map(function (c) { return new Function('a', c + '; return a;'); });
            return code.join('').length;
        }
        function numberKeys() { return Object.keys(a).filter(function (k) { return typeof a[k] == 'number'; }); }
        """)
        return context
    }

    @Test func matchesButterchurn() throws {
        let context = try Self.context()
        let presets = try Dictionary(bundledPresets().map { ($0.name, $0.text) }) { a, _ in a }
        let names = try #require(context.evaluateScript("Object.keys(butterchurnPresets.getPresets())").toArray() as? [String])
        var compared = 0
        var mismatches: [String] = []
        for name in names where !Self.knownDifferences.contains(name) {
            guard let text = presets[name + ".milk"] else { continue }
            let blocks = milkCodeBlocks(text)
            context.setObject(name, forKeyedSubscript: "name" as NSString)
            context.evaluateScript("var p = butterchurnPresets.getPresets()[name];")
            var units = [("p", ["init_eqs_str", "frame_eqs_str", "pixel_eqs_str"], ["per_frame_init", "per_frame", "per_pixel"])]
            for i in 0..<4 {
                units.append(("p.waves[\(i)]", ["init_eqs_str", "frame_eqs_str", "point_eqs_str"], ["wave_\(i)_init", "wave_\(i)_per_frame", "wave_\(i)_per_point"]))
                units.append(("p.shapes[\(i)]", ["init_eqs_str", "frame_eqs_str"], ["shape_\(i)_init", "shape_\(i)_per_frame"]))
            }
            for (object, jsKeys, milkKeys) in units {
                let keyList = jsKeys.map { "'\($0)'" }.joined(separator: ",")
                guard context.evaluateScript("setUp(\(object), [\(keyList)])").toInt32() > 0 else { continue }
                let label = "\(name) \(object)"
                let scope = EELScope(memory: EELMemory(), globals: EELGlobals(), random: { 0.5 })
                for key in try #require(context.evaluateScript("numberKeys()").toArray() as? [String]) {
                    scope[key] = context.evaluateScript("a['\(key)']").toDouble()
                }
                guard let programs = try? milkKeys.map({ try scope.compile(blocks[$0] ?? "") }) else {
                    mismatches.append("\(label): does not compile")
                    continue
                }
                context.evaluateScript("run[0](a)")
                scope.run(programs[0])
                for frame in 1...3 {
                    context.evaluateScript("a.frame = \(frame); a.time = 1 + \(frame) / 60; for (var i = 1; i < run.length; i++) run[i](a);")
                    scope["frame"] = Double(frame)
                    scope["time"] = 1 + Double(frame) / 60
                    programs.dropFirst().forEach(scope.run)
                }
                compared += 1
                for key in try #require(context.evaluateScript("numberKeys()").toArray() as? [String]) {
                    let js = context.evaluateScript("a['\(key)']").toDouble(), ours = scope[key]
                    if js.isNaN && ours.isNaN { continue }
                    if !(abs(js - ours) <= 1e-6 * max(1, abs(js))) { mismatches.append("\(label): \(key) js \(js) ours \(ours)") }
                }
            }
        }
        print("EEL oracle: \(compared) code units (preset, wave or shape) compared, \(mismatches.count) mismatches")
        mismatches.forEach { print("  \($0)") }
        #expect(compared > 50)
        #expect(mismatches.isEmpty)
    }
}
