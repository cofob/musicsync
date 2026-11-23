import Dispatch
import Metal

/// Per-frame vertex data in a few reused buffers instead of new ones each frame (the driver kept the memory of those:
/// over 100 MB after a few hundred frames). At most `count` frames are in flight; `begin` waits for the oldest.
final class FrameArenas {
    private let device: MTLDevice
    private var buffers: [MTLBuffer?]
    private let free: DispatchSemaphore
    private var index = 0, used = 0

    init(device: MTLDevice, count: Int = 3) {
        self.device = device
        buffers = Array(repeating: nil, count: count)
        free = DispatchSemaphore(value: count)
    }

    /// Starts a frame on `commandBuffer`: waits until a buffer is free, and frees it again when the GPU is done.
    func begin(_ commandBuffer: MTLCommandBuffer) {
        free.wait()
        index = (index + 1) % buffers.count
        used = 0
        commandBuffer.addCompletedHandler { [free] _ in free.signal() }
    }

    /// Copies `bytes` into this frame's buffer; returns the buffer and the offset to bind.
    func append(_ bytes: UnsafeRawBufferPointer) -> (MTLBuffer, Int)? {
        let offset = (used + 255) & ~255  // vertex buffer offsets must be aligned
        let needed = offset + bytes.count
        if (buffers[index]?.length ?? 0) < needed {
            // Grows by half again, so a big frame does not make a new buffer each time. Draws already encoded keep
            // the old buffer alive and bound; the rest of the frame goes to the new one, from its start.
            guard let bigger = device.makeBuffer(length: max(needed * 3 / 2, 1 << 20), options: .storageModeShared) else { return nil }
            buffers[index] = bigger
            used = 0
            return append(bytes)
        }
        guard let buffer = buffers[index], let base = bytes.baseAddress else { return nil }
        (buffer.contents() + offset).copyMemory(from: base, byteCount: bytes.count)
        used = needed
        return (buffer, offset)
    }
}
