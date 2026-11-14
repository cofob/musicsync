import AVFoundation
import Synchronization

/// Keeps a copy of what the equalizer taps put out, with the item time of each buffer, to measure the real
/// playback output while the player is muted. It allocates on the audio thread: for tests and dev tools only.
public final class TapRecorder: Sendable {
    public struct Buffer: Sendable {
        /// Identity of the `AVPlayerItem`.
        public var item: ObjectIdentifier
        /// Identity of the tap: a new audio mix gives the item a new one.
        public var tap: ObjectIdentifier
        /// Item time of the first frame, as the tap reports it.
        public var time: TimeInterval
        /// Host time at which the tap got the buffer.
        public var host: TimeInterval
        public var sampleRate: Double
        public var channels: Int
        /// Interleaved frames.
        public var samples: [Float]
    }

    private let buffers = Mutex<[Buffer]>([])

    public init() {}

    public var recorded: [Buffer] { buffers.withLock { $0 } }

    public func clear() { buffers.withLock { $0.removeAll() } }

    func record(_ list: UnsafeMutableAudioBufferListPointer, frames: Int, item: ObjectIdentifier, tap: ObjectIdentifier, time: TimeInterval, sampleRate: Double) {
        let channels = list.reduce(0) { $0 + Int($1.mNumberChannels) }
        guard channels > 0, frames > 0, time.isFinite else { return }
        var samples = [Float](repeating: 0, count: frames * channels)
        var channel = 0
        for buffer in list {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let stride = Int(buffer.mNumberChannels)
            for offset in 0..<stride {
                for frame in 0..<frames { samples[frame * channels + channel] = data[frame * stride + offset] }
                channel += 1
            }
        }
        let host = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        let new = Buffer(item: item, tap: tap, time: time, host: host, sampleRate: sampleRate, channels: channels, samples: samples)
        buffers.withLock { $0.append(new) }
    }
}
