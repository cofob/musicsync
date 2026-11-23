import Metal

/// The two frame textures MilkDrop feeds back: each frame warps `prev` into `target`, draws on it, then they swap.
/// 8-bit, as butterchurn's, so the fade of `decay` steps the same way. Rows are stored as in GL (row 0 at the bottom),
/// so offscreen passes flip clip y; only the final pass to the screen does not (see `FixedShaders`).
struct Targets {
    static let format = MTLPixelFormat.rgba8Unorm
    private(set) var prev: MTLTexture
    private(set) var target: MTLTexture
    var size: SIMD2<Int> { SIMD2(target.width, target.height) }

    init?(device: MTLDevice, size: SIMD2<Int>) {
        guard let a = Self.texture(device, size, mipmapped: true), let b = Self.texture(device, size, mipmapped: true) else { return nil }
        prev = a
        target = b
    }

    mutating func swap() { (prev, target) = (target, prev) }

    static func texture(_ device: MTLDevice, _ size: SIMD2<Int>, mipmapped: Bool = false) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: max(size.x, 1), height: max(size.y, 1), mipmapped: mipmapped)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        return device.makeTexture(descriptor: d)
    }
}
