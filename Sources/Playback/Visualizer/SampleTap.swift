import AVFoundation
import Synchronization

/// The last second of what the audio taps put out, for the visualizer. The taps write on the audio thread
/// without waiting or allocating; the main thread reads the frames that play now.
public final class SampleTap: Sendable {
    static let capacity = 32768
    /// The tap gets audio ahead of the output; reads go back at most this far.
    static let maxDelay: TimeInterval = 0.5

    private struct Ring {
        var left = [Float](repeating: 0, count: SampleTap.capacity)
        var right = [Float](repeating: 0, count: SampleTap.capacity)
        /// Index of the next frame to write.
        var head = 0
        /// Item time just after the last written frame.
        var end: TimeInterval = 0
        var sampleRate: Double = 44100
    }

    private let ring = Mutex(Ring())
    private let on = Atomic<Bool>(false)

    public init() {}

    /// Off: the taps write nothing.
    public var isOn: Bool {
        get { on.load(ordering: .relaxed) }
        set { on.store(newValue, ordering: .relaxed) }
    }

    /// Copies 32-bit float frames, interleaved or not; one channel goes to both sides. Skips the buffer when a reader holds the lock.
    func write(_ list: UnsafeMutableAudioBufferListPointer, frames: Int, time: TimeInterval, sampleRate: Double) {
        guard isOn, frames > 0 else { return }
        _ = ring.withLockIfAvailable { r in
            let first = list.first.flatMap { b in b.mData.map { ($0.assumingMemoryBound(to: Float.self), Int(b.mNumberChannels)) } }
            guard let (data, stride) = first, stride > 0 else { return }
            // Planar stereo has the right channel in the second buffer; interleaved has it at offset 1.
            let rightData: UnsafeMutablePointer<Float>, rightOffset: Int
            if stride > 1 { rightData = data; rightOffset = 1 }
            else if list.count > 1, let d = list[1].mData { rightData = d.assumingMemoryBound(to: Float.self); rightOffset = 0 }
            else { rightData = data; rightOffset = 0 }
            for frame in 0..<frames {
                r.left[r.head] = data[frame * stride]
                r.right[r.head] = rightData[frame * stride + rightOffset]
                r.head = (r.head + 1) % Self.capacity
            }
            r.end = time.isFinite ? time + Double(frames) / sampleRate : r.end
            r.sampleRate = sampleRate
        }
    }

    /// Rate of the last written audio.
    public var sampleRate: Double { ring.withLock { $0.sampleRate } }

    /// The `count` frames that end at item time `time` (the newest ones when the tap is not ahead of it).
    public func latest(_ count: Int, at time: TimeInterval) -> (left: [Float], right: [Float]) {
        let count = min(count, Self.capacity / 2)
        return ring.withLock { r in
            let delay = min(max(r.end - time, 0), Self.maxDelay)
            let back = Int(delay * r.sampleRate)
            let start = (r.head - back - count + 2 * Self.capacity) % Self.capacity
            let indexes = (0..<count).map { (start + $0) % Self.capacity }
            return (indexes.map { r.left[$0] }, indexes.map { r.right[$0] })
        }
    }
}
