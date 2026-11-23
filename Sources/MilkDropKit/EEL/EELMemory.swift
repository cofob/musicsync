/// megabuf of one preset; all scopes of that preset share it.
/// 8M doubles in blocks of 64K, allocated on the first write; unwritten cells read 0.
public final class EELMemory {
    static let blockSize = 65536
    static let blockCount = 128
    static let size = blockSize * blockCount

    private var blocks = [UnsafeMutablePointer<Double>?](repeating: nil, count: blockCount)

    public init() {}

    deinit { blocks.forEach { $0?.deallocate() } }

    /// The cell at `floor(index)`. Out of range reads 0 and ignores writes.
    subscript(index: Double) -> Double {
        get {
            guard let i = Self.cell(index), let block = blocks[i / Self.blockSize] else { return 0 }
            return block[i % Self.blockSize]
        }
        set {
            guard let i = Self.cell(index) else { return }
            block(i / Self.blockSize)[i % Self.blockSize] = newValue
        }
    }

    /// EEL `memcpy(dest, src, count)`: copies like `memmove`, clipped to the buffer as butterchurn does. Returns `dest`.
    func copy(to dest: Double, from src: Double, count: Double) -> Double {
        var (d, s, n) = (dest.rounded(.down), src.rounded(.down), count.rounded(.down))
        if s < 0 { (n, d, s) = (n + s, d - s, 0) }
        if d < 0 { (n, s, d) = (n + d, s - d, 0) }
        n = min(n, Double(Self.size) - max(d, s))
        if d < s {
            var k = 0.0
            while k < n { self[d + k] = self[s + k]; k += 1 }
        } else if d > s {
            var k = n - 1
            while k >= 0 { self[d + k] = self[s + k]; k -= 1 }
        }
        return dest
    }

    /// EEL `memset(dest, value, count)`, clipped to the buffer. Returns `dest`.
    func fill(_ dest: Double, value: Double, count: Double) -> Double {
        let d = max(dest.rounded(.down), 0)
        let n = min(count.rounded(.down), Double(Self.size) - d)
        var k = 0.0
        while k < n { self[d + k] = value; k += 1 }
        return dest
    }

    private static func cell(_ index: Double) -> Int? {
        let i = index.rounded(.down)
        return i >= 0 && i < Double(size) ? Int(i) : nil
    }

    private func block(_ n: Int) -> UnsafeMutablePointer<Double> {
        if let block = blocks[n] { return block }
        let block = UnsafeMutablePointer<Double>.allocate(capacity: Self.blockSize)
        block.initialize(repeating: 0, count: Self.blockSize)
        blocks[n] = block
        return block
    }
}

/// reg00..reg99 and gmegabuf: shared by all presets, survive preset changes.
public final class EELGlobals: @unchecked Sendable {
    let regs = UnsafeMutablePointer<Double>.allocate(capacity: 100)
    let gmegabuf = EELMemory()

    public init() { regs.initialize(repeating: 0, count: 100) }

    deinit { regs.deallocate() }
}
