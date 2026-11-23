import Foundation

/// Reads `.milk` files: `key=value` lines under `[preset00]`. Numbered lines (`per_frame_1=`, `warp_1=` …) make the code
/// blocks, joined in number order; shader lines start with a backtick.
public enum PresetFile {
    public static func load(_ url: URL) throws -> Preset {
        let data = try Data(contentsOf: url)
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        return parse(text, name: url.deletingPathExtension().lastPathComponent)
    }

    public static func parse(_ text: String, name: String) -> Preset {
        var values: [String: Double] = [:]
        var waveValues = Array(repeating: [String: Double](), count: 4), shapeValues = waveValues
        var blocks: [String: [(Int, String)]] = [:]
        var version = 1
        for raw in text.split(whereSeparator: \.isNewline) {
            guard let eq = raw.firstIndex(of: "=") else { continue }
            let key = raw[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(raw[raw.index(after: eq)...])
            if key == "milkdrop_preset_version" { version = (Int(value.trimmingCharacters(in: .whitespaces)) ?? 0) >= 200 ? 2 : 1; continue }
            if let (block, index) = codeKey(key) {
                blocks[block, default: []].append((index, value))
            } else if let (n, rest) = indexed(key, "wavecode_") {
                waveValues[n][PresetKeys.names[rest] ?? rest] = number(value)
            } else if let (n, rest) = indexed(key, "shapecode_") {
                shapeValues[n][PresetKeys.names[rest] ?? rest] = number(value)
            } else if let n = number(value) {
                values[PresetKeys.names[key] ?? key] = n
            }
        }
        func code(_ block: String, shader: Bool = false) -> String {
            (blocks[block] ?? []).sorted { $0.0 < $1.0 }.map { line in
                shader ? String(line.1.drop { $0 == "`" }) : line.1
            }.joined(separator: "\n")
        }
        var preset = Preset(name: name, version: version, values: values.merging(PresetKeys.preset) { file, _ in file })
        preset.initCode = code("per_frame_init")
        preset.frameCode = code("per_frame")
        preset.pixelCode = code("per_pixel")
        preset.warp = code("warp", shader: true)
        preset.comp = code("comp", shader: true)
        preset.waves = (0..<4).map { i in
            Preset.Wave(values: waveValues[i].merging(PresetKeys.wave) { file, _ in file },
                        initCode: code("wave_\(i)_init"), frameCode: code("wave_\(i)_per_frame"), pointCode: code("wave_\(i)_per_point"))
        }
        preset.shapes = (0..<4).map { i in
            Preset.Shape(values: shapeValues[i].merging(PresetKeys.shape) { file, _ in file },
                         initCode: code("shape_\(i)_init"), frameCode: code("shape_\(i)_per_frame"))
        }
        return preset
    }

    /// `per_frame_12` → ("per_frame", 12), `wave_0_per_point3` → ("wave_0_per_point", 3).
    private static func codeKey(_ key: String) -> (String, Int)? {
        let digits = key.reversed().prefix { $0.isNumber }
        guard !digits.isEmpty, let index = Int(String(digits.reversed())) else { return nil }
        var block = String(key.dropLast(digits.count))
        if block.hasSuffix("_") { block.removeLast() }
        let fixed = ["per_frame_init", "per_frame", "per_pixel", "per_vertex", "warp", "comp"]
        if fixed.contains(block) { return (block == "per_vertex" ? "per_pixel" : block, index) }
        for kind in ["wave", "shape"] {
            guard let (n, rest) = indexed(block, "\(kind)_") else { continue }
            let parts = kind == "wave" ? ["init", "per_frame", "per_point"] : ["init", "per_frame"]
            if parts.contains(rest) { return ("\(kind)_\(n)_\(rest)", index) }
        }
        return nil
    }

    /// `wavecode_2_samples` with prefix `wavecode_` → (2, "samples") for indexes 0...3.
    private static func indexed(_ key: String, _ prefix: String) -> (Int, String)? {
        guard key.hasPrefix(prefix) else { return nil }
        let rest = key.dropFirst(prefix.count)
        guard let n = rest.first?.wholeNumberValue, n < 4, rest.dropFirst().first == "_" else { return nil }
        return (n, String(rest.dropFirst(2)))
    }

    /// Leading number of the text, as JavaScript's `parseFloat` reads it (`1.5f` is 1.5).
    static func number(_ text: String) -> Double? {
        let s = text.trimmingCharacters(in: .whitespaces)
        if let n = Double(s) { return n }
        var prefix = String(s.prefix { "0123456789.-+eE".contains($0) })
        while !prefix.isEmpty, Double(prefix) == nil { prefix.removeLast() }
        return Double(prefix)
    }
}
