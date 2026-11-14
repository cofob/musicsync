import Testing
@testable import Support

@Test func shortTextIsKept() {
    #expect("Hello".truncated(to: 5) == "Hello")
    #expect("".truncated(to: 3) == "")
}

@Test func longTextEndsInEllipsis() {
    #expect("Hello World".truncated(to: 8) == "Hello W…")
    #expect("Hello World".truncated(to: 8).count == 8)
}

@Test func cutDropsTrailingSpace() {
    #expect("Hello World".truncated(to: 7) == "Hello…")
}

@Test func cutKeepsWholeCharacters() {
    #expect("Café 🇫🇷 Song".truncated(to: 7) == "Café 🇫🇷…")
}
