import AVFoundation
import Playback
import Testing

@MainActor @Suite struct ItemGainTests {
    private func volume(_ item: AVPlayerItem) -> Float? {
        var start: Float = 0, end: Float = 0, range = CMTimeRange()
        guard item.audioMix?.inputParameters.first?.getVolumeRamp(for: .zero, startVolume: &start, endVolume: &end, timeRange: &range) == true
        else { return nil }
        return start
    }

    @Test func setsAndClearsTheMix() async throws {
        let url = try silentFile(seconds: 1)
        defer { try? FileManager.default.removeItem(at: url) }
        let item = AVPlayerItem(url: url)
        await item.setGain(0.5)
        #expect(item.audioMix?.inputParameters.count == 1)
        #expect(volume(item) == 0.5)
        await item.setGain(1)
        #expect(item.audioMix == nil)
    }
}
