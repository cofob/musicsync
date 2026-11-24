import Foundation
import Playback
import Subsonic
import Support

/// AutoMix: the current and the next two songs are analyzed in the background, and the transition into the next
/// song is planned again when an analysis comes in. Until then the songs crossfade.
/// A visualizer that follows song parts has the current song analyzed too, for its `sections`.
extension Player {
    /// Asks for the analyses of the current, the next and the one after, when they mix into each other (not an album
    /// in order), and of the current song for the visualizer; none when neither wants them.
    func analyzeUpcoming() {
        analyses.onResult = { [weak self] _ in self?.analysisArrived() }
        guard let index else { analyses.want([]); return updateSections() }
        var wanted = wantsSections ? [index] : []
        if settings.transitions == .autoMix {
            let next = nextIndex ?? index + 1
            let mixed = [(index, next), (next, next + 1)].filter { a, b in
                queue.indices.contains(b) && settings.transition(from: queue[a].song, to: queue[b].song, duration: queue[a].duration) != nil
            }
            wanted += mixed.flatMap { [$0.0, $0.1] }
        }
        var seen = Set<Int>()
        analyses.want(wanted.filter { seen.insert($0).inserted }.compactMap(analysisJob(at:)))
        updateSections()
    }

    /// A visualizer is open and set to follow song parts (Settings > Visualizer).
    private var wantsSections: Bool { visualizers > 0 && UserDefaults.app.bool(forKey: VisualizerSettings.sections) }

    private func analysisArrived() {
        if settings.transitions == .autoMix { retimeNext() }
        updateSections()
    }

    private func updateSections() {
        let new = wantsSections ? index.flatMap(analysis(at:)) : nil
        if new != analysis { analysis = new }
    }

    /// Analyses of the current entry and entry `i`, when both are ready.
    func analyses(into i: Int) -> (SongAnalysis, SongAnalysis)? {
        guard let index, let a = analysis(at: index), let b = analysis(at: i) else { return nil }
        return (a, b)
    }

    /// Entry `i` can start past its beginning: a file, or the original file streamed (with byte ranges).
    func canSeek(_ i: Int) -> Bool {
        guard case .server(let song) = queue[i] else { return true }
        let fallback = transcoded.contains(i)
        return (!fallback && localFile?(song.id) != nil) || !streamSettings.stream(for: song, fallback: fallback).isConverted
    }

    private func analysis(at i: Int) -> SongAnalysis? {
        guard queue.indices.contains(i), case .server(let song) = queue[i] else { return nil }
        return analyses.results[AnalysisCache.key(for: song)]
    }

    /// The downloaded file, else the stream the player plays. Not for live streams, local files or songs that cannot play now.
    private func analysisJob(at i: Int) -> AnalysisQueue.Job? {
        guard case .server(let song) = queue[i], canPlay?(queue[i]) ?? true else { return nil }
        let key = AnalysisCache.key(for: song), fallback = transcoded.contains(i)
        if !fallback, let url = localFile?(song.id) { return .init(key: key, source: url) }
        guard let client else { return nil }
        let stream = streamSettings.stream(for: song, fallback: fallback)
        return .init(key: key, source: client.streamURL(id: song.id, format: stream.format, maxBitRate: stream.maxBitRate),
                     contentType: stream.contentType)
    }

    private func retimeNext() {
        if let nextIndex, let transition = transition(to: nextIndex) { mixer.retime(transition) }
    }
}

private extension PlayItem {
    var song: Song? { if case .server(let song) = self { song } else { nil } }
}

extension AnalysisQueue {
    /// The app's queue; its cache is in Caches/AutoMix (in the demo folder in demo mode).
    convenience init() { self.init(cache: AnalysisCache(directory: Paths.caches("AutoMix"))) }
}
