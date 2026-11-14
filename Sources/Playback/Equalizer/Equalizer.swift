import AVFoundation
import MediaToolbox
import Synchronization

/// The equalizer gains shared by the audio taps of all items. The main thread sets them; each tap reads
/// them on its audio thread without waiting for the lock, and its filters ramp to them.
public final class Equalizer: Sendable {
    private let shared = Mutex((generation: 0, gains: EqualizerGains.flat))
    private let frames = Atomic<Int>(0)
    let recorder: TapRecorder?

    /// `recorder` keeps what the taps put out (tests and dev tools).
    public init(recorder: TapRecorder? = nil) { self.recorder = recorder }

    public func set(_ gains: EqualizerGains) {
        shared.withLock { if $0.gains != gains { $0.generation += 1; $0.gains = gains } }
    }

    /// Frames the taps filtered so far: shows that the equalizer runs.
    public var processedFrames: Int { frames.load(ordering: .relaxed) }

    /// An audio tap for one track that runs the equalizer; nil when MediaToolbox cannot make one.
    /// After the mix volume, as it adds less start delay there than before it. `item` names the recorded audio.
    public func makeTap(for item: AVPlayerItem? = nil) -> MTAudioProcessingTap? {
        let context = Unmanaged.passRetained(TapContext(self, item: item.map(ObjectIdentifier.init)))
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0, clientInfo: context.toOpaque(),
            init: { _, info, storage in storage.pointee = info },
            finalize: { tap in Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release() },
            prepare: { tap, _, format in TapContext.of(tap).prepare(format.pointee) },
            unprepare: { tap in TapContext.of(tap).processor = nil },
            process: { tap, frames, _, buffers, framesOut, flagsOut in
                var range = CMTimeRange.invalid
                guard MTAudioProcessingTapGetSourceAudio(tap, frames, buffers, flagsOut, &range, framesOut) == noErr else { return }
                TapContext.of(tap).process(buffers, frames: framesOut.pointee, time: range.start.seconds)
            })
        var tap: MTAudioProcessingTap?
        guard MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap) == noErr else {
            context.release()
            return nil
        }
        return tap
    }

    /// Hands new gains to `processor` when they changed since `generation`; skips this time when the main thread holds the lock.
    fileprivate func sync(_ processor: EqualizerProcessor, _ generation: inout Int) {
        let seen = generation
        if let new = shared.withLockIfAvailable({ value -> Int? in
            guard value.generation != seen else { return nil }
            processor.set(value.gains)
            return value.generation
        }), let new { generation = new }
    }

    fileprivate func current() -> (generation: Int, gains: EqualizerGains) { shared.withLock { $0 } }

    fileprivate func count(_ n: Int) { frames.add(n, ordering: .relaxed) }
}

/// Tap storage: the filters for the format the tap reports. Its callbacks come one at a time.
private final class TapContext {
    let equalizer: Equalizer
    let item: ObjectIdentifier?
    var processor: EqualizerProcessor?
    var generation = 0

    init(_ equalizer: Equalizer, item: ObjectIdentifier?) {
        self.equalizer = equalizer
        self.item = item
    }

    static func of(_ tap: MTAudioProcessingTap) -> TapContext {
        Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
    }

    /// Only 32-bit float PCM is filtered; other formats play as they are.
    func prepare(_ format: AudioStreamBasicDescription) {
        guard format.mFormatID == kAudioFormatLinearPCM, format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32, format.mSampleRate > 0 else { processor = nil; return }
        let now = equalizer.current()
        generation = now.generation
        processor = EqualizerProcessor(sampleRate: format.mSampleRate, channels: Int(format.mChannelsPerFrame), gains: now.gains)
    }

    func process(_ buffers: UnsafeMutablePointer<AudioBufferList>, frames: CMItemCount, time: TimeInterval) {
        guard let processor else { return }
        let list = UnsafeMutableAudioBufferListPointer(buffers)
        equalizer.sync(processor, &generation)
        processor.process(list, frames: frames)
        equalizer.count(frames)
        if let recorder = equalizer.recorder, let item {
            recorder.record(list, frames: frames, item: item, tap: ObjectIdentifier(self), time: time, sampleRate: processor.sampleRate)
        }
    }
}
