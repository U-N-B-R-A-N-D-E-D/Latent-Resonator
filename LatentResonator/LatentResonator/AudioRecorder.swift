import Foundation
import AVFoundation

// MARK: - Audio Recorder
//
// Writes AVAudioPCMBuffer data to a WAV file on disk.
// Used at two levels:
//   1. Per-lane: captures the isolated output of a single ResonatorLane
//      (for studying one latent trajectory in isolation -- §5.1-5.4).
//   2. Master bus: captures the mixed output (final performance artifact).
//
// Thread safety: writeBuffer() dispatches writes to a serial queue
// so it can be called from audio tap callbacks or inference threads.
// @unchecked Sendable: all mutable state is synchronized via recordingQueue.

final class AudioRecorder: @unchecked Sendable {

    private var audioFile: AVAudioFile?
    private(set) var isRecording: Bool = false
    private(set) var recordingURL: URL?
    private let recordingQueue = DispatchQueue(
        label: "com.latentresonator.recorder",
        qos: .utility
    )

    /// Output directory for all Latent Resonator recordings.
    /// Uses custom path from Settings when set; else ~/Documents/LatentResonator.
    static var outputDirectory: URL {
        if let custom = UserDefaults.standard.string(forKey: LRConstants.RecordingConfig.userDefaultsKey),
           !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return LRConstants.RecordingConfig.defaultDirectory
    }

    /// Start recording to a WAV file.
    ///
    /// - Parameters:
    ///   - name: Identifier for the recording (e.g. lane name or "MASTER")
    ///   - format: Audio format matching the tap output
    /// - Returns: File URL of the new recording
    func startRecording(name: String, format: AVAudioFormat) throws -> URL {
        let dir = Self.outputDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let filename = "\(LRConstants.recordingFilePrefix)\(name)_\(timestamp).wav"
        let url = dir.appendingPathComponent(filename)

        audioFile = try AVAudioFile(forWriting: url, settings: format.settings)
        recordingURL = url
        isRecording = true
        print(">> AudioRecorder: Recording started -> \(filename)")
        return url
    }

    /// Append a buffer to the active recording. Thread-safe.
    func writeBuffer(_ buffer: AVAudioPCMBuffer) {
        guard isRecording, let file = audioFile else { return }
        recordingQueue.async {
            do {
                try file.write(from: buffer)
            } catch {
                print(">> AudioRecorder: write error -- \(error.localizedDescription)")
            }
        }
    }

    /// Stop recording and return the file URL immediately.
    /// Note: Pending buffers in the write queue may not be flushed; last buffers can be lost.
    /// Use stopRecording() async when you need all buffered data written before returning.
    @discardableResult
    func stopRecording() -> URL? {
        guard isRecording else { return nil }
        isRecording = false
        let url = recordingURL
        audioFile = nil
        recordingURL = nil
        if let url = url {
            print(">> AudioRecorder: Recording stopped -> \(url.lastPathComponent)")
        }
        return url
    }

    /// Stop recording and return the file URL after all pending writes have completed.
    /// Use this when you need a complete recording (e.g. before app quit or export).
    func stopRecording() async -> URL? {
        guard isRecording else { return nil }
        isRecording = false
        let url = recordingURL

        return await withCheckedContinuation { cont in
            recordingQueue.async {
                self.audioFile = nil
                self.recordingURL = nil
                if let url = url {
                    print(">> AudioRecorder: Recording stopped (flush complete) -> \(url.lastPathComponent)")
                }
                cont.resume(returning: url)
            }
        }
    }

    /// Export a metadata sidecar JSON alongside a recording file.
    ///
    /// Enables Section 5 analysis: maps iteration N to sonic characteristics.
    static func exportMetadata(
        recordingURL: URL,
        iterationCount: Int,
        laneName: String,
        parameters: [String: Any],
        featureLog: [SpectralFeatureSnapshot] = []
    ) {
        let meta: [String: Any] = [
            "lane": laneName,
            "iterationCount": iterationCount,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "sampleRate": LRConstants.sampleRate,
            "parameters": parameters
        ]

        let sidecarURL = recordingURL
            .deletingPathExtension()
            .appendingPathExtension("json")

        if let data = try? JSONSerialization.data(withJSONObject: meta, options: .prettyPrinted) {
            try? data.write(to: sidecarURL)
            print(">> AudioRecorder: Metadata exported -> \(sidecarURL.lastPathComponent)")
        }

        // Export spectral feature telemetry as a separate CSV for analysis tools
        if !featureLog.isEmpty {
            let csvURL = recordingURL
                .deletingPathExtension()
                .appendingPathExtension("features.csv")
            var csv = "iteration,centroid,flatness,flux,promptPhase,inputStrength,timestamp\n"
            for s in featureLog {
                csv += "\(s.iteration),\(s.centroid),\(s.flatness),\(s.flux),\(s.promptPhase),\(s.inputStrength),\(s.timestamp)\n"
            }
            try? csv.write(to: csvURL, atomically: true, encoding: .utf8)
            print(">> AudioRecorder: Feature log exported -> \(csvURL.lastPathComponent)")
        }
    }
}
