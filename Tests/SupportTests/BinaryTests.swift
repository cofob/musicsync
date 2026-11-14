import Foundation
import Testing
@testable import Support

@Test func roundTripIntegers() throws {
    var w = BinaryWriter()
    w.tag("mhbd")
    w.u32(0xF4)
    w.u16(0xBEEF)
    w.u64(0x0102_0304_0506_0708)
    w.utf16le("Hé")
    w.patchU32(0xDEAD_BEEF, at: 4)

    let r = BinaryReader(w.data)
    try r.expectTag("mhbd", at: 0)
    #expect(try r.u32(at: 4) == 0xDEAD_BEEF)
    #expect(try r.u16(at: 8) == 0xBEEF)
    #expect(try r.u64(at: 10) == 0x0102_0304_0506_0708)
    #expect(try r.utf16le(at: 18, byteCount: 4) == "Hé")
    #expect(Array(w.data[4..<8]) == [0xEF, 0xBE, 0xAD, 0xDE])
}

@Test func outOfBoundsThrows() {
    let r = BinaryReader(Data([1, 2]))
    #expect(throws: BinaryError.self) { try r.u32(at: 0) }
}

@Test func alignPads() {
    var w = BinaryWriter()
    w.zeros(5)
    w.align(4)
    #expect(w.count == 8)
}
