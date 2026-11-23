/// Band values of the equalizer, in dB, for `EqualizerGains.frequencies`.
public struct EqualizerPreset: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var name: String
    public var bands: [Double]
    public var id: String { name }

    public init(name: String, bands: [Double]) {
        self.name = name
        self.bands = bands
    }

    public static let flat = EqualizerPreset(name: "Flat", bands: Array(repeating: 0, count: 10))

    /// The standard presets, in the usual order.
    public static let builtIn: [EqualizerPreset] = [
        .init(name: "Acoustic", bands: [5, 4.9, 3.95, 1.05, 2.15, 1.75, 3.5, 4.1, 3.55, 2.15]),
        .init(name: "Bass Booster", bands: [5.5, 4.25, 3.5, 2.5, 1.25, 0, 0, 0, 0, 0]),
        .init(name: "Bass Reducer", bands: [-5.5, -4.25, -3.5, -2.5, -1.25, 0, 0, 0, 0, 0]),
        .init(name: "Classical", bands: [4.75, 3.75, 3, 2.5, -1.5, -1.5, 0, 2.25, 3.25, 3.75]),
        .init(name: "Dance", bands: [3.57, 6.55, 4.99, 0, 1.92, 3.65, 5.15, 4.54, 3.59, 0]),
        .init(name: "Deep", bands: [4.95, 3.55, 1.76, 1, 2.85, 2.5, 1.45, -2.15, -3.55, -4.6]),
        .init(name: "Electronic", bands: [4.25, 3.8, 1.2, 0, -2.15, 2.2, 0.85, 1.25, 3.95, 4.8]),
        flat,
        .init(name: "Hip-Hop", bands: [5, 4.25, 1.5, 3, -1, -1, 1.5, -0.5, 2, 3]),
        .init(name: "Jazz", bands: [4, 3, 1.5, 2.25, -1.5, -1.5, 0, 1.5, 3, 3.75]),
        .init(name: "Late Night", bands: [4.92, 4.1, 2.35, 0.24, -1.4, 1.38, 2.62, 2.81, 3.28, 3.55]),
        .init(name: "Latin", bands: [4.5, 3, 0, 0, -1.5, -1.5, -1.5, 0, 3, 4.5]),
        .init(name: "Loudness", bands: [6, 4, 0, 0, -2, 0, -1, -5, 5, 1]),
        .init(name: "Lounge", bands: [-3, -1.5, -0.5, 1.5, 4, 2.5, 0, -1.5, 2, 1]),
        .init(name: "Piano", bands: [3, 2, 0, 2.5, 3, 1.5, 3.5, 4.5, 3, 3.5]),
        .init(name: "Pop", bands: [-1.5, -1, 0, 2, 4, 4, 2, 0, -1, -1.5]),
        .init(name: "R&B", bands: [2.62, 6.92, 5.65, 1.33, -2.19, -1.5, 2.32, 2.65, 3, 3.75]),
        .init(name: "Rock", bands: [5, 4, 3, 1.5, -0.5, -1, 0.5, 2.5, 3.5, 4.5]),
        .init(name: "Small Speakers", bands: [5.5, 4.25, 3.5, 2.5, 1.25, 0, -1.25, -2.5, -3.5, -4.25]),
        .init(name: "Spoken Word", bands: [-3.46, -0.47, 0, 0.69, 3.46, 4.61, 4.84, 4.28, 2.54, 0]),
        .init(name: "Treble Booster", bands: [0, 0, 0, 0, 0, 1.25, 2.5, 3.5, 4.25, 5.5]),
        .init(name: "Treble Reducer", bands: [0, 0, 0, 0, 0, -1.25, -2.5, -3.5, -4.25, -5.5]),
        .init(name: "Vocal Booster", bands: [-1.5, -3, -3, 1.5, 3.75, 3.75, 3, 1.5, 0, -1.5]),
    ]
}
