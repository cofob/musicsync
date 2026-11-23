import Foundation

/// What AutoMix knows about a song from its audio. Times are seconds in the song.
public struct SongAnalysis: Codable, Equatable, Sendable {
    /// Raised when the analysis changes, so that older cached results are made again.
    public static let version = 2
    /// Mono sample rate the analysis works at: enough for beats and loudness, and fast.
    public static let sampleRate = 11025.0

    public var duration: TimeInterval
    /// First and last time with sound; before and after is silence.
    public var soundStart: TimeInterval
    public var soundEnd: TimeInterval
    /// The energy reaches its stable level here.
    public var introEnd: TimeInterval
    /// The energy falls off after here.
    public var outroStart: TimeInterval
    /// Tempo, 70–180.
    public var bpm: Double
    /// First beat one of a bar; the beats follow every 60 / `bpm` seconds.
    public var downbeat: TimeInterval
    /// 0…1: how clearly the beat stands out. Songs without a steady beat are low.
    public var beatStrength: Double
    /// Where a new part of the song starts (verse, chorus…), sorted; the visualizer changes there.
    public var sections: [TimeInterval]

    public init(duration: TimeInterval, soundStart: TimeInterval, soundEnd: TimeInterval, introEnd: TimeInterval,
                outroStart: TimeInterval, bpm: Double, downbeat: TimeInterval, beatStrength: Double, sections: [TimeInterval] = []) {
        self.duration = duration
        self.soundStart = soundStart
        self.soundEnd = soundEnd
        self.introEnd = introEnd
        self.outroStart = outroStart
        self.bpm = bpm
        self.downbeat = downbeat
        self.beatStrength = beatStrength
        self.sections = sections
    }

    /// Analyzes mono PCM. Pure and CPU-bound: call it off the main thread.
    public init(samples: [Float], sampleRate: Double = SongAnalysis.sampleRate) {
        let shape = Loudness(samples, sampleRate: sampleRate).shape()
        let beat = Beat(samples, sampleRate: sampleRate, soundStart: shape.soundStart)
        self.init(duration: Double(samples.count) / sampleRate, soundStart: shape.soundStart, soundEnd: shape.soundEnd,
                  introEnd: shape.introEnd, outroStart: shape.outroStart, bpm: beat.bpm, downbeat: beat.downbeat,
                  beatStrength: beat.strength,
                  sections: Sections.find(samples, sampleRate: sampleRate, bpm: beat.bpm, downbeat: beat.downbeat,
                                          beatStrength: beat.strength, soundStart: shape.soundStart, soundEnd: shape.soundEnd))
    }
}
