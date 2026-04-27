import Foundation
import AVFoundation
import Accelerate

// MARK: - Reverb Insert Position
/// Defines where the reverb is inserted in the signal chain relative to feedback.
enum ReverbInsertPosition: String, CaseIterable, Identifiable, Codable {
    case preFeedback = "pre"
    case postFeedback = "post"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .preFeedback: return "Pre-Feedback"
        case .postFeedback: return "Post-Feedback"
        }
    }
}

// MARK: - Reverb Node
/// Schroeder-Moorer style reverberator with per-lane pre/post feedback toggle.
/// Implements a classic digital reverb using a series of comb filters
/// followed by all-pass filters.
///
/// v2.0: Stub implementation - core DSP logic preserved but exposedControls
/// API needs updating to match current NodeGraph architecture.
final class ReverbNode: BaseGraphNode {

    // MARK: - Parameters

    /// Room size (0-1), affects comb filter delay lengths.
    var roomSize: Float {
        get { getParam("roomSize", default: 0.5) }
        set { setParam("roomSize", value: newValue) }
    }

    /// Decay time in seconds (0.1-10.0).
    var decay: Float {
        get { getParam("decay", default: 2.0) }
        set { setParam("decay", value: newValue) }
    }

    /// High-frequency damping (0-1), higher = darker reverb.
    var damping: Float {
        get { getParam("damping", default: 0.5) }
        set { setParam("damping", value: newValue) }
    }

    /// Wet/dry mix (0-1), balance between dry and reverb signal.
    var wetDryMix: Float {
        get { getParam("wetDryMix", default: 0.3) }
        set { setParam("wetDryMix", value: newValue) }
    }

    /// Insert position: pre or post feedback loop.
    var insertPosition: ReverbInsertPosition {
        get {
            let raw = getParam("insertPosition", default: ReverbInsertPosition.postFeedback.rawValue)
            if let pos = ReverbInsertPosition(rawValue: raw) {
                return pos
            }
            return .postFeedback
        }
        set { setParam("insertPosition", value: newValue.rawValue) }
    }

    // MARK: - State

    private var sourceNode: AVAudioSourceNode?
    private let sampleRate: Double

    // Schroeder reverb: 6 parallel comb filters + 3 series all-pass
    private var combDelays: [[Float]] = []
    private var combWritePos: [Int] = []
    private var combFeedback: [Float] = [0.805, 0.827, 0.783, 0.807, 0.795, 0.789]
    private let combDelayLengths: [Int] = [1557, 1617, 1491, 1422, 1277, 1116]

    private var allpassDelays: [[Float]] = []
    private var allpassWritePos: [Int] = []
    private let allpassDelayLengths: [Int] = [225, 556, 441]
    private let allpassFeedback: Float = 0.7

    // Low-pass filter state for damping
    private var filterState: Float = 0.0

    // Parameter smoothing
    private var smoothedWetDryMix: Float = 0.3
    private var smoothedDamping: Float = 0.5

    // MARK: - Init

    init(id: UUID = UUID(), params: [String: Any] = [:], sampleRate: Double = LRConstants.sampleRate) {
        self.sampleRate = sampleRate

        // Initialize comb filter delay lines
        for length in combDelayLengths {
            combDelays.append([Float](repeating: 0, count: length))
            combWritePos.append(0)
        }

        // Initialize all-pass filter delay lines
        for length in allpassDelayLengths {
            allpassDelays.append([Float](repeating: 0, count: length))
            allpassWritePos.append(0)
        }

        super.init(
            id: id,
            nodeType: "reverb",
            category: .effect,
            displayName: "REVERB"
        )

        for (key, value) in params {
            self.parameters[key] = value
        }

        createSourceNode()
    }

    // MARK: - Codable

    required init(from decoder: Decoder) throws {
        self.sampleRate = LRConstants.sampleRate

        // Initialize comb filter delay lines
        for length in combDelayLengths {
            combDelays.append([Float](repeating: 0, count: length))
            combWritePos.append(0)
        }

        // Initialize all-pass filter delay lines
        for length in allpassDelayLengths {
            allpassDelays.append([Float](repeating: 0, count: length))
            allpassWritePos.append(0)
        }

        try super.init(from: decoder)
        createSourceNode()
    }

    // MARK: - Ports

    override var ports: [NodePort] {
        [
            NodePort(id: "in", label: "IN", signalType: .audio, direction: .input),
            NodePort(id: "room_cv", label: "ROOM CV", signalType: .control, direction: .input),
            NodePort(id: "decay_cv", label: "DECAY CV", signalType: .control, direction: .input),
            NodePort(id: "damp_cv", label: "DAMP CV", signalType: .control, direction: .input),
            NodePort(id: "mix_cv", label: "MIX CV", signalType: .control, direction: .input),
            NodePort(id: "out", label: "OUT", signalType: .audio, direction: .output)
        ]
    }

    // MARK: - Audio Unit

    override func audioUnit() -> AVAudioNode? {
        return sourceNode
    }

    private func createSourceNode() {
        let format = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: AVAudioChannelCount(LRConstants.channelCount)
        )!

        sourceNode = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            guard self != nil else { return noErr }

            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard let buffer = ablPointer.first else { return noErr }

            let data = UnsafeMutableBufferPointer<Float>(
                start: buffer.mData?.assumingMemoryBound(to: Float.self),
                count: Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            )

            // For now, output silence - tap implementation needed for actual reverb
            for i in 0..<Int(frameCount) {
                data[i] = 0.0
            }

            return noErr
        }
    }

    // MARK: - Reset

    func reset() {
        // Clear all delay lines
        for i in 0..<combDelays.count {
            combDelays[i] = [Float](repeating: 0, count: combDelayLengths[i])
            combWritePos[i] = 0
        }
        for i in 0..<allpassDelays.count {
            allpassDelays[i] = [Float](repeating: 0, count: allpassDelayLengths[i])
            allpassWritePos[i] = 0
        }
        filterState = 0.0
    }
}
