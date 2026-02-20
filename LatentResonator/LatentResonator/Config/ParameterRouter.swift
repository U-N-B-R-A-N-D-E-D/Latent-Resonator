import Foundation
import CoreMIDI
import Network

// MARK: - Control Parameter (MIDI CC + OSC mapping)
//
// Enum of performable parameters that can be driven by MIDI CC or OSC.
// Used by ParameterRouter for scaleCCToValue / valueToCC.
// OSC address: /lr/<rawValue> with a single float argument.

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
    case resonatorNote
    case resonatorDecay

    // Stochastic
    case entropy
    case granularity

    // ACE-Step inference
    case shift
    case inputStrength
    case inferenceSteps

    // Oscillator
    case sineFrequency
    case pulseWidth

    // LFO
    case lfoRate
    case lfoDepth

    // Global / toggles
    case crossfader
    case mute
    case solo
    case spectralMorphActive
    case autoDecayToggle
    case promptEvolution
    case inferMethodSDE
    case laneRecord
    case archiveRecall

    /// Continuous range (min, max). Toggles use (0, 1) and isToggle == true.
    var floatRange: (Float, Float)? {
        switch self {
        case .volume, .mute, .solo, .spectralMorphActive, .autoDecayToggle,
             .promptEvolution, .inferMethodSDE, .laneRecord:
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
        case .resonatorNote:
            return (LRConstants.resonatorNoteRange.lowerBound,
                    LRConstants.resonatorNoteRange.upperBound)
        case .resonatorDecay:
            return (LRConstants.resonatorDecayRange.lowerBound,
                    LRConstants.resonatorDecayRange.upperBound)
        case .entropy:
            return (LRConstants.entropyRange.lowerBound,
                    LRConstants.entropyRange.upperBound)
        case .granularity:
            return (LRConstants.granularityRange.lowerBound,
                    LRConstants.granularityRange.upperBound)
        case .shift:
            return (LRConstants.aceShiftRange.lowerBound,
                    LRConstants.aceShiftRange.upperBound)
        case .inputStrength:
            return (LRConstants.inputStrengthRange.lowerBound,
                    LRConstants.inputStrengthRange.upperBound)
        case .inferenceSteps:
            return (Float(LRConstants.aceStepsRange.lowerBound),
                    Float(LRConstants.aceStepsRange.upperBound))
        case .sineFrequency:
            return (LRConstants.sineFrequencyRange.lowerBound,
                    LRConstants.sineFrequencyRange.upperBound)
        case .pulseWidth:
            return (LRConstants.pulseWidthRange.lowerBound,
                    LRConstants.pulseWidthRange.upperBound)
        case .lfoRate:
            return (LRConstants.lfoRateRange.lowerBound,
                    LRConstants.lfoRateRange.upperBound)
        case .lfoDepth:
            return (LRConstants.lfoDepthRange.lowerBound,
                    LRConstants.lfoDepthRange.upperBound)
        case .archiveRecall:
            return (0.0, Float(LRConstants.iterationArchiveSize - 1))
        }
    }

    /// Toggle params: CC < 64 -> 0, CC >= 64 -> 1.
    var isToggle: Bool {
        switch self {
        case .mute, .solo, .spectralMorphActive, .autoDecayToggle,
             .promptEvolution, .inferMethodSDE, .laneRecord:
            return true
        default: return false
        }
    }

    /// Default MIDI CC (unique per parameter). CC 20-51.
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
        case .autoDecayToggle:     return 38
        case .archiveRecall:       return 39
        case .shift:               return 40
        case .inputStrength:       return 41
        case .inferenceSteps:      return 42
        case .sineFrequency:       return 43
        case .pulseWidth:          return 44
        case .resonatorNote:       return 45
        case .resonatorDecay:      return 46
        case .lfoRate:             return 47
        case .lfoDepth:            return 48
        case .promptEvolution:     return 49
        case .inferMethodSDE:      return 50
        case .laneRecord:          return 51
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

final class MIDIInputManager: ObservableObject {

    private var midiClient: MIDIClientRef = 0
    private var inputPort: MIDIPortRef = 0

    /// CC -> ControlParameter lookup (built from defaults, user-configurable later).
    var ccMap: [UInt8: ControlParameter]

    /// Callback invoked on main queue when a mapped CC is received.
    /// Parameters: (parameter, scaledValue)
    var onParameterChange: ((ControlParameter, Float) -> Void)?

    /// Callback invoked on main queue when any MIDI packet is received (CC, Note, etc.).
    /// Used by the Settings UI to show MIDI IN activity LED.
    var onActivity: (() -> Void)?

    /// Last time any MIDI message was received. UI uses this for the activity LED.
    @Published var lastActivityTime: Date?

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
                DispatchQueue.main.async { [weak self] in
                    self?.lastActivityTime = Date()
                    self?.onActivity?()
                }
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
            ccMap[cc] = param
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

// MARK: - OSC Input Manager (UDP)
//
// Receives OSC messages over UDP and routes them through ParameterRouter.
// Address format: /lr/<ControlParameter.rawValue> with a single float argument.
// Example: /lr/texture 0.75, /lr/guidanceScale 12.0, /lr/mute 1.0

final class OSCInputManager: ObservableObject {

    @Published var isEnabled: Bool = false {
        didSet { isEnabled ? start() : stop() }
    }
    @Published var port: UInt16 = 9000
    @Published var lastReceivedAddress: String = ""

    /// Traffic monitor: last packet validity and description for Settings > OSC.
    @Published var lastTrafficIsValid: Bool = true
    @Published var lastTrafficDescription: String = ""

    private var udpListener: NWListener?
    private var tcpListener: NWListener?
    private let queue = DispatchQueue(label: "lr.osc.input", qos: .userInteractive)

    var onParameterChange: ((ControlParameter, Float) -> Void)?

    /// Callback invoked when any packet is received. (isValid, description, rawData).
    /// Invalid = non-OSC protocol (e.g. MIDI/raw binary like ff 00...).
    var onTraffic: ((Bool, String, Data?) -> Void)?

    static let userDefaultsEnabledKey = "LatentResonator.oscEnabled"
    static let userDefaultsPortKey = "LatentResonator.oscPort"

    init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.userDefaultsEnabledKey)
        let saved = UserDefaults.standard.integer(forKey: Self.userDefaultsPortKey)
        if saved > 0 { port = UInt16(saved) }
    }

    func saveSettings() {
        UserDefaults.standard.set(isEnabled, forKey: Self.userDefaultsEnabledKey)
        UserDefaults.standard.set(Int(port), forKey: Self.userDefaultsPortKey)
    }

    func start() {
        stop()
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }

        // UDP listener
        let udpParams = NWParameters.udp
        udpParams.allowLocalEndpointReuse = true
        do {
            udpListener = try NWListener(using: udpParams, on: nwPort)
        } catch {
            print(">> OSC: Failed to create UDP listener on port \(port): \(error)")
        }
        udpListener?.newConnectionHandler = { [weak self] connection in
            print(">> OSC: UDP connection from \(connection.endpoint)")
            connection.start(queue: self?.queue ?? .global())
            self?.receiveLoop(on: connection)
        }
        udpListener?.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print(">> OSC: Listening on UDP port \(nwPort.rawValue)")
            case .failed(let err):
                print(">> OSC: UDP listener failed: \(err)")
            case .cancelled:
                print(">> OSC: UDP listener cancelled")
            default: break
            }
        }
        udpListener?.service = NWListener.Service(name: "Latent Resonator", type: "_osc._udp.")
        udpListener?.start(queue: queue)

        // TCP listener (OSC-over-TCP with SLIP or length-prefix framing)
        let tcpParams = NWParameters.tcp
        tcpParams.allowLocalEndpointReuse = true
        do {
            tcpListener = try NWListener(using: tcpParams, on: nwPort)
        } catch {
            print(">> OSC: Failed to create TCP listener on port \(port): \(error)")
        }
        tcpListener?.newConnectionHandler = { [weak self] connection in
            print(">> OSC: TCP connection from \(connection.endpoint)")
            connection.start(queue: self?.queue ?? .global())
            self?.tcpReceiveLoop(on: connection)
        }
        tcpListener?.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print(">> OSC: Listening on TCP port \(nwPort.rawValue)")
            case .failed(let err):
                print(">> OSC: TCP listener failed: \(err)")
            case .cancelled:
                print(">> OSC: TCP listener cancelled")
            default: break
            }
        }
        tcpListener?.service = NWListener.Service(name: "Latent Resonator", type: "_osc._tcp.")
        tcpListener?.start(queue: queue)
    }

    func stop() {
        udpListener?.cancel()
        udpListener = nil
        tcpListener?.cancel()
        tcpListener = nil
    }

    private func receiveLoop(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            if let data = data, !data.isEmpty {
                self?.parseOSCMessage(data)
            }
            if error == nil {
                self?.receiveLoop(on: connection)
            }
        }
    }

    /// OSC-over-TCP: read 4-byte big-endian length prefix, then the OSC packet.
    /// Falls back to treating raw data as OSC if no valid length prefix.
    private func tcpReceiveLoop(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            if let data = data, !data.isEmpty {
                self?.handleTCPData(data, on: connection)
            }
            if isComplete || error != nil {
                connection.cancel()
                return
            }
            self?.tcpReceiveLoop(on: connection)
        }
    }

    private func handleTCPData(_ data: Data, on connection: NWConnection) {
        if data.count >= 4 {
            let possibleLen = data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
            if possibleLen > 0, possibleLen <= 65536, data.count >= 4 + Int(possibleLen) {
                let oscData = data.subdata(in: 4..<(4 + Int(possibleLen)))
                parseOSCMessage(oscData)
                return
            }
        }
        parseOSCMessage(data)
    }

    private func parseOSCMessage(_ data: Data) {
        // Detect non-OSC packets (e.g. MIDI/raw binary ff 00...) — report as invalid
        guard data.count >= 4, data[0] == 0x2F else {
            reportTraffic(isValid: false, description: invalidPacketDescription(data), data: data)
            return
        }

        guard let address = readOSCString(from: data, at: 0) else {
            reportTraffic(isValid: false, description: invalidPacketDescription(data), data: data)
            return
        }
        var offset = alignTo4(address.count + 1)

        guard let typeTag = readOSCString(from: data, at: offset) else {
            reportTraffic(isValid: false, description: invalidPacketDescription(data), data: data)
            return
        }
        offset += alignTo4(typeTag.count + 1)

        guard typeTag == ",f", offset + 4 <= data.count else {
            reportTraffic(isValid: false, description: invalidPacketDescription(data), data: data)
            return
        }

        let floatValue: Float = data.subdata(in: offset..<offset + 4).withUnsafeBytes {
            Float(bitPattern: UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self)))
        }

        guard address.hasPrefix("/lr/") else {
            reportTraffic(isValid: true, description: "\(address) \(floatValue)", data: nil)
            return
        }
        let paramName = String(address.dropFirst(4))
        guard let param = ControlParameter(rawValue: paramName) else {
            reportTraffic(isValid: true, description: "\(address) \(floatValue)", data: nil)
            return
        }

        let value: Float
        if param.isToggle {
            value = floatValue >= 0.5 ? 1.0 : 0.0
        } else if let (lo, hi) = param.floatRange {
            value = min(hi, max(lo, floatValue))
        } else {
            value = floatValue
        }

        reportTraffic(isValid: true, description: "\(address) \(floatValue)", data: nil)
        DispatchQueue.main.async { [weak self] in
            self?.lastReceivedAddress = address
            self?.onParameterChange?(param, value)
        }
    }

    private func reportTraffic(isValid: Bool, description: String, data: Data?) {
        DispatchQueue.main.async { [weak self] in
            self?.lastTrafficIsValid = isValid
            self?.lastTrafficDescription = description
            self?.onTraffic?(isValid, description, data)
        }
    }

    private func invalidPacketDescription(_ data: Data) -> String {
        let hex = data.prefix(32).map { String(format: "%02X", $0) }.joined(separator: " ")
        return "[HEX] \(hex)\(data.count > 32 ? " …" : "") (Protocol Mismatch)"
    }

    private func readOSCString(from data: Data, at offset: Int) -> String? {
        guard offset < data.count else { return nil }
        var end = offset
        while end < data.count && data[end] != 0 { end += 1 }
        return String(data: data[offset..<end], encoding: .utf8)
    }

    private func alignTo4(_ n: Int) -> Int { (n + 3) & ~3 }
}
