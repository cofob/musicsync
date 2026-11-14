/// "Artist — Album" from the parts that are there. A part equal to the one before it shows once: a podcast
/// episode has the show name as artist and as album.
public func byline(_ parts: String?...) -> String {
    var shown: [String] = []
    for case let part? in parts where !part.isEmpty && part != shown.last { shown.append(part) }
    return shown.joined(separator: " — ")
}
