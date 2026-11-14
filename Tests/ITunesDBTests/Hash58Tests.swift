import Foundation
import Testing
@testable import ITunesDB

@Suite struct Hash58Tests {
    /// Known answers produced by libgpod 0.8.3 `itdb_hash58.c` (compiled standalone) on the same input.
    private func buffer() -> Data {
        var d = Data((0..<0x400).map { UInt8(truncatingIfNeeded: $0 * 7 + 3) })
        d.replaceSubrange(0..<4, with: Data("mhbd".utf8))
        return d
    }

    @Test func keyMatchesLibgpod() throws {
        let key = Hash58.key(guid: try Hash58.parseGuid("0x000A27001234ABCD"))
        #expect(hex(key) == "7656555989011358f15b51f7bf00c518ffd9109e")
    }

    @Test(arguments: [
        ("000A27001234ABCD", "a9dd53077f42846b37754a36abfe518a3d5a2312"),
        ("00002704000506FF", "9d69ebda8fb18ee7c9351e63c64dce68877c0231"),
    ])
    func signMatchesLibgpod(guid: String, expected: String) throws {
        let original = buffer()
        var signed = original
        Hash58.sign(&signed, guid: try Hash58.parseGuid(guid))
        #expect(hex(signed[0x58..<0x6C]) == expected)
        #expect(signed[0x30] == 1 && signed[0x31] == 0)
        // Everything else (including db_id and the 0x32 block) is restored.
        let changed = Set(original.indices.filter { original[$0] != signed[$0] })
        #expect(changed.isSubset(of: Set([0x30, 0x31] + Array(0x58..<0x6C))))
        #expect(Hash58.verify(signed, guid: try Hash58.parseGuid(guid)))
    }

    @Test func verifyRejectsWrongGuidAndTampering() throws {
        var signed = buffer()
        let guid = try Hash58.parseGuid("000A27001234ABCD")
        Hash58.sign(&signed, guid: guid)
        #expect(!Hash58.verify(signed, guid: try Hash58.parseGuid("000A27001234ABCE")))
        signed[0x200] ^= 1
        #expect(!Hash58.verify(signed, guid: guid))
    }

    @Test func serializedDatabaseVerifies() throws {
        let guid = try Hash58.parseGuid("0x000A27001234ABCD")
        let data = try sampleDB().serialize(firewireGuid: guid)
        #expect(Hash58.verify(data, guid: guid))
        #expect(!Hash58.verify(try sampleDB().serialize(), guid: guid))
    }

    @Test func guidParsing() throws {
        #expect(try Hash58.parseGuid("0x000A27001234ABCD") == [0, 0x0A, 0x27, 0, 0x12, 0x34, 0xAB, 0xCD])
        #expect(try Hash58.parseGuid("000a27001234abcd") == [0, 0x0A, 0x27, 0, 0x12, 0x34, 0xAB, 0xCD])
        #expect(throws: Hash58.GuidError.self) { try Hash58.parseGuid("12345") }
        #expect(throws: Hash58.GuidError.self) { try Hash58.parseGuid("zz0A27001234ABCD") }
    }
}
