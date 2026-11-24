import AVFoundation
#if os(macOS)
import CoreAudio
#endif

/// Sound from outside the player for the standalone visualizer: what other apps play (Mac) or the microphone.
/// `samples` has the newest frames; read them at time `.infinity`.
@MainActor @Observable public final class AudioCapture {
    public enum Source: String, CaseIterable, Identifiable, Sendable {
        #if os(macOS)
        case system
        #endif
        case microphone
        public var id: Self { self }
        public static var `default`: Source { allCases[0] }
        public var title: String {
            switch self {
            #if os(macOS)
            case .system: "System Audio"
            #endif
            case .microphone: "Microphone"
            }
        }
    }

    @ObservationIgnored public let samples = SampleTap()
    /// Why the capture does not run; nil while it runs or is stopped.
    public private(set) var error: String?
    @ObservationIgnored private var engine: AVAudioEngine?
    #if os(macOS)
    @ObservationIgnored private var tap: SystemTap?
    #endif

    public init() {}

    /// `microphone`: UID of the input device (`microphones`); empty for the system's default input.
    public func start(_ source: Source, microphone: String = "") async {
        stop()
        do {
            switch source {
            #if os(macOS)
            case .system: tap = try SystemTap(samples)
            #endif
            case .microphone: try await startMicrophone(microphone)
            }
            samples.isOn = true
        } catch {
            stop()
            self.error = "Cannot record \(source.title.lowercased()). Allow MusicSync to record audio in System Settings > Privacy & Security."
        }
    }

    public func stop() {
        samples.isOn = false
        error = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            self.engine = nil
            #if os(iOS)
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, policy: .longFormAudio)
            #endif
        }
        #if os(macOS)
        tap = nil
        #endif
    }

    private func startMicrophone(_ uid: String) async throws {
        guard await AVAudioApplication.requestRecordPermission() else { throw CaptureError() }
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, options: [.mixWithOthers, .defaultToSpeaker])
        try session.setActive(true)
        #endif
        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode
        #if os(macOS)
        if var device = Self.device(uid), let unit = input.audioUnit {
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                              &device, UInt32(MemoryLayout<AudioDeviceID>.size))
            if status != noErr { throw CaptureError() }
        }
        #endif
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { throw CaptureError() }
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.tapBlock(samples))
        try engine.start()
    }

    /// Made outside the main actor: the tap calls it on an audio queue, and a main-actor closure traps there.
    private nonisolated static func tapBlock(_ samples: SampleTap) -> AVAudioNodeTapBlock {
        { buffer, _ in
            samples.write(UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList), frames: Int(buffer.frameLength),
                          time: 0, sampleRate: buffer.format.sampleRate)
        }
    }
}

struct CaptureError: Error {}

#if os(macOS)
/// An input device for `AudioCapture.start(_:microphone:)`.
public struct Microphone: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
}

extension AudioCapture {
    /// The input devices, in the system's order.
    public nonisolated static func microphones() -> [Microphone] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = Self.address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard inputChannels(id) > 0, let uid = string(id, kAudioDevicePropertyDeviceUID),
                  let name = string(id, kAudioObjectPropertyName) else { return nil }
            return Microphone(id: uid, name: name)
        }
    }

    /// The device with this UID; nil for an empty or unknown one.
    nonisolated static func device(_ uid: String) -> AudioDeviceID? {
        guard !uid.isEmpty else { return nil }
        var address = Self.address(kAudioHardwarePropertyTranslateUIDToDevice)
        var cfUID = uid as CFString, id = AudioDeviceID(kAudioObjectUnknown), size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                                UInt32(MemoryLayout<CFString>.size), &cfUID, &size, &id)
        return status == noErr && id != kAudioObjectUnknown ? id : nil
    }

    private nonisolated static func inputChannels(_ id: AudioDeviceID) -> Int {
        var address = Self.address(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        return UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self)).reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private nonisolated static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = Self.address(selector)
        var value: Unmanaged<CFString>?, size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    nonisolated static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
}
#endif

#if os(macOS)
/// A Core Audio tap on all processes but this one, read through a private aggregate device. Stops when released.
private final class SystemTap {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?

    init(_ samples: SampleTap) throws {
        func check(_ status: OSStatus) throws { if status != noErr { throw CaptureError() } }
        // This process, so that the player's own sound is left out.
        var pid = getpid(), own = AudioObjectID(kAudioObjectUnknown), size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioCapture.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &own))
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: own == kAudioObjectUnknown ? [] : [own])
        description.isPrivate = true
        description.muteBehavior = .unmuted
        try check(AudioHardwareCreateProcessTap(description, &tapID))

        var format = AudioStreamBasicDescription()
        size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        address = AudioCapture.address(kAudioTapPropertyFormat)
        try check(AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format))
        let rate = format.mSampleRate

        let device: [String: Any] = [
            kAudioAggregateDeviceNameKey: "MusicSync Visualizer",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        try check(AudioHardwareCreateAggregateDevice(device as CFDictionary, &deviceID))
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, nil) { _, input, _, _, _ in
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard let first = list.first, first.mNumberChannels > 0 else { return }
            samples.write(list, frames: Int(first.mDataByteSize) / (4 * Int(first.mNumberChannels)), time: 0, sampleRate: rate)
        })
        try check(AudioDeviceStart(deviceID, procID))
    }

    deinit {
        if let procID {
            AudioDeviceStop(deviceID, procID)
            AudioDeviceDestroyIOProcID(deviceID, procID)
        }
        if deviceID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(deviceID) }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
    }
}
#endif
