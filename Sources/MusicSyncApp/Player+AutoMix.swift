import Foundation
import Playback
import Subsonic
import Support

/// AutoMix: the current and the next two songs are analyzed in the background, and the transition into the next
/// song is planned again when an analysis comes in. Until then the songs crossfade.
extension Player {
    /// Asks for the analyses of the current, the next and the one after; none when AutoMix is off.
    func analyzeUpcoming() {
        guard settings.transitions == .autoMix, let index else { return analyses.want([]) }
        analyses.onResult = { [weak self] _ in self?.retimeNext() }
        let next = nextIndex ?? index + 1
        analyses.want([index, next, next + 1].filter(queue.indices.contains).compactMap(analysisJob(at:)))
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
        return (!fallback && localFile?(song.id) != nil) || !settings.stream(for: song, fallback: fallback).isConverted
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
        let stream = settings.stream(for: song, fallback: fallback)
        return .init(key: key, source: client.streamURL(id: song.id, format: stream.format, maxBitRate: stream.maxBitRate),
                     contentType: stream.contentType)
    }

    private func retimeNext() {
        if let nextIndex, let transition = transition(to: nextIndex) { mixer.retime(transition) }
    }
}

extension AnalysisQueue {
    /// The app's queue; its cache is in Caches/AutoMix (in the demo folder in demo mode).
    convenience init() { self.init(cache: AnalysisCache(directory: Paths.caches("AutoMix"))) }
}
