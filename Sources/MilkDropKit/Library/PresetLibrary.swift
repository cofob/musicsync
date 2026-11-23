import Foundation

/// The `.milk` presets the visualizer can show: the bundled ones and those in other folders (the user's own,
/// downloaded packs). Files are parsed when shown. A name in a later folder hides the same name before it.
public struct PresetLibrary: Sendable {
    public struct Entry: Sendable, Hashable {
        public var name: String
        public var url: URL
        public var isBuiltIn: Bool
    }

    public private(set) var entries: [String: Entry] = [:]

    /// `folders` are searched one level deep, so a downloaded pack can keep its category folders.
    public init(builtIn: URL? = MilkDropResources.presets, folders: [URL]) {
        if let builtIn { add(builtIn, isBuiltIn: true) }
        for folder in folders { add(folder, isBuiltIn: false) }
    }

    /// Names to show: all, or only the folder presets when `builtIn` is off and there are any. Sorted, case-insensitive.
    public func names(includingBuiltIn builtIn: Bool, excluding failed: Set<String> = []) -> [String] {
        let own = entries.values.filter { !$0.isBuiltIn }
        let shown = builtIn || own.isEmpty ? Array(entries.values) : own
        return shown.map(\.name).filter { !failed.contains($0) }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    public func load(_ name: String) throws -> Preset {
        guard let entry = entries[name] else { throw CocoaError(.fileNoSuchFile) }
        return try PresetFile.load(entry.url)
    }

    private mutating func add(_ folder: URL, isBuiltIn: Bool) {
        let fm = FileManager.default
        for url in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey])) ?? [] {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                for file in (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [] { add(file: file, isBuiltIn) }
            } else {
                add(file: url, isBuiltIn)
            }
        }
    }

    private mutating func add(file: URL, _ isBuiltIn: Bool) {
        guard file.pathExtension.lowercased() == "milk" else { return }
        let name = file.deletingPathExtension().lastPathComponent
        entries[name] = Entry(name: name, url: file, isBuiltIn: isBuiltIn)
    }
}
