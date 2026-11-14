import Foundation

public enum SoundCheck {
    /// iTunesDB Sound Check value for a ReplayGain adjustment in dB (as in gtkpod).
    public static func value(replayGainDB gain: Double) -> UInt32 {
        let v = (1000 * pow(10, -gain / 10)).rounded()
        return v.isFinite ? UInt32(min(max(v, 0), Double(UInt32.max))) : 0
    }
}
