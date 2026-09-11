import Foundation
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
/// Schroeder-style feedback-delay-network reverb (comb + all-pass).
/// Whitepaper §1.2 — Lucier-style spatial smear as an insert, not a generic preset.
final class ReverbNode: BaseGraphNode {

    var roomSize: Float {
        get { getParam("roomSize", default: 0.5) }
        set { setParam("roomSize", value: newValue) }
    }

    var decay: Float {
        get { getParam("decay", default: 2.0) }
        set { setParam("decay", value: newValue) }
    }

    var damping: Float {
        get { getParam("damping", default: 0.5) }
        set { setParam("damping", value: newValue) }
    }

    var wetDryMix: Float {
        get { getParam("wetDryMix", default: 0.3) }
        set { setParam("wetDryMix", value: newValue) }
    }

    var insertPosition: ReverbInsertPosition {
        get {
            let raw = getParam("insertPosition", default: ReverbInsertPosition.postFeedback.rawValue)
            return ReverbInsertPosition(rawValue: raw) ?? .postFeedback
        }
        set { setParam("insertPosition", value: newValue.rawValue) }
    }

    private let sampleRate: Double

    private var combDelaysL: [[Float]] = []
    private var combDelaysR: [[Float]] = []
    private var combWritePos: [Int] = []
    private var combFeedback: [Float] = [0.805, 0.827, 0.783, 0.807, 0.795, 0.789]
    private let combDelayLengths: [Int] = [1557, 1617, 1491, 1422, 1277, 1116]

    private var allpassDelaysL: [[Float]] = []
    private var allpassDelaysR: [[Float]] = []
    private var allpassWritePos: [Int] = []
    private let allpassDelayLengths: [Int] = [225, 556, 441]
    private let allpassFeedback: Float = 0.7

    private var dampStateL: Float = 0
    private var dampStateR: Float = 0

    private var smoothedWetDryMix: Float = 0.3
    private var smoothedDamping: Float = 0.5
    private var smoothedFeedback: Float = 0.75

    init(id: UUID = UUID(), params: [String: Any] = [:], sampleRate: Double = LRConstants.sampleRate) {
        self.sampleRate = sampleRate

        for length in combDelayLengths {
            combDelaysL.append([Float](repeating: 0, count: length))
            combDelaysR.append([Float](repeating: 0, count: length + 23))
            combWritePos.append(0)
        }
        for length in allpassDelayLengths {
            allpassDelaysL.append([Float](repeating: 0, count: length))
            allpassDelaysR.append([Float](repeating: 0, count: length + 11))
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
        smoothedWetDryMix = wetDryMix
        smoothedDamping = damping
    }

    required init(from decoder: Decoder) throws {
        self.sampleRate = LRConstants.sampleRate
        for length in combDelayLengths {
            combDelaysL.append([Float](repeating: 0, count: length))
            combDelaysR.append([Float](repeating: 0, count: length + 23))
            combWritePos.append(0)
        }
        for length in allpassDelayLengths {
            allpassDelaysL.append([Float](repeating: 0, count: length))
            allpassDelaysR.append([Float](repeating: 0, count: length + 11))
            allpassWritePos.append(0)
        }
        try super.init(from: decoder)
        smoothedWetDryMix = wetDryMix
        smoothedDamping = damping
    }

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

    @inline(__always)
    private func combSample(
        input: Float,
        index: Int,
        feedback: Float,
        bufferL: inout [Float],
        bufferR: inout [Float],
        writePos: inout Int
    ) -> (Float, Float) {
        let lenL = bufferL.count
        let lenR = bufferR.count
        let readL = (writePos - combDelayLengths[index] + lenL) % lenL
        let readR = (writePos - combDelayLengths[index] + lenR) % lenR
        let delayedL = bufferL[readL]
        let delayedR = bufferR[readR]
        let nextL = input + delayedL * feedback
        let nextR = input + delayedR * feedback
        bufferL[writePos] = nextL.isNaN || nextL.isInfinite ? 0 : nextL
        bufferR[writePos % lenR] = nextR.isNaN || nextR.isInfinite ? 0 : nextR
        writePos = (writePos + 1) % lenL
        return (delayedL, delayedR)
    }

    @inline(__always)
    private func allpassSample(
        inputL: Float,
        inputR: Float,
        index: Int,
        bufferL: inout [Float],
        bufferR: inout [Float],
        writePos: inout Int
    ) -> (Float, Float) {
        let lenL = bufferL.count
        let lenR = bufferR.count
        let readL = (writePos - allpassDelayLengths[index] + lenL) % lenL
        let readR = (writePos - allpassDelayLengths[index] + lenR) % lenR
        let delayedL = bufferL[readL]
        let delayedR = bufferR[readR]
        let outL = -inputL + delayedL
        let outR = -inputR + delayedR
        bufferL[writePos] = inputL + delayedL * allpassFeedback
        bufferR[writePos % lenR] = inputR + delayedR * allpassFeedback
        writePos = (writePos + 1) % lenL
        return (outL, outR)
    }

    func reset() {
        for i in 0..<combDelaysL.count {
            combDelaysL[i] = [Float](repeating: 0, count: combDelayLengths[i])
            combDelaysR[i] = [Float](repeating: 0, count: combDelayLengths[i] + 23)
            combWritePos[i] = 0
        }
        for i in 0..<allpassDelaysL.count {
            allpassDelaysL[i] = [Float](repeating: 0, count: allpassDelayLengths[i])
            allpassDelaysR[i] = [Float](repeating: 0, count: allpassDelayLengths[i] + 11)
            allpassWritePos[i] = 0
        }
        dampStateL = 0
        dampStateR = 0
    }
}

// MARK: - ReverbNode + DSPNode

extension ReverbNode: GraphNodeDSPProvider, DSPNode {
    var nodeId: UUID { id }
    func dspNode() -> DSPNode? { self }

    func render(
        inputs: UnsafeBufferPointer<AudioBuffer>,
        output: AudioBuffer,
        frameCount: Int,
        sampleRate: Double
    ) {
        // P1.5 — snapshot user-facing params before the smoothing lines.
        let wdm = wetDryMix
        let damp = damping
        let rs = roomSize
        let dec = decay

        guard let inBuf = inputs.first else {
            for i in 0..<frameCount {
                output.left[i] = 0
                output.right[i] = 0
            }
            return
        }

        let alpha: Float = 0.05
        smoothedWetDryMix += alpha * (wdm - smoothedWetDryMix)
        smoothedDamping += alpha * (damp - smoothedDamping)
        let targetFeedback = min(0.92, 0.55 + rs * 0.35 + dec * 0.02)
        smoothedFeedback += alpha * (targetFeedback - smoothedFeedback)

        let wet = min(max(smoothedWetDryMix, 0), 1)
        let dry = 1 - wet
        let dampCoeff = min(max(smoothedDamping, 0), 0.99)

        for i in 0..<frameCount {
            let inL = inBuf.left[i]
            let inR = inBuf.right[i]
            var combL: Float = 0
            var combR: Float = 0

            for c in 0..<combDelaysL.count {
                let (dl, dr) = combSample(
                    input: (inL + inR) * 0.5,
                    index: c,
                    feedback: smoothedFeedback * combFeedback[c],
                    bufferL: &combDelaysL[c],
                    bufferR: &combDelaysR[c],
                    writePos: &combWritePos[c]
                )
                combL += dl
                combR += dr
            }
            combL *= 0.16
            combR *= 0.16

            dampStateL = dampStateL * dampCoeff + combL * (1 - dampCoeff)
            dampStateR = dampStateR * dampCoeff + combR * (1 - dampCoeff)

            var apL = dampStateL
            var apR = dampStateR
            for a in 0..<allpassDelaysL.count {
                let (ol, or_) = allpassSample(
                    inputL: apL,
                    inputR: apR,
                    index: a,
                    bufferL: &allpassDelaysL[a],
                    bufferR: &allpassDelaysR[a],
                    writePos: &allpassWritePos[a]
                )
                apL = ol
                apR = or_
            }

            output.left[i] = inL * dry + apL * wet
            output.right[i] = inR * dry + apR * wet
        }
    }
}
