public extension Sequence<UInt8> {
    /// Lowercase hex, two digits per byte.
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
