import Foundation

/// One thumbnail format of the iPod: RGB565 little-endian, no row padding.
public struct ArtworkFormat: Sendable, Hashable {
    public let id: Int
    public let width: Int
    public let height: Int

    public var byteSize: Int { width * height * 2 }

    public init(id: Int, width: Int, height: Int) {
        self.id = id
        self.width = width
        self.height = height
    }

    /// iPod classic / nano 3G cover art formats, in libgpod order.
    public static let classic: [ArtworkFormat] = [
        ArtworkFormat(id: 1061, width: 56, height: 56),
        ArtworkFormat(id: 1055, width: 128, height: 128),
        ArtworkFormat(id: 1068, width: 128, height: 128),
        ArtworkFormat(id: 1060, width: 320, height: 320),
    ]
}
