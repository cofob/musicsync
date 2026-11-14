import Foundation
import Testing
@testable import Transcode

private let ffmpeg = FFmpeg.locate()

/// Creates a scratch dir with a 3 s 24-bit/96 kHz stereo FLAC sine.
private func makeSource(seconds: Int = 3) async throws -> (dir: URL, flac: URL, ffmpeg: FFmpeg) {
    let ff = try #require(ffmpeg)
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("transcode-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let flac = dir.appendingPathComponent("src.flac")
    let r = try await runProcess(ff.ffmpeg, ["-y", "-v", "error", "-f", "lavfi", "-i",
        "sine=frequency=440:duration=\(seconds):sample_rate=96000", "-ac", "2", "-c:a", "flac", "-sample_fmt", "s32", flac.path])
    try #require(r.status == 0, "\(r.stderr)")
    return (dir, flac, ff)
}

@Suite(.enabled(if: ffmpeg != nil, "ffmpeg not installed"))
struct IntegrationTests {
    @Test func encodersAvailable() async throws {
        let ff = try #require(ffmpeg)
        #expect(try await ff.supports(.stockAAC))
        #expect(try await ff.supports(.rockboxFLAC))
        #expect(try await ff.supports(.rockboxOpus))
        #expect(try await ff.hasEncoder("no_such_encoder") == false)
        #expect(try await ff.version().hasPrefix("ffmpeg version"))
    }

    @Test func addLyricsKeepsAudioAndGapless() async throws {
        let (dir, flac, ff) = try await makeSource()
        defer { try? FileManager.default.removeItem(at: dir) }
        let aac = dir.appendingPathComponent("in.m4a"), out = dir.appendingPathComponent("out.m4a")
        try await ff.transcode(input: flac, output: aac, preset: .stockAAC, source: try await ff.probe(flac), tags: TrackTags()) { _ in }
        try await ff.addLyrics("La la\nLa", input: aac, output: out)
        let tags = try await runProcess(ff.ffprobe, ["-v", "error", "-show_entries", "format_tags=lyrics", "-of", "default=nw=1:nk=1", out.path])
        #expect(String(decoding: tags.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "La la\nLa")
        #expect(try Gapless.read(from: out) == Gapless.read(from: aac))
        #expect(try await ff.probe(out).codec == "aac")
    }

    @Test func stockAAC() async throws {
        let (dir, flac, ff) = try await makeSource()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try await ff.probe(flac)
        #expect(source.codec == "flac" && source.sampleRate == 96000 && source.bitsPerSample == 24)
        #expect(FFmpeg.needsTranscode(source: source, preset: .stockAAC))

        let out = dir.appendingPathComponent("out.m4a")
        let last = LastValue()
        let tags = TrackTags(title: "Sine", artist: "Tester", album: "Album", trackNumber: 2, trackTotal: 9)
        try await ff.transcode(input: flac, output: out, preset: .stockAAC, source: source, tags: tags) { last.value = $0 }
        #expect(last.value == 1)

        let info = try await ff.probe(out)
        #expect(info.codec == "aac" && info.profile == "LC")
        #expect(info.sampleRate == 44100 && info.channels == 2)
        #expect(abs(info.durationSeconds - 3) < 0.05)
        #expect(!FFmpeg.needsTranscode(source: info, preset: .stockAAC))

        let tagJSON = try await runProcess(ff.ffprobe, ["-v", "error", "-show_entries", "format_tags", "-of", "json", out.path])
        let text = String(decoding: tagJSON.stdout, as: UTF8.self)
        #expect(text.contains("\"title\": \"Sine\"") && text.contains("\"track\": \"2/9\""))

        // ffmpeg rounds the edit list up to whole 1024-sample frames.
        let raw = try Gapless.read(from: out)
        #expect(raw.pregap == 2112)
        #expect(raw.sampleCount >= 3 * 44100 && raw.sampleCount < 3 * 44100 + 1024)
        let exact = try Gapless.read(from: out, exactSampleCount: Int((source.durationSeconds * 44100).rounded()))
        #expect(exact.pregap == 2112 && exact.sampleCount == 3 * 44100)
        #expect((exact.pregap + exact.sampleCount + exact.postgap) % 1024 == 0)
        #expect(exact.postgap >= 0 && exact.postgap < 2048)
    }

    @Test func rockboxFLAC() async throws {
        let (dir, flac, ff) = try await makeSource()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("out.flac")
        try await ff.transcode(input: flac, output: out, preset: .rockboxFLAC, source: try await ff.probe(flac), tags: TrackTags(title: "x")) { _ in }
        let info = try await ff.probe(out)
        #expect(info.codec == "flac" && info.sampleRate == 44100 && info.bitsPerSample == 16)
        #expect(abs(info.durationSeconds - 3) < 0.05)
        #expect(!FFmpeg.needsTranscode(source: info, preset: .rockboxFLAC))
    }

    @Test func rockboxOpus() async throws {
        let (dir, flac, ff) = try await makeSource()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("out.opus")
        try await ff.transcode(input: flac, output: out, preset: .rockboxOpus, source: try await ff.probe(flac), tags: TrackTags(title: "x")) { _ in }
        let info = try await ff.probe(out)
        #expect(info.codec == "opus" && info.channels == 2)
        #expect(abs(info.durationSeconds - 3) < 0.05)
    }

    @Test func failureRemovesPartialOutputAndReportsStderr() async throws {
        let (dir, flac, ff) = try await makeSource(seconds: 1)
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("out.m4a")
        let source = try await ff.probe(flac)
        try Data("junk".utf8).write(to: dir.appendingPathComponent("bad.flac"))
        await #expect(throws: TranscodeError.self) {
            try await ff.transcode(input: dir.appendingPathComponent("bad.flac"), output: out, preset: .stockAAC,
                                   source: source, tags: TrackTags()) { _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: out.path))
    }

    @Test func cancellationKillsProcess() async throws {
        let (dir, flac, ff) = try await makeSource(seconds: 1200)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try await ff.probe(flac)
        let out = dir.appendingPathComponent("cancel-\(UUID().uuidString).m4a")
        let started = LastValue()
        let task = Task {
            try await ff.transcode(input: flac, output: out, preset: .stockAAC, source: source, tags: TrackTags()) { started.value = $0 }
        }
        for _ in 0..<100 where started.value == 0 { try await Task.sleep(for: .milliseconds(100)) }
        #expect(started.value > 0)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: out.path))
        var alive = true
        for _ in 0..<50 where alive {
            let r = try await runProcess(URL(fileURLWithPath: "/usr/bin/pgrep"), ["-f", out.lastPathComponent])
            alive = r.status == 0
            if alive { try await Task.sleep(for: .milliseconds(100)) }
        }
        #expect(!alive)
    }
}

private final class LastValue: @unchecked Sendable {
    private let lock = NSLock()
    private var v = 0.0
    var value: Double {
        get { lock.withLock { v } }
        set { lock.withLock { v = newValue } }
    }
}
