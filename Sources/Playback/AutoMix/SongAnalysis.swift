import Foundation
import Support

/// What AutoMix knows about a song from its audio. Times are seconds in the song.
public struct SongAnalysis: Codable, Equatable, Sendable {
    /// Raised when the analysis changes, so that older cached results are made again.
    public static let version = 3
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
    /// The mood of the whole song (`MoodMeter`); nil when the song has no sound.
    public var mood: Mood?
    /// The mood of each part: `sections.count + 1` moods, or none when `mood` is nil.
    public var partMoods: [Mood]

    public init(duration: TimeInterval, soundStart: TimeInterval, soundEnd: TimeInterval, introEnd: TimeInterval,
                outroStart: TimeInterval, bpm: Double, downbeat: TimeInterval, beatStrength: Double, sections: [TimeInterval] = [],
                mood: Mood? = nil, partMoods: [Mood] = []) {
        self.duration = duration
        self.soundStart = soundStart
        self.soundEnd = soundEnd
        self.introEnd = introEnd
        self.outroStart = outroStart
        self.bpm = bpm
        self.downbeat = downbeat
        self.beatStrength = beatStrength
        self.sections = sections
        self.mood = mood
        self.partMoods = partMoods
    }

    /// Analyzes mono PCM. Pure and CPU-bound: call it off the main thread.
    public init(samples: [Float], sampleRate: Double = SongAnalysis.sampleRate) {
        let shape = Loudness(samples, sampleRate: sampleRate).shape()
        let beat = Beat(samples, sampleRate: sampleRate, soundStart: shape.soundStart)
        let sections = Sections.find(samples, sampleRate: sampleRate, bpm: beat.bpm, downbeat: beat.downbeat,
                                     beatStrength: beat.strength, soundStart: shape.soundStart, soundEnd: shape.soundEnd)
        let meter = MoodMeter(frames: MoodFrames(samples, sampleRate: sampleRate), onsets: beat.onsets,
                              onsetStep: Double(Beat.hop) / sampleRate, bpm: beat.bpm, beatStrength: beat.strength)
        let mood = meter.mood(from: shape.soundStart, to: shape.soundEnd)
        let bounds = [shape.soundStart] + sections + [shape.soundEnd]
        self.init(duration: Double(samples.count) / sampleRate, soundStart: shape.soundStart, soundEnd: shape.soundEnd,
                  introEnd: shape.introEnd, outroStart: shape.outroStart, bpm: beat.bpm, downbeat: beat.downbeat,
                  beatStrength: beat.strength, sections: sections, mood: mood,
                  partMoods: mood.map { whole in zip(bounds, bounds.dropFirst()).map { meter.mood(from: $0, to: $1) ?? whole } } ?? [])
    }

    /// The moods of the part playing at `time` and of the whole song; nil when the song has no mood.
    public func moods(at time: TimeInterval) -> (part: Mood, song: Mood)? {
        guard let mood else { return nil }
        let part = sections.lastIndex { $0 <= time }.map { $0 + 1 } ?? 0
        return (partMoods.indices.contains(part) ? partMoods[part] : mood, mood)
    }
}
