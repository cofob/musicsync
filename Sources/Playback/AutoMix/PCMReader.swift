import AVFoundation

enum AnalysisError: Error {
    case noAudio, tooLong, tooLarge, status(Int)
}

/// Decodes audio files to mono Float samples at the analysis sample rate.
enum PCMReader {
    /// Longer songs (long DJ mixes) are not analyzed: they cost too much memory.
    static let maxDuration: TimeInterval = 20 * 60

    /// `contentType` tells AVFoundation the type of a file without an extension (a saved stream).
    static func samples(of url: URL, contentType: String? = nil, sampleRate: Double = SongAnalysis.sampleRate) async throws -> [Float] {
        let asset = AVURLAsset(url: url, options: contentType.map { [AVURLAssetOverrideMIMETypeKey: $0] })
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw AnalysisError.noAudio }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
        ])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? AnalysisError.noAudio }
        let limit = Int(maxDuration * sampleRate)
        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            if Task.isCancelled { reader.cancelReading(); throw CancellationError() }
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let count = CMBlockBufferGetDataLength(block) / 4, old = samples.count
            samples.append(contentsOf: repeatElement(0, count: count))
            _ = samples.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * 4, destination: $0.baseAddress! + old * 4) }
            if samples.count > limit { reader.cancelReading(); throw AnalysisError.tooLong }
        }
        guard reader.status == .completed else { throw reader.error ?? AnalysisError.noAudio }
        return samples
    }
}
