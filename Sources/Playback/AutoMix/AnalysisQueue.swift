import Foundation

/// Analyzes songs for AutoMix in the background at low priority, one at a time: from the cache, a local file, or a
/// stream saved to a temp file (at most `maxBytes`). It keeps the results of the wanted songs in memory.
@MainActor public final class AnalysisQueue {
    public struct Job: Equatable, Sendable {
        /// `AnalysisCache.key(for:)`.
        public var key: String
        /// A local file or a stream URL.
        public var source: URL
        /// Type of a stream, which has no file extension.
        public var contentType: String?

        public init(key: String, source: URL, contentType: String? = nil) {
            self.key = key
            self.source = source
            self.contentType = contentType
        }
    }

    /// Called with the key of each new result.
    public var onResult: @MainActor (String) -> Void = { _ in }
    public private(set) var results: [String: SongAnalysis] = [:]
    private let cache: AnalysisCache
    private let session: URLSession
    private let maxBytes: Int
    private var wanted: [Job] = []
    private var running: (job: Job, id: UUID, task: Task<Void, Never>)?
    /// Not tried again in this session.
    private var failed: Set<String> = []

    public init(cache: AnalysisCache, session: URLSession = .shared, maxBytes: Int = 60_000_000) {
        self.cache = cache
        self.session = session
        self.maxBytes = maxBytes
    }

    /// Analyzes `jobs` in order and forgets the results of other songs. A running job that is not wanted any more stops.
    public func want(_ jobs: [Job]) {
        wanted = jobs
        let keys = Set(jobs.map(\.key))
        results = results.filter { keys.contains($0.key) }
        if let running, !jobs.contains(running.job) {
            running.task.cancel()
            self.running = nil
        }
        startNext()
    }

    private func startNext() {
        guard running == nil, let job = wanted.first(where: { results[$0.key] == nil && !failed.contains($0.key) }) else { return }
        let id = UUID()
        let (cache, session, maxBytes) = (cache, session, maxBytes)
        let task = Task.detached(priority: .background) { [weak self] in
            let analysis = await Self.analyze(job, cache: cache, session: session, maxBytes: maxBytes)
            await self?.finished(id, analysis)
        }
        running = (job, id, task)
    }

    private func finished(_ id: UUID, _ analysis: SongAnalysis?) {
        guard let job = running?.job, running?.id == id else { return }  // stopped
        running = nil
        if let analysis {
            results[job.key] = analysis
            onResult(job.key)
        } else {
            failed.insert(job.key)
        }
        startNext()
    }

    nonisolated static func analyze(_ job: Job, cache: AnalysisCache, session: URLSession, maxBytes: Int) async -> SongAnalysis? {
        if let cached = cache.read(job.key) { return cached }
        let file = job.source.isFileURL ? job.source : try? await download(job.source, session: session, maxBytes: maxBytes)
        guard let file else { return nil }
        defer { if file != job.source { try? FileManager.default.removeItem(at: file) } }
        guard let samples = try? await PCMReader.samples(of: file, contentType: job.contentType), !Task.isCancelled else { return nil }
        let analysis = SongAnalysis(samples: samples)
        cache.write(analysis, for: job.key)
        return analysis
    }

    /// Saves `url` to a temp file; fails past `maxBytes`.
    nonisolated static func download(_ url: URL, session: URLSession, maxBytes: Int) async throws -> URL {
        let (bytes, response) = try await session.bytes(from: url)
        if let status = (response as? HTTPURLResponse)?.statusCode, status != 200 { throw AnalysisError.status(status) }
        guard response.expectedContentLength <= maxBytes else { throw AnalysisError.tooLarge }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("automix-\(UUID().uuidString)")
        do {
            guard FileManager.default.createFile(atPath: file.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            var chunk: [UInt8] = [], total = 0
            chunk.reserveCapacity(1 << 16)
            for try await byte in bytes {
                chunk.append(byte)
                guard chunk.count == 1 << 16 else { continue }
                total += chunk.count
                if total > maxBytes { throw AnalysisError.tooLarge }
                try handle.write(contentsOf: chunk)
                chunk.removeAll(keepingCapacity: true)
            }
            if total + chunk.count > maxBytes { throw AnalysisError.tooLarge }
            try handle.write(contentsOf: chunk)
            return file
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
    }
}
