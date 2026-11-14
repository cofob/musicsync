import Device
import Foundation
import ITunesDB
import Transcode

/// One song to download, encode and copy; `old` is the entry it replaces.
struct Work: Sendable {
    var desired: DesiredSong
    var old: Manifest.Entry?
    var estimate: Int64
}

struct Transferred: Sendable {
    var work: Work
    var prepared: Prepared
    var path: String
    var size: Int64
}

enum Outcome: Sendable {
    case done(Transferred)
    case failed(Work, String)
    case cancelled
}

extension SyncJob {
    /// Adds and re-encodes with `workers` parallel pipelines; files reach the device one at a time.
    func transfer() async throws {
        let items = plan.add.map { Work(desired: $0, old: nil, estimate: SizeEstimate.bytes($0)) }
            + plan.reencode.map { Work(desired: $0.desired, old: $0.entry, estimate: SizeEstimate.bytes($0.desired)) }
        guard !items.isEmpty, let ffmpeg, !Task.isCancelled else { return }
        emit(.phase(.transferring))
        progress = SyncProgress(itemsDone: 0, itemsTotal: items.count, bytesDone: 0, bytesTotal: items.reduce(0) { $0 + $1.estimate })
        publishProgress()

        let pipeline = TransferPipeline(client: client, ffmpeg: ffmpeg, workDir: workDir, lyrics: settings.lyrics)
        let used = Set(db.tracks.map { ITunesDB.relativePath(ipodLocation: $0.location) })
            .union(manifest.entries.values.map(\.relativePath)).union(manifest.rockboxEntries.values.map(\.relativePath))
        let copier = DeviceCopier(device: device, used: used)
        let emit = self.emit
        var queue = items.makeIterator()
        transferError = nil

        await withTaskGroup(of: Outcome.self) { group in
            func startNext() {
                guard !Task.isCancelled, transferError == nil, let work = queue.next() else { return }
                emit(.item(songID: work.desired.id, title: work.desired.tags.title, stage: .queued))
                group.addTask { await Self.process(work, pipeline: pipeline, copier: copier, emit: emit) }
            }
            for _ in 0..<max(1, settings.workers) { startNext() }
            while let outcome = await group.next() {
                do { try apply(outcome) } catch { transferError = error; group.cancelAll() }
                if Task.isCancelled { group.cancelAll() } else { startNext() }
            }
        }
        if let transferError { throw transferError }
    }

    /// Worker body: no access to job state.
    static func process(_ work: Work, pipeline: TransferPipeline, copier: DeviceCopier,
                        emit: @escaping @Sendable (SyncEvent) -> Void) async -> Outcome {
        let d = work.desired
        let stage: @Sendable (ItemStage) -> Void = { emit(.item(songID: d.id, title: d.tags.title, stage: $0)) }
        do {
            try Task.checkCancellation()
            let prepared = try await pipeline.prepare(d, stage: stage)
            defer { try? FileManager.default.removeItem(at: prepared.file) }
            try Task.checkCancellation()
            stage(.copying)
            let path = switch d.preset.target {
            case .stock: try await copier.copyStock(prepared.file, ext: prepared.ext)
            case .rockbox: try await copier.copyRockbox(
                prepared.file, wanted: RockboxPaths.songPath(d.tags, ext: prepared.ext), replacing: work.old?.relativePath)
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: prepared.file.path)[.size] as? Int64) ?? prepared.output.size
            return .done(Transferred(work: work, prepared: prepared, path: path, size: size))
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failed(work, error.localizedDescription)
        }
    }

    // MARK: Applying results

    private func apply(_ outcome: Outcome) throws {
        switch outcome {
        case .cancelled: return
        case .failed(let work, let message):
            let d = work.desired
            emit(.item(songID: d.id, title: d.tags.title, stage: .failed(message)))
            summary.failures.append(.init(songID: d.id, title: d.tags.title, message: message))
            finish(work)
        case .done(let t):
            let d = t.work.desired
            if d.preset.target == .stock { applyStock(t) } else { applyRockbox(t) }
            if t.work.old == nil { summary.added += 1 } else { summary.reencoded += 1 }
            manifestDirty = true
            sinceCheckpoint += 1
            emit(.item(songID: d.id, title: d.tags.title, stage: .done))
            finish(t.work)
            try checkpointIfDue()
        }
    }

    private func finish(_ work: Work) {
        progress.itemsDone += 1
        progress.bytesDone += work.estimate
        publishProgress()
    }

    private func entry(_ t: Transferred, dbid: UInt64, trackID: UInt32) -> Manifest.Entry {
        let d = t.work.desired
        return Manifest.Entry(
            dbid: dbid, trackID: trackID, relativePath: t.path, presetID: d.preset.id, presetVersion: d.preset.version,
            albumID: d.albumID, sourceSize: d.song.size, sourceSuffix: d.song.suffix, sourceCreated: d.song.created,
            outSize: t.size, fingerprint: d.fingerprint, title: d.tags.title)
    }

    /// New track, or the same track (id, dbid, statistics, artwork) pointing at the new file.
    private func applyStock(_ t: Transferred) {
        let d = t.work.desired
        var track = TrackBuilder.make(d, prepared: t.prepared, relativePath: t.path, size: t.size)
        let trackID: UInt32
        if let old = t.work.old, let i = db.tracks.firstIndex(where: { $0.dbid == old.dbid }) {
            let previous = db.tracks[i]
            track.id = previous.id; track.dbid = previous.dbid
            track.playCount = previous.playCount; track.skipCount = previous.skipCount; track.rating = previous.rating
            track.timePlayed = previous.timePlayed; track.timeAdded = previous.timeAdded
            track.bookmarkTime = previous.bookmarkTime
            if previous.hasArtwork { track.setArtwork(imageID: previous.mhiiLink, sourceSize: previous.artworkSize) }
            db.tracks[i] = track
            pendingDeletes.append(ITunesDB.relativePath(ipodLocation: previous.location))
            trackID = previous.id
        } else {
            trackID = db.addTrack(track)
        }
        manifest.entries[d.id] = entry(t, dbid: track.dbid, trackID: trackID)
        dbDirty = true
    }

    private func applyRockbox(_ t: Transferred) {
        if let old = t.work.old, old.relativePath != t.path { pendingDeletes.append(old.relativePath) }
        manifest.rockboxEntries[t.work.desired.id] = entry(t, dbid: 0, trackID: 0)
    }
}
