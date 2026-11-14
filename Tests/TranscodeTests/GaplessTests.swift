import Foundation
import Testing
@testable import Transcode

private func be32(_ v: Int) -> Data { Data([24, 16, 8, 0].map { UInt8(truncatingIfNeeded: v >> $0) }) }
private func box(_ type: String, _ payload: Data...) -> Data {
    let body = payload.reduce(Data(), +)
    return be32(body.count + 8) + Data(type.utf8) + body
}
private let fullHeader = Data(count: 4)

private func mp4(frames: Int, elst: (duration: Int, mediaTime: Int)?, smpb: String? = nil) -> Data {
    let mvhd = box("mvhd", fullHeader, Data(count: 8), be32(44100), Data(count: 80))
    let mdhd = box("mdhd", fullHeader, Data(count: 8), be32(44100), Data(count: 8))
    let stts = box("stts", fullHeader, be32(2), be32(frames - 1), be32(1024), be32(1), be32(64))
    let mdia = box("mdia", mdhd, box("minf", box("stbl", stts)))
    var trak = box("trak", mdia)
    if let e = elst {
        let edts = box("edts", box("elst", fullHeader, be32(1), be32(e.duration), be32(e.mediaTime), be32(0x10000)))
        trak = box("trak", edts, mdia)
    }
    var udta = Data()
    if let smpb {
        let item = box("----", box("mean", fullHeader, Data("com.apple.iTunes".utf8)), box("name", fullHeader, Data("iTunSMPB".utf8)),
                       box("data", be32(1), be32(0), Data(smpb.utf8)))
        udta = box("udta", box("meta", fullHeader, box("hdlr", Data(count: 24)), box("ilst", item)))
    }
    return box("ftyp", Data("M4A ".utf8), Data(count: 8)) + box("moov", mvhd, trak, udta) + box("mdat", Data(count: 16))
}

@Test func elstValues() throws {
    // 133 frames = 136192 samples; ffmpeg style: duration = frames*1024 - 2112 (rounded up to whole frames).
    let g = try Gapless.parse(mp4(frames: 133, elst: (133120, 2112)))
    #expect(g == GaplessInfo(pregap: 2112, postgap: 960, sampleCount: 133120))
}

@Test func elstWithExactSampleCount() throws {
    let g = try Gapless.parse(mp4(frames: 133, elst: (133120, 2112)), exactSampleCount: 132300)
    #expect(g == GaplessInfo(pregap: 2112, postgap: 1780, sampleCount: 132300))
}

@Test func missingElstAssumesAppleEncoderDelay() throws {
    let g = try Gapless.parse(mp4(frames: 133, elst: nil), exactSampleCount: 132300)
    #expect(g == GaplessInfo(pregap: 2112, postgap: 1780, sampleCount: 132300))
}

@Test func iTunSMPBWins() throws {
    let smpb = " 00000000 00000840 000001CC 000000000000A6A4 00000000 00000000"
    let g = try Gapless.parse(mp4(frames: 133, elst: (133120, 2112), smpb: smpb))
    #expect(g == GaplessInfo(pregap: 0x840, postgap: 0x1CC, sampleCount: 0xA6A4))
}

@Test func garbageThrows() {
    #expect(throws: TranscodeError.self) { try Gapless.parse(Data(count: 3)) }
    #expect(throws: TranscodeError.self) { try Gapless.parse(box("ftyp", Data(count: 8))) }
}
