import Foundation

/// The "Cream of the Crop" pack (projectM, 9 795 presets sorted by theme), downloaded on request by category.
/// The archive is fixed to one commit, so the counts below stay true. Presets go to `<folder>/<category>/<name>.milk`.
public enum PresetPack {
    public static let commit = "0180df21f5e0bd39b9060cc5de420ed2f1f9e509"
    static let archive = URL(string: "https://codeload.github.com/projectM-visualizer/presets-cream-of-the-crop/tar.gz/\(commit)")!

    public struct Category: Sendable, Hashable, Identifiable {
        public var name: String
        public var count: Int
        public var id: String { name }
    }

    public static let categories: [Category] = [
        ("Dancer", 1351), ("Drawing", 1143), ("Fractal", 1354), ("Geometric", 1027), ("Hypnotic", 280),
        ("Particles", 389), ("Reaction", 1791), ("Sparkle", 797), ("Supernova", 380), ("Transition", 4), ("Waveform", 1279),
    ].map { Category(name: $0.0, count: $0.1) }

    /// Presets now in `folder`, by category.
    public static func installed(in folder: URL) -> [String: Int] {
        var counts: [String: Int] = [:]
        for category in categories {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent(category.name).path)) ?? []
            let n = files.filter { $0.hasSuffix(".milk") }.count
            if n > 0 { counts[category.name] = n }
        }
        return counts
    }

    public static func remove(_ category: String, from folder: URL) throws {
        try FileManager.default.removeItem(at: folder.appendingPathComponent(category))
    }

    /// Downloads the pack once and keeps the presets of `wanted` categories. `progress` gets 0…1 of the download.
    /// Returns how many presets it saved.
    public static func download(_ wanted: Set<String>, to folder: URL, session: URLSession = .shared,
                                progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> Int {
        let (bytes, response) = try await session.bytes(from: archive)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let expected = response.expectedContentLength
        var saved = 0
        let reader = TarGzip { path, data in
            guard let (category, name) = place(path), wanted.contains(category) else { return }
            let dir = folder.appendingPathComponent(category)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: dir.appendingPathComponent(name))
            saved += 1
        }
        var chunk = Data(), received = 0
        chunk.reserveCapacity(1 << 16)
        for try await byte in bytes {
            chunk.append(byte)
            guard chunk.count == 1 << 16 else { continue }
            try Task.checkCancellation()
            try reader.append(chunk)
            received += chunk.count
            chunk.removeAll(keepingCapacity: true)
            if expected > 0 { progress(min(Double(received) / Double(expected), 1)) }
        }
        try reader.append(chunk)
        try reader.finish()
        progress(1)
        return saved
    }

    /// `presets-cream-of-the-crop-<sha>/! Transition/sub/x.milk` → ("Transition", "x.milk"); nil for other files.
    static func place(_ path: String) -> (String, String)? {
        let parts = path.split(separator: "/")
        guard parts.count >= 3, let file = parts.last, file.hasSuffix(".milk") else { return nil }
        let category = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "! "))
        return (category, String(file))
    }
}
