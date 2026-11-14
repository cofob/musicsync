import Foundation
import Testing
@testable import Subsonic
@testable import Sync
import Transcode

struct ServerFormatTests {
    private func format(_ song: Song, preset: Preset = .stockAAC, enabled: Bool = true) -> String? {
        TransferPipeline.serverFormat(makeDesired(song, preset: preset), enabled: enabled).map { "\($0.format)/\($0.kbps)" }
    }

    @Test func onlyLosslessUpTo48kHzForTheStockPreset() {
        #expect(format(makeSong("a")) == "aac/256")
        #expect(format(makeSong("a", suffix: "m4a", bitRate: 900)) == "aac/256")  // ALAC
        #expect(format(makeSong("a", suffix: "mp3", bitRate: 320)) == nil)
        #expect(format(makeSong("a", suffix: "m4a", bitRate: 256)) == nil)
        #expect(format(makeSong("a", extra: ["samplingRate": 96000])) == nil)
        #expect(format(makeSong("a", extra: ["samplingRate": 0])) == nil)
        #expect(format(makeSong("a"), preset: .rockboxOpus) == nil)
        #expect(format(makeSong("a"), enabled: false) == nil)
    }

    @Test func oldSettingsLoadWithConversionOff() throws {
        let settings = try JSONDecoder().decode(SyncSettings.self, from: Data(#"{"lyrics":false}"#.utf8))
        #expect(!settings.serverConversion && !settings.lyrics)
    }
}

@Suite(.enabled(if: ffmpegTools != nil, "ffmpeg not installed"))
struct ServerConversionTests {
    private func prepare(convertedOnServer: Bool) async throws -> (Prepared, StubServer) {
        let dir = try tempDirectory("server-conversion")
        defer { try? FileManager.default.removeItem(at: dir) }
        let server = StubServer()
        server.serve(songID: "s-1", file: try makeFLAC(in: dir, name: "s.flac", seconds: 2, frequency: 440))
        if convertedOnServer {
            let adts = try makeFLAC(in: dir, name: "s.aac", seconds: 2, frequency: 440,
                                    encode: ["-c:a", "aac", "-b:a", "256k", "-f", "adts"])
            server.serveConverted(songID: "s-1", file: adts)
        }
        let pipeline = TransferPipeline(client: server.client, ffmpeg: try #require(ffmpegTools), workDir: dir,
                                        serverConversion: true)
        let prepared = try await pipeline.prepare(makeDesired(makeSong("s-1", duration: 2))) { _ in }
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        try FileManager.default.copyItem(at: prepared.file, to: copy)
        var result = prepared
        result.file = copy
        return (result, server)
    }

    @Test func serverAACIsRemuxedNotEncodedAgain() async throws {
        let (prepared, server) = try await prepare(convertedOnServer: true)
        defer { try? FileManager.default.removeItem(at: prepared.file) }
        #expect(!prepared.transcoded && prepared.ext == "m4a")
        #expect(prepared.output.codec == "aac" && prepared.output.container.contains("mp4"))
        let query = try #require(server.streamQueries.first)
        #expect(query.contains(URLQueryItem(name: "format", value: "aac")))
        #expect(query.contains(URLQueryItem(name: "maxBitRate", value: "256")))
    }

    @Test func originalFromTheServerIsConvertedHere() async throws {
        let (prepared, _) = try await prepare(convertedOnServer: false)
        defer { try? FileManager.default.removeItem(at: prepared.file) }
        #expect(prepared.transcoded && prepared.ext == "m4a" && prepared.output.codec == "aac")
    }
}
