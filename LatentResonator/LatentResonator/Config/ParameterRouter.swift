import Foundation
import CoreMIDI

// MARK: - Control Parameter (MIDI CC mapping)
//
// Enum of performable parameters that can be driven by MIDI CC.
// Used by ParameterRouter for scaleCCToValue / valueToCC.
// Plan §6: MIDI map for scenes, crossfader, master CFG, focus-lane macros.

enum ControlParameter: String, CaseIterable {

    // Core lane parameters
    case volume
    case guidanceScale
    case feedback
    case texture
    case chaos
    case warmth

    // Filter
    case filterCutoff
    case filterResonance

    // Effects
    case delayMix
    case delayTime
    case delayFeedback
    case bitCrushDepth

    // Stochastic
    case entropy
    case granularity

    // Global / toggles
    case crossfader
    case mute
    case solo
    case spectralMorphActive

    /// Continuous range (min, max) or nil. Toggles use (0, 1) and isToggle == true.
    var floatRange: (Float, Float)? {
        switch self {
        case .volume, .mute, .solo, .spectralMorphActive:
            return (0.0, 1.0)
        case .guidanceScale:
            return (LRConstants.cfgScaleRange.lowerBound,
                    LRConstants.cfgScaleRange.upperBound)
        case .feedback:
            return (LRConstants.feedbackRange.lowerBound,
                    LRConstants.feedbackRange.upperBound)
        case .texture, .chaos, .warmth, .crossfader:
            return (0.0, 1.0)
        case .filterCutoff:
            return (LRConstants.filterCutoffRange.lowerBound,
                    LRConstants.filterCutoffRange.upperBound)
        case .filterResonance:
            return (LRConstants.filterResonanceRange.lowerBound,
                    LRConstants.filterResonanceRange.upperBound)
        case .delayMix:
            return (LRConstants.delayMixRange.lowerBound,
                    LRConstants.delayMixRange.upperBound)
        case .delayTime:
            return (LRConstants.delayTimeRange.lowerBound,
                    LRConstants.delayTimeRange.upperBound)
        case .delayFeedback:
            return (LRConstants.delayFeedbackRange.lowerBound,
                    LRConstants.delayFeedbackRange.upperBound)
        case .bitCrushDepth:
            return (LRConstants.bitCrushRange.lowerBound,
                    LRConstants.bitCrushRange.upperBound)
        case .entropy:
            return (LRConstants.entropyRange.lowerBound,
                    LRConstants.entropyRange.upperBound)
        case .granularity:
            return (LRConstants.granularityRange.lowerBound,
                    LRConstants.granularityRange.upperBound)
        }
    }

    /// Toggle params: CC < 64 -> 0, CC >= 64 -> 1.
    var isToggle: Bool {
        switch self {
        case .mute, .solo, .spectralMorphActive: return true
        default: return false
        }
    }

    /// Default MIDI CC (unique per parameter).
    /// CC 20-39 reserved for LatentResonator focus-lane routing.
    var defaultCC: UInt8 {
        switch self {
        case .volume:              return 20
        case .guidanceScale:       return 21
        case .mute:                return 22
        case .solo:                return 23
        case .spectralMorphActive: return 24
        case .texture:             return 25
        case .chaos:               return 26
        case .warmth:              return 27
        case .crossfader:          return 28
        case .feedback:            return 29
        case .filterCutoff:        return 30
        case .filterResonance:     return 31
        case .delayMix:            return 32
        case .delayTime:           return 33
        case .delayFeedback:       return 34
        case .bitCrushDepth:       return 35
        case .entropy:             return 36
        case .granularity:         return 37
        }
    }
}

// MARK: - Parameter Router

enum ParameterRouter {

    /// Map MIDI CC 0-127 to parameter value in the parameter's float range.
    /// - Toggles: CC < 64 -> 0.0, CC >= 64 -> 1.0.
    /// - Continuous: linear map CC/127 -> [lo, hi].
    static func scaleCCToValue(_ cc: UInt8, for param: ControlParameter) -> Float {
        if param.isToggle {
            return cc >= 64 ? 1.0 : 0.0
        }
        guard let (lo, hi) = param.floatRange else { return 0 }
        let t = Float(cc) / 127.0
        return lo + t * (hi - lo)
    }

    /// Map a value in the parameter's range to CC 0-127.
    static func valueToCC(_ value: Float, for param: ControlParameter) -> UInt8 {
        if param.isToggle {
            return value >= 0.5 ? 127 : 0
        }
        guard let (lo, hi) = param.floatRange else { return 0 }
        let t = (value - lo) / (hi - lo)
        let clamped = max(0, min(1, t))
        return UInt8(clamped * 127)
    }

    /// Build the default CC -> ControlParameter lookup table.
    static func defaultCCMap() -> [UInt8: ControlParameter] {
        var map = [UInt8: ControlParameter]()
        for param in ControlParameter.allCases {
            map[param.defaultCC] = param
        }
        return map
    }
}

// MARK: - CoreMIDI Input Manager
//
// Receives MIDI CC messages from any connected controller and routes
// them through ParameterRouter into the NeuralEngine / ResonatorLane
// parameter space. Runs on the CoreMIDI real-time thread; parameter
// application is dispatched to the main queue for @Published safety.

final class MIDIInputManager {

    private var midiClient: MIDIClientRef = 0
    private var inputPort: MIDIPortRef = 0

    /// CC -> ControlParameter lookup (built from defaults, user-configurable later).
    var ccMap: [UInt8: ControlParameter]

    /// Callback invoked on main queue when a mapped CC is received.
    /// Parameters: (parameter, scaledValue)
    var onParameterChange: ((ControlParameter, Float) -> Void)?

    /// Parameter target for pitch bend (14-bit). Default: filter cutoff.
    var pitchBendTarget: ControlParameter = .filterCutoff

    /// Parameter target for channel aftertouch. Default: texture.
    var aftertouchTarget: ControlParameter = .texture

    /// MIDI Learn state: when true, the next CC received assigns to learningParameter.
    var isLearning: Bool = false
    var learningParameter: ControlParameter?

    /// Callback for UI notification when a MIDI Learn assignment completes.
    var onLearnComplete: (() -> Void)?

    init() {
        ccMap = MIDIInputManager.loadCustomCCMap() ?? ParameterRouter.defaultCCMap()
    }

    /// Engage MIDI Learn for a specific parameter. The next CC received
    /// will be mapped to this parameter, replacing any existing mapping.
    func startLearn(for param: ControlParameter) {
        learningParameter = param
        isLearning = true
    }

    /// Cancel an active MIDI Learn without assigning.
    func cancelLearn() {
        isLearning = false
        learningParameter = nil
    }

    /// Persist the current CC map to UserDefaults.
    func saveCCMap() {
        var dict = [String: String]()
        for (cc, param) in ccMap {
            dict[String(cc)] = param.rawValue
        }
        UserDefaults.standard.set(dict, forKey: "LatentResonator.customCCMap")
    }

    /// Load a custom CC map from UserDefaults.
    static func loadCustomCCMap() -> [UInt8: ControlParameter]? {
        guard let dict = UserDefaults.standard.dictionary(forKey: "LatentResonator.customCCMap") as? [String: String] else {
            return nil
        }
        var map = [UInt8: ControlParameter]()
        for (ccStr, paramStr) in dict {
            if let cc = UInt8(ccStr), let param = ControlParameter(rawValue: paramStr) {
                map[cc] = param
            }
        }
        return map.isEmpty ? nil : map
    }

    /// Reset CC map to defaults and clear persisted data.
    func resetCCMap() {
        ccMap = ParameterRouter.defaultCCMap()
        UserDefaults.standard.removeObject(forKey: "LatentResonator.customCCMap")
    }

    /// Start listening for MIDI input from all sources.
    func start() {
        let status = MIDIClientCreateWithBlock("LatentResonatorMIDI" as CFString, &midiClient) { [weak self] notification in
            // Handle source added/removed if needed
            let messageID = notification.pointee.messageID
            if messageID == .msgSetupChanged {
                self?.connectAllSources()
            }
        }
        guard status == noErr else {
            print(">> MIDI: Failed to create client (\(status))")
            return
        }

        let portStatus = MIDIInputPortCreateWithProtocol(
            midiClient,
            "LatentResonatorInput" as CFString,
            ._1_0,
            &inputPort
        ) { [weak self] eventList, _ in
            self?.handleMIDIEventList(eventList)
        }
        guard portStatus == noErr else {
            print(">> MIDI: Failed to create input port (\(portStatus))")
            return
        }

        connectAllSources()
        print(">> MIDI: Input manager started")
    }

    /// Stop MIDI input and dispose resources.
    func stop() {
        if inputPort != 0 {
            MIDIPortDispose(inputPort)
            inputPort = 0
        }
        if midiClient != 0 {
            MIDIClientDispose(midiClient)
            midiClient = 0
        }
    }

    /// Connect to all available MIDI sources.
    private func connectAllSources() {
        let sourceCount = MIDIGetNumberOfSources()
        for i in 0..<sourceCount {
            let source = MIDIGetSource(i)
            MIDIPortConnectSource(inputPort, source, nil)
        }
        if sourceCount > 0 {
            print(">> MIDI: Connected to \(sourceCount) source(s)")
        }
    }

    /// Parse MIDI 1.0 event list and route CC messages.
    private func handleMIDIEventList(_ eventListPtr: UnsafePointer<MIDIEventList>) {
        let eventList = eventListPtr.pointee
        var packet = eventList.packet

        for _ in 0..<eventList.numPackets {
            // MIDI 1.0 Universal Packet: 32-bit word
            let wordCount = packet.wordCount
            if wordCount >= 1 {
                let word = packet.words.0
                let messageType = (word >> 28) & 0xF
                let status = UInt8((word >> 16) & 0xFF)
                let data1 = UInt8((word >> 8) & 0xFF)
                let data2 = UInt8(word & 0xFF)

                // MIDI 1.0 channel voice message (type 0x2)
                if messageType == 0x2 {
                    let statusNibble = status & 0xF0

                    switch statusNibble {
                    // CC message: status 0xBn
                    case 0xB0:
                        routeCC(cc: data1, value: data2)

                    // Pitch Bend: status 0xEn (14-bit: data1 = LSB, data2 = MSB)
                    case 0xE0:
                        let combined = (UInt16(data2) << 7) | UInt16(data1)
                        let normalized = Float(combined) / 16383.0
                        let target = pitchBendTarget
                        if let (lo, hi) = target.floatRange {
                            let scaled = lo + normalized * (hi - lo)
                            DispatchQueue.main.async { [weak self] in
                                self?.onParameterChange?(target, scaled)
                            }
                        }

                    // Channel Aftertouch: status 0xDn (7-bit: data1 = pressure)
                    case 0xD0:
                        let target = aftertouchTarget
                        let scaled = ParameterRouter.scaleCCToValue(data1, for: target)
                        DispatchQueue.main.async { [weak self] in
                            self?.onParameterChange?(target, scaled)
                        }

                    default:
                        break
                    }
                }
            }
            packet = MIDIEventPacketNext(&packet).pointee
        }
    }

    /// Route a CC message through ParameterRouter.
    /// In MIDI Learn mode, assigns the incoming CC to the learning parameter.
    private func routeCC(cc: UInt8, value: UInt8) {
        if isLearning, let param = learningParameter {
            // Remove any existing mapping for this CC
            ccMap[cc] = param
            // Also remove any other CC that was mapped to the same param
            for (existingCC, existingParam) in ccMap where existingParam == param && existingCC != cc {
                ccMap.removeValue(forKey: existingCC)
            }
            isLearning = false
            learningParameter = nil
            saveCCMap()
            DispatchQueue.main.async { [weak self] in
                self?.onLearnComplete?()
            }
            return
        }

        guard let param = ccMap[cc] else { return }
        let scaled = ParameterRouter.scaleCCToValue(value, for: param)
        DispatchQueue.main.async { [weak self] in
            self?.onParameterChange?(param, scaled)
        }
    }
}
