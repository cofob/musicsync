import Foundation
@testable import MilkDropKit
import Testing

/// Code blocks of a .milk text by name (`per_frame`, `wave_0_per_point` …), lines joined as MilkDrop does.
func milkCodeBlocks(_ text: String) -> [String: String] {
    let key = /^(per_frame_init|per_frame|per_pixel)_\d+$|^((?:wave|shape)_\d+_(?:init|per_frame|per_point))\d+$/
    var lines: [String: [String]] = [:]
    for line in text.split(whereSeparator: \.isNewline) {
        guard let eq = line.firstIndex(of: "="), let match = line[..<eq].wholeMatch(of: key) else { continue }
        lines[String(match.1 ?? match.2!), default: []].append(String(line[line.index(after: eq)...]))
    }
    return lines.mapValues(EELScope.joinCodeLines)
}

func bundledPresets() throws -> [(name: String, text: String)] {
    try FileManager.default.contentsOfDirectory(at: #require(MilkDropResources.presets), includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "milk" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        .map { ($0.lastPathComponent, String(decoding: try Data(contentsOf: $0), as: UTF8.self)) }
}
