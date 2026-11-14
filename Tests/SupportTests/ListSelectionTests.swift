import Testing
@testable import Support

private let rows = ["a", "b", "c", "d", "e"]

@Test func clickSelectsOneRow() {
    var s = ListSelection<String>()
    s.click("b")
    s.click("d")
    #expect(s.selected == ["d"])
    #expect(s.anchor == "d")
}

@Test func toggleAddsAndRemoves() {
    var s = ListSelection<String>()
    s.click("a")
    s.toggle("c")
    #expect(s.ordered(in: rows) == ["a", "c"])
    s.toggle("a")
    #expect(s.ordered(in: rows) == ["c"])
}

@Test func extendSelectsTheRangeFromTheAnchor() {
    var s = ListSelection<String>()
    s.click("b")
    s.extend(to: "d", in: rows)
    #expect(s.ordered(in: rows) == ["b", "c", "d"])
    // Upwards from the same anchor replaces the range.
    s.extend(to: "a", in: rows)
    #expect(s.ordered(in: rows) == ["a", "b"])
    #expect(s.anchor == "b")
}

@Test func extendAfterToggleKeepsTheOtherRows() {
    var s = ListSelection<String>()
    s.click("a")
    s.toggle("d")
    s.extend(to: "e", in: rows)
    #expect(s.ordered(in: rows) == ["a", "d", "e"])
    // A second ⇧-click replaces only the range.
    s.extend(to: "c", in: rows)
    #expect(s.ordered(in: rows) == ["a", "c", "d"])
}

@Test func extendWithoutAnchorIsAClick() {
    var s = ListSelection<String>()
    s.extend(to: "c", in: rows)
    #expect(s.selected == ["c"])
    // An anchor that left the list (filtered out) counts as none.
    s.extend(to: "e", in: ["d", "e"])
    #expect(s.selected == ["e"])
}

@Test func selectAllAndClear() {
    var s = ListSelection<String>()
    s.selectAll(rows)
    #expect(s.count == 5)
    s.clear()
    #expect(s.isEmpty)
    #expect(s.anchor == nil)
}

@Test func selectionFollowsRowsWhenTheListChanges() {
    var s = ListSelection<String>()
    s.click("b")
    s.toggle("d")
    #expect(s.ordered(in: rows.reversed()) == ["d", "b"])
    #expect(s.ordered(in: ["d", "e"]) == ["d"])
    // Filtered rows come back still selected.
    #expect(s.ordered(in: rows) == ["b", "d"])
}
