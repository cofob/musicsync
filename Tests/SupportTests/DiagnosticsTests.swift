import Foundation
import Support
import Testing

@Suite struct RedactTests {
    @Test func removesCredentials() {
        let url = "https://music.example.com/rest/stream?u=me&t=abc123&s=salt9&v=1.16&c=MusicSync&id=7"
        let clean = Redact.secrets(in: url)
        #expect(!clean.contains("abc123") && !clean.contains("salt9") && !clean.contains("u=me"))
        #expect(clean.contains("id=7") && clean.contains("v=1.16"))
        #expect(Redact.secrets(in: #"{"password":"hunter2","name":"x"}"#) == #"{"password":"[redacted]","name":"x"}"#)
        #expect(Redact.secrets(in: "Authorization: Bearer eyJ.abc-def") == "Authorization: Bearer [redacted]")
        #expect(Redact.secrets(in: "plain text") == "plain text")
    }
}

@Suite struct DiskCacheTests {
    @Test func trimsOldestFirst() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("diskcache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for (i, name) in ["a", "b", "sub/c"].enumerated() {
            let url = dir.appendingPathComponent(name)
            try Data(count: 100).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(i) * 1000)], ofItemAtPath: url.path)
        }
        #expect(DiskCache.size(of: dir) == 300)
        #expect(DiskCache.trim(dir, to: 500) == 0)
        #expect(DiskCache.trim(dir, to: 150) == 2)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("sub/c").path))
        #expect(DiskCache.size(of: dir) == 100)
        DiskCache.clear(dir)
        #expect(DiskCache.size(of: dir) == 0)
        #expect(FileManager.default.fileExists(atPath: dir.path))
    }
}
