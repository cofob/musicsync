import Playback
import SwiftUI

/// Settings > Playback.
struct PlaybackSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var player = model.player
        Form {
            Section {
                Toggle("Crossfade songs", isOn: $player.settings.crossfade)
                Slider(value: $player.settings.crossfadeSeconds, in: 1...12, step: 1) {
                    Text("\(Int(player.settings.crossfadeSeconds)) seconds").monospacedDigit()
                } minimumValueLabel: { Text("1 s") } maximumValueLabel: { Text("12 s") }
                    .disabled(!player.settings.crossfade)
            } footer: {
                footer("Songs of the same album that play in order are not crossfaded.")
            }
            Section {
                Picker("Sound Check", selection: $player.settings.soundCheck) {
                    Text("Off").tag(PlaybackSettings.SoundCheck.off)
                    Text("Track").tag(PlaybackSettings.SoundCheck.track)
                    Text("Album").tag(PlaybackSettings.SoundCheck.album)
                }
                if player.settings.soundCheck != .off {
                    Slider(value: $player.settings.preAmp, in: -12...12, step: 1) {
                        Text("Pre-amp \(player.settings.preAmp > 0 ? "+" : "")\(Int(player.settings.preAmp)) dB").monospacedDigit()
                    }
                    Toggle("Prevent clipping", isOn: $player.settings.preventClipping)
                }
            } footer: {
                footer("Plays songs at the same volume, from their ReplayGain tags. Album keeps the volume steps of an album that plays in order.")
            }
            Section {
                Picker("Streaming quality", selection: $player.settings.quality) {
                    Text("Original").tag(StreamQuality.original)
                    Text("AAC").tag(StreamQuality.aac)
                    Text("MP3").tag(StreamQuality.mp3)
                }
                if player.settings.quality != .original {
                    Picker("Bit rate", selection: $player.settings.maxBitRate) {
                        ForEach([128, 192, 256, 320], id: \.self) { Text("\($0) kbps").tag($0) }
                    }
                }
                if player.supportsTranscodeOffset {
                    Toggle("Seek in converted streams on the server", isOn: $player.settings.transcodeOffset)
                }
            } footer: {
                footer("Original plays the files as they are on the server. AAC and MP3 are converted by the server and use less data. Downloaded songs play from their files.")
            }
            Section {
                Picker("Speed", selection: $player.settings.speed) {
                    ForEach([0.5, 0.75, 1, 1.25, 1.5, 1.75, 2], id: \.self) { Text(speedTitle($0)).tag($0) }
                }
                SleepTimerPicker(selection: $player.sleepTimer)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func footer(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }
}

/// "1.25×".
func speedTitle(_ speed: Double) -> String { speed.formatted(.number.precision(.fractionLength(0...2))) + "×" }

/// Off, 15–60 minutes, end of the current song. Used in Settings and in the Playback menu.
struct SleepTimerPicker: View {
    @Binding var selection: SleepTimer?

    var body: some View {
        Picker("Sleep Timer", selection: $selection) {
            Text("Off").tag(SleepTimer?.none)
            ForEach(SleepTimer.choices, id: \.self) { Text($0.title).tag(Optional($0)) }
        }
    }
}
