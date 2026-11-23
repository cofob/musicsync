import Metal

/// The noise textures shaders sample (`sampler_noise_lq` …), made as butterchurn makes them: random RGBA bytes,
/// smoothed with cubic interpolation between points `zoom` apart.
enum Noise {
    /// RGBA bytes of a `size`×`size` texture.
    static func plane(size: Int, zoom: Int, random: () -> Double = { .random(in: 0..<1) }) -> [UInt8] {
        var r = randomBytes(size * size, zoom: zoom, random: random)
        guard zoom > 1 else { return r }
        let e = size, i = zoom
        for n in stride(from: 0, to: e, by: i) {
            for l in 0..<e where l % i != 0 {
                let m = l / i * i + e, u = n * e
                smooth(&r, at: n * e * 4 + 4 * l, t: Double(l % i) / Double(i)) { k in 4 * u + (m + k * i) % e * 4 }
            }
        }
        for x in 0..<e {
            for b in 0..<e where b % i != 0 {
                let t = b / i * i + e
                smooth(&r, at: b * e * 4 + 4 * x, t: Double(b % i) / Double(i)) { k in (t + k * i) % e * e * 4 + 4 * x }
            }
        }
        return r
    }

    /// RGBA bytes of a `size`³ volume texture.
    static func volume(size: Int, zoom: Int, random: () -> Double = { .random(in: 0..<1) }) -> [UInt8] {
        var r = randomBytes(size * size * size, zoom: zoom, random: random)
        guard zoom > 1 else { return r }
        let e = size, i = zoom, n = e * e, l = e
        for m in stride(from: 0, to: e, by: i) {
            for u in stride(from: 0, to: e, by: i) {
                for g in 0..<e where g % i != 0 {
                    let c = g / i * i + e, a = m * n + u * l
                    smooth(&r, at: m * n * 4 + u * l * 4 + 4 * g, t: Double(g % i) / Double(i)) { k in 4 * a + (c + k * i) % e * 4 }
                }
            }
        }
        for z in stride(from: 0, to: e, by: i) {
            for p in 0..<e {
                for y in 0..<e where y % i != 0 {
                    let c = y / i * i + e, s = z * n
                    smooth(&r, at: y * l * 4 + 4 * p + 4 * s, t: Double(y % i) / Double(i)) { k in (c + k * i) % e * l * 4 + 4 * p + 4 * s }
                }
            }
        }
        for d0 in 0..<e {
            for v in 0..<e {
                for w in 0..<e where w % i != 0 {
                    let c = w / i * i + e, x = v * l
                    smooth(&r, at: w * n * 4 + 4 * d0 + 4 * x, t: Double(v % i) / Double(i)) { k in (c + k * i) % e * n * 4 + 4 * d0 + 4 * x }
                }
            }
        }
        return r
    }

    /// Bytes as butterchurn stores them: `floor(random*a + a/2)` written into a `Uint8Array`, which wraps.
    private static func randomBytes(_ count: Int, zoom: Int, random: () -> Double) -> [UInt8] {
        let a = zoom > 1 ? 216.0 : 256.0
        return (0..<count * 4).map { _ in UInt8(truncatingIfNeeded: Int((random() * a + a / 2).rounded(.down))) }
    }

    /// Writes the cubic interpolation at `t` of the four pixels at `offset(-1 … 2)` into the pixel at `index`.
    private static func smooth(_ bytes: inout [UInt8], at index: Int, t: Double, _ offset: (Int) -> Int) {
        let offsets = (-1...2).map(offset)
        for d in 0..<4 {
            let p = offsets.map { Double(bytes[$0 + d]) / 255 }
            let t2 = t * t, h = p[3] - p[2] - p[0] + p[1]
            let value = h * t * t2 + (p[0] - p[1] - h) * t2 + (p[2] - p[0]) * t + p[1]
            bytes[index + d] = UInt8(truncatingIfNeeded: Int(min(max(value, 0), 1) * 255))
        }
    }

    /// noise_lq, noise_mq, noise_hq (256², with mipmaps) and noisevol_lq, noisevol_hq (32³).
    struct Textures {
        let lq, mq, hq, volumeLQ, volumeHQ: MTLTexture
    }

    static func makeTextures(device: MTLDevice, queue: MTLCommandQueue, random: () -> Double) -> Textures? {
        guard let lq = texture(device, plane(size: 256, zoom: 1, random: random), size: 256),
              let mq = texture(device, plane(size: 256, zoom: 4, random: random), size: 256),
              let hq = texture(device, plane(size: 256, zoom: 8, random: random), size: 256),
              let vlq = texture(device, volume(size: 32, zoom: 1, random: random), size: 32, depth: 32),
              let vhq = texture(device, volume(size: 32, zoom: 4, random: random), size: 32, depth: 32) else { return nil }
        if let buffer = queue.makeCommandBuffer(), let blit = buffer.makeBlitCommandEncoder() {
            for t in [lq, mq, hq, vlq, vhq] { blit.generateMipmaps(for: t) }
            blit.endEncoding()
            buffer.commit()
        }
        return Textures(lq: lq, mq: mq, hq: hq, volumeLQ: vlq, volumeHQ: vhq)
    }

    private static func texture(_ device: MTLDevice, _ bytes: [UInt8], size: Int, depth: Int = 1) -> MTLTexture? {
        let d = MTLTextureDescriptor()
        d.textureType = depth > 1 ? .type3D : .type2D
        d.pixelFormat = .rgba8Unorm
        (d.width, d.height, d.depth) = (size, size, depth)
        d.mipmapLevelCount = Int(log2(Double(size))) + 1
        d.usage = .shaderRead
        guard let t = device.makeTexture(descriptor: d) else { return nil }
        bytes.withUnsafeBytes {
            t.replace(region: MTLRegionMake3D(0, 0, 0, size, size, depth), mipmapLevel: 0, slice: 0,
                      withBytes: $0.baseAddress!, bytesPerRow: size * 4, bytesPerImage: size * size * 4)
        }
        return t
    }
}
