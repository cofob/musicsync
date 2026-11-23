import AVFoundation

/// Background playback: the playback category, active once something plays.
/// Calls and other apps pause the player; unplugged headphones too, as in other music apps.
@MainActor enum AudioSession {
    private static var watcher: Watcher<Bool>?
    private static var observers: [Any] = []
    /// Playing when an interruption began: it plays on when the interruption ends.
    private static var resumes = false

    static func start(_ player: Player) {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, policy: .longFormAudio)
        // Not at launch: activating the session stops the audio of other apps.
        watcher = Watcher({ player.isPlaying }) { if $0 { try? session.setActive(true) } }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { note in
                let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
                let options = AVAudioSession.InterruptionOptions(rawValue: note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
                MainActor.assumeIsolated {
                    switch type {
                    case .began?:
                        resumes = player.isPlaying
                        player.pause()
                    case .ended? where options.contains(.shouldResume) && resumes:
                        resumes = false
                        if !player.isPlaying { player.toggle() }
                    default: break
                    }
                }
            },
            center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: .main) { note in
                let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init)
                guard reason == .oldDeviceUnavailable else { return }
                MainActor.assumeIsolated { player.pause() }
            },
        ]
    }
}
