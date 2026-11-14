import Playback
import SwiftUI

/// Settings > Playback: the streaming quality on metered networks (Low Data Mode, a phone hotspot).
struct MeteredQualityRows: View {
    @Binding var settings: PlaybackSettings
    let isMetered: Bool

    var body: some View {
        Picker(selection: $settings.meteredQuality) {
            Text("Same as Other Networks").tag(StreamQuality?.none)
            Divider()
            Text("Original").tag(StreamQuality?.some(.original))
            Text("AAC").tag(StreamQuality?.some(.aac))
            Text("MP3").tag(StreamQuality?.some(.mp3))
        } label: {
            Text("On metered networks")
            Text(isMetered ? "This Mac is on a metered network now." : "Low Data Mode or a phone hotspot.")
        }
        if let quality = settings.meteredQuality, quality != .original {
            Picker("Metered bit rate", selection: $settings.meteredMaxBitRate) {
                ForEach([64, 96, 128, 192, 256, 320], id: \.self) { Text("\($0) kbps").tag($0) }
            }
        }
    }
}
