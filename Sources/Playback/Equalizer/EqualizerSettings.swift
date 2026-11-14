import Foundation
import Support

/// Window > Equalizer. Persisted by the app (UserDefaults key `equalizerSettings`, JSON), apart from
/// `PlaybackSettings`: a slider move must not rebuild the next song.
public struct EqualizerSettings: Codable, Equatable, Sendable {
    public var isOn = false
    /// dB, −12…12.
    public var preamp = 0.0
    /// dB per band of `EqualizerGains.frequencies`, −12…12.
    public var bands = EqualizerPreset.flat.bands
    /// Name of the chosen preset; nil when a band was moved by hand (Manual).
    public var preset: String? = EqualizerPreset.flat.name
    public var userPresets: [EqualizerPreset] = []

    public init() {}

    /// What the filters play: flat when off.
    public var gains: EqualizerGains { isOn ? EqualizerGains(preamp: preamp, bands: bands) : .flat }

    /// Built-in presets, then the saved ones.
    public var presets: [EqualizerPreset] { EqualizerPreset.builtIn + userPresets }

    /// Like a band move, a preset turns the equalizer on, as in Apple Music.
    public mutating func apply(_ preset: EqualizerPreset) {
        isOn = true
        bands = preset.bands
        self.preset = preset.name
    }

    public mutating func setBand(_ index: Int, to value: Double) {
        guard bands.indices.contains(index) else { return }
        isOn = true
        bands[index] = value
        preset = nil
    }

    /// A saved preset replaces one of the same name. Built-in names are kept for the built-in presets.
    public func canSave(as name: String) -> Bool {
        let name = name.trimmingCharacters(in: .whitespaces)
        return !name.isEmpty && !EqualizerPreset.builtIn.contains { $0.name == name }
    }

    public mutating func savePreset(as name: String) {
        guard canSave(as: name) else { return }
        let name = name.trimmingCharacters(in: .whitespaces)
        userPresets.removeAll { $0.name == name }
        userPresets.append(EqualizerPreset(name: name, bands: bands))
        preset = name
    }

    public mutating func deletePreset(_ name: String) {
        userPresets.removeAll { $0.name == name }
        if preset == name { preset = nil }
    }

    /// Missing keys keep their defaults; a wrong band count is padded or cut to ten bands.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = EqualizerSettings()
        isOn = try c.decodeIfPresent(Bool.self, forKey: .isOn) ?? d.isOn
        preamp = try c.decodeIfPresent(Double.self, forKey: .preamp) ?? d.preamp
        bands = EqualizerGains.fit(try c.decodeIfPresent([Double].self, forKey: .bands) ?? d.bands)
        // Manual saves no preset name.
        preset = try c.decodeIfPresent(String.self, forKey: .preset) ?? (bands == d.bands ? d.preset : nil)
        userPresets = (try c.decodeIfPresent([EqualizerPreset].self, forKey: .userPresets) ?? [])
            .map { EqualizerPreset(name: $0.name, bands: EqualizerGains.fit($0.bands)) }
    }

    public static let defaultsKey = "equalizerSettings"

    public static func load(from defaults: UserDefaults = .app) -> EqualizerSettings {
        guard let data = defaults.data(forKey: defaultsKey),
              let value = try? JSONDecoder().decode(EqualizerSettings.self, from: data) else { return EqualizerSettings() }
        return value
    }

    public func save(to defaults: UserDefaults = .app) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}
