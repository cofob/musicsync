import AVFoundation
@testable import Playback

/// What the speakers get from a muted mixer. The equalizer tap sits after the time-pitch unit, so one item's
/// recording is its output, frame after frame on the clock; its place on the host clock comes from lining it up
/// with the item's own audio at the times the item timebase gives. The fade volume the mixer sets on each deck
/// is polled every 5 ms with the timebases.
@MainActor final class OutputCapture {
    struct DeckState {
        var item: ObjectIdentifier?
        /// Item time at the poll's host time.
        var time: Double
        /// Rate of the item timebase, and the rate and fade the mixer set on the deck.
        var rate: Double
        var playerRate: Float
        var fade: Float
    }

    struct Poll {
        var host: Double
        var decks: [DeckState]
    }

    /// The last unbroken run of one item's recorded output.
    struct Track {
        /// Item time the tap reports for each buffer, and the buffer's first frame. Only roughly right off rate 1.
        var stamps: [(time: Double, frame: Int)]
        var sampleRate: Double
        var channels: Int
        var samples: [Float]
        /// Host time at which frame 0 is heard, once known.
        var anchor: Double?
        var frames: Int { samples.count / channels }

        /// Frame value at host time `h`, linearly between frames; nil outside the recording.
        func value(atHost h: Double, channel: Int) -> Float? {
            guard let anchor else { return nil }
            let x = (h - anchor) * sampleRate, i = Int(x.rounded(.down))
            guard i >= 0, i + 1 < frames else { return nil }
            let c = min(channel, channels - 1), f = Float(x - Double(i))
            return samples[i * channels + c] * (1 - f) + samples[(i + 1) * channels + c] * f
        }

        /// Mono (the channel mean) of frames `range`; 0 outside the recording.
        func mono(_ range: Range<Int>) -> [Float] {
            range.map { f in f >= 0 && f < frames ? (0..<channels).reduce(0) { $0 + samples[f * channels + $1] } / Float(channels) : 0 }
        }
    }

    /// Stereo output on the host clock from `start`: each deck as heard, and their sum.
    struct Render {
        var sampleRate: Double
        var start: Double
        var decks: [[Float]]
        var mix: [Float]
        var frames: Int { mix.count / 2 }
        func host(_ frame: Int) -> Double { start + Double(frame) / sampleRate }
        func frame(_ host: Double) -> Int { min(max(Int(((host - start) * sampleRate).rounded()), 0), frames) }
    }

    let mixer: Mixer
    let recorder: TapRecorder
    private(set) var polls: [Poll] = []
    private var timer: Timer?

    init(mixer: Mixer, recorder: TapRecorder) {
        self.mixer = mixer
        self.recorder = recorder
    }

    func start() {
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 0.005, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let clock = CMClockGetHostTimeClock(), now = CMClockGetTime(clock)
        polls.append(Poll(host: now.seconds, decks: mixer.decks.map { deck in
            let item = deck.player.currentItem
            guard let item, let timebase = item.timebase else {
                return DeckState(item: item.map(ObjectIdentifier.init), time: 0, rate: 0, playerRate: deck.player.rate, fade: deck.fade)
            }
            let time = CMSyncConvertTime(now, from: clock, to: timebase).seconds
            return DeckState(item: ObjectIdentifier(item), time: time.isFinite ? time : 0, rate: CMTimebaseGetRate(timebase),
                             playerRate: deck.player.rate, fade: deck.fade)
        }))
    }

    /// Host time at which `item` is at item time `t`, from the nearest poll where it plays.
    func host(of item: ObjectIdentifier, at t: Double) -> Double? {
        let states = polls.flatMap { p in p.decks.filter { $0.item == item && $0.rate > 0 }.map { (p.host, $0) } }
        guard let near = states.min(by: { abs($0.1.time - t) < abs($1.1.time - t) }) else { return nil }
        return near.0 + (t - near.1.time) / near.1.rate
    }

    func host(of item: AVPlayerItem, at t: Double) -> Double? { host(of: ObjectIdentifier(item), at: t) }

    /// Item time of `item` at host time `h`, from the last poll before it where the item plays.
    func itemTime(_ item: ObjectIdentifier, atHost h: Double) -> Double? {
        var lo = 0, hi = polls.count - 1
        while lo < hi { let mid = (lo + hi + 1) / 2; if polls[mid].host <= h { lo = mid } else { hi = mid - 1 } }
        for p in polls[max(lo - 2, 0)...min(lo + 1, polls.count - 1)].reversed() where p.host <= h || p.host == polls[0].host {
            if let s = p.decks.first(where: { $0.item == item && $0.rate > 0 }) { return s.time + (h - p.host) * s.rate }
        }
        return nil
    }

    /// The recordings by item; a jump of the stamps by half a second or more (a seek) starts the run again.
    func tracks() -> [ObjectIdentifier: Track] {
        var tracks: [ObjectIdentifier: Track] = [:]
        for b in recorder.recorded {
            if var t = tracks[b.item], t.channels == b.channels, t.sampleRate == b.sampleRate, let last = t.stamps.last,
               abs(b.time - last.time) < 0.5 {
                t.stamps.append((b.time, t.frames))
                t.samples += b.samples
                tracks[b.item] = t
            } else {
                tracks[b.item] = Track(stamps: [(b.time, 0)], sampleRate: b.sampleRate, channels: b.channels, samples: b.samples)
            }
        }
        return tracks
    }

    /// Finds the host time of frame 0 of `track` (of `item`): its output against the item's `source` (mono from item
    /// time `sourceStart`) played at the times the timebase gives, over `length` seconds from host time `from`. Also
    /// returns how far the item time of the heard sound is ahead of the tap's stamp, in seconds.
    func anchor(_ track: Track, of item: ObjectIdentifier, source: [Float], sourceRate: Double, sourceStart: Double = 0, from: Double,
                length: Double = 3) -> (anchor: Double, latency: Double)? {
        let sr = track.sampleRate, n = max(Int(sr / 1000), 1), bin = Double(n) / sr
        guard let t0 = itemTime(item, atHost: from),
              let stamp = track.stamps.min(by: { abs($0.time - t0) < abs($1.time - t0) }) else { return nil }
        // Rough guess from the stamp; the tap reports items about 93 ms early at rate 1.
        guard let guessHost = host(of: item, at: stamp.time + 0.093) else { return nil }
        let guess = guessHost - Double(stamp.frame) / sr
        let count = Int(length * sr)
        let expected: [Float] = (0..<count).map { k in
            guard let t = itemTime(item, atHost: from + Double(k) / sr) else { return 0 }
            let i = Int(((t - sourceStart) * sourceRate).rounded())
            return source.indices.contains(i) ? source[i] : 0
        }
        // Within 60 ms of the guess: further away, the next beat of a song may fit as well.
        let first = Int(((from - guess) * sr).rounded()) - 60 * n
        let heard = track.mono(first..<first + count + 120 * n)
        // Heard bin k + l matches expected bin k when frame first + (k + l) n is heard at from + k bins.
        let l = Measure.lag(Measure.envelope(expected, sampleRate: sr), Measure.envelope(heard, sampleRate: sr), lags: 0...120)
        guard l > 1, l < 119 else { return nil }
        let anchor = from - Double(first) / sr - l * bin
        let heardTime = itemTime(item, atHost: anchor + Double(stamp.frame) / sr) ?? stamp.time
        return (anchor, heardTime - stamp.time)
    }

    /// The output from host time `from` to `to`. `tracks` come from `tracks()`, with their `anchor` set.
    func render(_ tracks: [ObjectIdentifier: Track], from: Double, to: Double) -> Render {
        let sampleRate = tracks.values.first?.sampleRate ?? 44100
        let frames = polls.isEmpty ? 0 : max(Int((to - from) * sampleRate), 0), deckCount = mixer.decks.count
        var decks = Array(repeating: [Float](repeating: 0, count: frames * 2), count: deckCount)
        var k = 0
        for i in 0..<frames {
            let h = from + Double(i) / sampleRate
            while k + 1 < polls.count, polls[k + 1].host <= h { k += 1 }
            for d in 0..<deckCount {
                // The earlier poll, else the later one: the first frames of an item that came between the two.
                for j in k...min(k + 1, polls.count - 1) {
                    let s = polls[j].decks[d]
                    guard let id = s.item, s.rate > 0, let track = tracks[id],
                          let left = track.value(atHost: h, channel: 0), let right = track.value(atHost: h, channel: 1) else { continue }
                    decks[d][2 * i] = left * s.fade
                    decks[d][2 * i + 1] = right * s.fade
                    break
                }
            }
        }
        var mix = [Float](repeating: 0, count: frames * 2)
        for deck in decks { for j in mix.indices { mix[j] += deck[j] } }
        return Render(sampleRate: sampleRate, start: from, decks: decks, mix: mix)
    }

    /// Writes 32-bit float stereo samples as a WAV file.
    nonisolated static func write(_ samples: [Float], sampleRate: Double, to url: URL) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count / 2)),
              let data = buffer.floatChannelData else { throw CocoaError(.fileWriteUnknown) }
        buffer.frameLength = AVAudioFrameCount(samples.count / 2)
        for i in 0..<samples.count / 2 {
            data[0][i] = samples[2 * i]
            data[1][i] = samples[2 * i + 1]
        }
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
    }

    /// Folder for WAV files of the measurements, from `MUSICSYNC_CAPTURE_DIR`; nil writes none.
    nonisolated static var wavFolder: URL? {
        ProcessInfo.processInfo.environment["MUSICSYNC_CAPTURE_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }
}
