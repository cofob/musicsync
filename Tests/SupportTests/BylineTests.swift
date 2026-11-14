import Testing
@testable import Support

@Test func bylineJoinsTheParts() {
    #expect(byline("Artist", "Album") == "Artist — Album")
    #expect(byline("Artist", nil) == "Artist")
    #expect(byline(nil, "", "Album") == "Album")
}

@Test func bylineShowsASameNameOnce() {
    #expect(byline("Show", "Show") == "Show")
    #expect(byline("Song", "Show", "Show") == "Song — Show")
}
