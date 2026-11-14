import AVFoundation
import Foundation
import Testing

/// A silent stereo WAV of `seconds` in a temp folder: real audio for AVPlayer tests that makes no sound.
func silentFile(seconds: Double) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("playback-test-\(UUID().uuidString).wav")
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2))
    let frames = AVAudioFrameCount(seconds * 44100)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
    buffer.frameLength = frames  // zero-filled
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    try file.write(from: buffer)
    return url
}
