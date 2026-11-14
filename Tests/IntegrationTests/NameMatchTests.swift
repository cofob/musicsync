import Testing
@testable import Integration

@Suite struct NameMatchTests {
    private let names = ["Night Echo", "Echo", "Echoes of Blue", "Blue Echo Night", "Café del Mar", "Ｗide"]

    private func rank(_ text: String) -> [String] { NameMatch.rank(names, by: { $0 }, matching: text) }

    @Test func sameNameThenPrefixThenWords() {
        #expect(rank("echo") == ["Echo", "Echoes of Blue", "Night Echo", "Blue Echo Night"])
        #expect(rank("night echo") == ["Night Echo", "Blue Echo Night"])
    }

    @Test func ignoresCaseAccentsAndWidth() {
        #expect(rank("  CAFE ") == ["Café del Mar"])
        #expect(rank("wide") == ["Ｗide"])
    }

    @Test func emptyOrUnknownTextFindsNothing() {
        #expect(rank("").isEmpty)
        #expect(rank("   ").isEmpty)
        #expect(rank("ocean").isEmpty)
    }
}
