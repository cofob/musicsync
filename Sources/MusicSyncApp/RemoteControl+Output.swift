#if os(macOS)
import CoreAudio
#else
import AVFoundation
#endif
import Remote

extension RemoteControl {
    /// What the remote shows as the output: the server while the jukebox plays, else the Mac's output device,
    /// which is also the AirPlay speaker picked in the player.
    func output(_ state: inout RemoteState) {
        let jukebox = app.jukebox
        state.jukebox = jukebox.isAvailable ? jukebox.isActive : nil
        state.output = jukebox.isActive ? jukebox.serverName : Self.outputDeviceName() ?? "This Mac"
    }

    /// Name of the default output device; a quick read of the audio system's own state.
    static func outputDeviceName() -> String? {
        #if os(iOS)
        return AVAudioSession.sharedInstance().currentRoute.outputs.first?.portName
        #else
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }
        var name: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        address.mSelector = kAudioObjectPropertyName
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr, let name else { return nil }
        return name.takeRetainedValue() as String
        #endif
    }
}
