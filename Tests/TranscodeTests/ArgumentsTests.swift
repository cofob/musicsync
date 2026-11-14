import Foundation
import Testing
@testable import Transcode

private let flac24x96 = MediaInfo(codec: "flac", sampleRate: 96000, channels: 2, bitsPerSample: 24, durationSeconds: 3, container: "flac")
private let flac16x44 = MediaInfo(codec: "flac", sampleRate: 44100, channels: 2, bitsPerSample: 16, durationSeconds: 3, container: "flac")
private let flac24x44 = MediaInfo(codec: "flac", sampleRate: 44100, channels: 2, bitsPerSample: 24, durationSeconds: 3, container: "flac")
private let tags = TrackTags(title: "T", artist: "A", album: "B", albumArtist: "AA", genre: "G", year: 2020,
                             trackNumber: 3, trackTotal: 12, discNumber: 1, discTotal: 2, compilation: true)
private let inURL = URL(fileURLWithPath: "/in/a.flac")
private let outURL = URL(fileURLWithPath: "/out/a.m4a")

private func args(_ preset: Preset, _ source: MediaInfo, _ tags: TrackTags = TrackTags()) -> [String] {
    FFmpeg.arguments(input: inURL, output: outURL, preset: preset, source: source, tags: tags)
}

private let resample = "aresample=44100:filter_size=64:phase_shift=10:cutoff=0.97:dither_method=triangular_hp"

@Test func stockAACCommand() {
    #expect(args(.stockAAC, flac24x96, tags) == [
        "-y", "-nostdin", "-hide_banner", "-v", "error", "-progress", "pipe:1",
        "-i", "/in/a.flac", "-map", "0:a:0", "-map_metadata", "-1",
        "-af", resample, "-sample_fmt", "s16",
        "-c:a", "aac_at", "-aac_at_mode", "cvbr", "-b:a", "256k", "-aac_at_quality", "0",
        "-metadata", "title=T", "-metadata", "artist=A", "-metadata", "album=B", "-metadata", "album_artist=AA",
        "-metadata", "genre=G", "-metadata", "date=2020", "-metadata", "track=3/12", "-metadata", "disc=1/2",
        "-metadata", "compilation=1",
        "-movflags", "+faststart", "-f", "ipod", "/out/a.m4a",
    ])
}

@Test func resampleOnlyWhenNeeded() {
    #expect(args(.stockAAC, flac16x44).contains("-af") == false)
    #expect(args(.stockAAC, flac16x44).contains("s16"))
    #expect(args(.stockAAC, flac24x44).contains(resample))  // 24 -> 16 bit needs dither
    #expect(args(.stockAAC, flac24x96).contains(resample))
    #expect(args(.rockboxFLAC, flac16x44).contains("-af") == false)
    var surround = flac16x44
    surround.channels = 6
    #expect(args(.stockAAC, flac16x44).contains("-ac") == false)
    #expect(args(.stockAAC, surround).joined(separator: " ").contains("-ac 2"))
    var aac = MediaInfo(codec: "aac", profile: "LC", sampleRate: 44100, channels: 2, bitRate: 256000, durationSeconds: 1, container: "mp4")
    #expect(Preset.stockAAC.accepts(aac))
    aac.channels = 6
    #expect(Preset.stockAAC.accepts(aac) == false)
}

@Test func tvbrAAC() {
    var p = Preset.stockAAC
    p.codec = .aac(.tvbr(quality: 4))
    let a = args(p, flac16x44)
    #expect(a.contains("vbr") && a.contains("-q:a") && !a.contains("-b:a"))
}

@Test func rockboxFLACCommand() {
    let a = args(.rockboxFLAC, flac24x96, tags)
    #expect(a.contains(resample))
    #expect(a.contains("s16"))
    #expect(a.joined(separator: " ").contains("-c:a flac -compression_level 8"))
    #expect(a.contains("tracknumber=3") && a.contains("tracktotal=12") && a.contains("albumartist=AA"))
    #expect(a.suffix(3) == ["-f", "flac", "/out/a.m4a"])
    #expect(a.contains("-movflags") == false)
}

@Test func rockboxOpusCommand() {
    let a = args(.rockboxOpus, flac24x96)
    #expect(a.contains("aresample=48000:filter_size=64:phase_shift=10:cutoff=0.97:dither_method=triangular_hp"))
    #expect(a.contains("-sample_fmt") == false)
    #expect(a.joined(separator: " ").contains("-c:a libopus -b:a 128k -vbr on"))
    #expect(a.suffix(3) == ["-f", "opus", "/out/a.m4a"])
    let at48 = MediaInfo(codec: "flac", sampleRate: 48000, channels: 2, bitsPerSample: 24, durationSeconds: 3, container: "flac")
    #expect(args(.rockboxOpus, at48).contains("-af") == false)
}

@Test func tagsSkipEmptyValues() {
    let m = TrackTags(title: "T").metadata(vorbis: false)
    #expect(m.map(\.key) == ["title"])
}

@Test func presetsRoundTripThroughJSON() throws {
    let data = try JSONEncoder().encode(Preset.builtIns)
    #expect(try JSONDecoder().decode([Preset].self, from: data) == Preset.builtIns)
    #expect(Preset.builtIns.map(\.id) == ["stock-aac", "stock-alac", "rockbox-flac", "rockbox-opus"])
}

@Test func stockALACCommand() {
    let a = args(.stockALAC, flac24x96)
    #expect(a.contains(resample) && a.contains("s16"))
    #expect(a.joined(separator: " ").contains("-c:a alac -movflags +faststart"))
    #expect(a.suffix(3) == ["-f", "ipod", "/out/a.m4a"])
}

@Test func passthroughDecisionTable() {
    func info(_ codec: String, profile: String? = nil, rate: Int = 44100, kbps: Int = 256, bits: Int = 0,
              container: String) -> MediaInfo {
        MediaInfo(codec: codec, profile: profile, sampleRate: rate, channels: 2, bitsPerSample: bits,
                  bitRate: kbps * 1000, durationSeconds: 1, container: container)
    }
    let m4a = "mov,mp4,m4a,3gp,3g2,mj2"
    let table: [(MediaInfo, Preset, Bool)] = [
        (info("mp3", kbps: 320, container: "mp3"), .stockAAC, false),
        (info("mp3", rate: 44100, kbps: 128, container: "mp3"), .stockAAC, false),
        (info("aac", profile: "LC", kbps: 256, container: m4a), .stockAAC, false),
        (info("aac", profile: "LC", rate: 48000, kbps: 320, container: m4a), .stockAAC, false),
        (info("aac", profile: "LC", kbps: 321, container: m4a), .stockAAC, true),
        (info("aac", profile: "LC", rate: 96000, kbps: 256, container: m4a), .stockAAC, true),
        (info("aac", profile: "HE-AAC", kbps: 64, container: m4a), .stockAAC, true),
        (info("aac", profile: "LC", kbps: 128, container: "aac"), .stockAAC, true),  // raw ADTS
        (info("alac", bits: 16, container: m4a), .stockAAC, true),
        (info("flac", bits: 16, container: "flac"), .stockAAC, true),
        (info("opus", container: "ogg"), .stockAAC, true),
        (info("flac", bits: 16, container: "flac"), .rockboxFLAC, false),
        (info("flac", bits: 24, container: "flac"), .rockboxFLAC, true),
        (info("flac", rate: 96000, bits: 16, container: "flac"), .rockboxFLAC, true),
        (info("mp3", container: "mp3"), .rockboxFLAC, true),
        (info("flac", bits: 16, container: "flac"), .rockboxOpus, true),
        (info("alac", bits: 16, container: m4a), .stockALAC, false),
        (info("alac", bits: 24, container: m4a), .stockALAC, true),
        (info("aac", profile: "LC", kbps: 256, container: m4a), .stockALAC, false),
        (info("flac", bits: 16, container: "flac"), .stockALAC, true),
    ]
    for (source, preset, expected) in table {
        #expect(FFmpeg.needsTranscode(source: source, preset: preset) == expected, "\(source.codec) \(source.sampleRate) -> \(preset.id)")
    }
}

@Test func mediaInfoFromFFprobeJSON() throws {
    let json = """
    {"streams":[{"codec_type":"audio","codec_name":"flac","sample_rate":"96000","channels":2,
    "bits_per_sample":0,"bits_per_raw_sample":"24","duration":"3.000000"}],
    "format":{"format_name":"flac","duration":"3.0","size":"1234","bit_rate":"900000"}}
    """
    let info = try MediaInfo(ffprobeJSON: Data(json.utf8))
    #expect(info == MediaInfo(codec: "flac", sampleRate: 96000, channels: 2, bitsPerSample: 24, bitRate: 900000,
                              durationSeconds: 3, size: 1234, container: "flac"))
}
