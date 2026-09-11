import Foundation
import AVFoundation

// MARK: - Shared Control Types

/// Interpolation curve type for envelopes and modulation shapes
public enum CurveType: String, Codable, CaseIterable {
    case linear
    case exponential
    case logarithmic
    case sCurve
    case step
    
    var displayName: String {
        switch self {
        case .linear: return "Linear"
        case .exponential: return "Exponential"
        case .logarithmic: return "Logarithmic"
        case .sCurve: return "S-Curve"
        case .step: return "Step"
        }
    }
}

/// Single breakpoint for envelope/gesture interpolation
public struct Breakpoint: Identifiable, Codable, Equatable {
    public let id: UUID
    public var time: Float      // Normalized 0.0...1.0 within envelope duration
    public var value: Float     // Output value
    public var curve: CurveType // Interpolation curve to NEXT breakpoint
    
    public init(id: UUID = UUID(), time: Float, value: Float, curve: CurveType = .linear) {
        self.id = id
        self.time = time
        self.value = value
        self.curve = curve
    }
}

// MARK: - Control Nodes (Phase 1)
//
// These nodes wrap ModulationEngine modulators for use in the NodeGraph.
// They exist ONLY inside MacroNode.internalGraph and provide control-rate
// signals for parameter modulation.
//
// Architecture notes:
// - No audio path (audioUnit() returns nil)
// - Output: control signals (Float) via control-type edges
// - Evaluated at 60Hz by ControlGraphEvaluator (Phase 2)
// - Modulate lane parameters via ModulationEngine connections

// MARK: - Agitation Node

/// LFO/modulation source node wrapping AgitationModulator.
/// Multiple waveforms (sine, triangle, saw, square, S&H, random walk).
final class AgitationNode: BaseGraphNode {
    
    /// The underlying modulator (source of truth for parameters).
    let modulator: AgitationModulator
    
    override var category: NodeCategory { .control }
    
    override var ports: [NodePort] {
        [NodePort(id: "out", label: "CV OUT", signalType: .control, direction: .output)]
    }
    
    init(id: UUID = UUID(), params: [String: Any] = [:]) {
        // Create modulator with default values
        self.modulator = AgitationModulator(name: "Agitation", sourceId: id)
        
        super.init(
            id: id,
            nodeType: "agitation",
            category: .control,
            displayName: "Agitation"
        )
        
        // Apply params if provided
        if let rate = params["rate"] as? Float {
            modulator.rate = rate
        }
        if let depth = params["depth"] as? Float {
            modulator.depth = depth
        }
        if let waveformRaw = params["waveform"] as? String,
           let waveform = AgitationWaveform(rawValue: waveformRaw) {
            modulator.waveform = waveform
        }
        if let symmetry = params["symmetry"] as? Float {
            modulator.symmetry = symmetry
        }
        
        // Expose parameters for UI binding
        self.parameters["rate"] = modulator.rate
        self.parameters["depth"] = modulator.depth
        self.parameters["waveform"] = modulator.waveform.rawValue
        self.parameters["symmetry"] = modulator.symmetry
    }
    
    required init(from decoder: Decoder) throws {
        self.modulator = AgitationModulator(name: "Agitation", sourceId: UUID())
        try super.init(from: decoder)
        // Sync modulator from decoded parameters
        if let rate = parameters["rate"] as? Float {
            modulator.rate = rate
        }
        if let depth = parameters["depth"] as? Float {
            modulator.depth = depth
        }
        if let waveformRaw = parameters["waveform"] as? String,
           let waveform = AgitationWaveform(rawValue: waveformRaw) {
            modulator.waveform = waveform
        }
        if let symmetry = parameters["symmetry"] as? Float {
            modulator.symmetry = symmetry
        }
    }
    
    // MARK: - BaseGraphNode Overrides
    
    override func audioUnit() -> AVAudioNode? {
        return nil // Control-only node, no audio path
    }
    
    /// Update parameters when changed from UI or graph mutation.
    /// Override didSet on parameters to sync to modulator.
    func updateParameter(id: String, value: Any) {
        parameters[id] = value
        
        // Sync to modulator
        switch id {
        case "rate":
            if let v = value as? Float { modulator.rate = v }
        case "depth":
            if let v = value as? Float { modulator.depth = v }
        case "waveform":
            if let str = value as? String, let wf = AgitationWaveform(rawValue: str) {
                modulator.waveform = wf
            }
        case "symmetry":
            if let v = value as? Float { modulator.symmetry = v }
        default:
            break
        }
    }
    
    /// Evaluate control output at time t. Called by ControlGraphEvaluator (Phase 2).
    func evaluate(at time: TimeInterval, dt: Double) -> Float {
        // Create a dummy connection for evaluation (or use first real connection if available)
        let dummyConnection = ModulationConnection(
            destination: ModulationAddress(nodeId: id, parameter: .volume),
            scale: 1.0
        )
        return modulator.evaluate(connection: dummyConnection, dt: dt)
    }
}

// MARK: - Peak Node

/// Envelope generator node wrapping PeakModulator.
/// Triggered ADSR with probability gate for performance expressiveness.
final class PeakNode: BaseGraphNode {
    
    /// The underlying modulator (source of truth for parameters).
    let modulator: PeakModulator
    
    override var category: NodeCategory { .control }
    
    override var ports: [NodePort] {
        [
            NodePort(id: "trigger", label: "TRIG IN", signalType: .gate, direction: .input),
            NodePort(id: "out", label: "CV OUT", signalType: .control, direction: .output)
        ]
    }
    
    init(id: UUID = UUID(), params: [String: Any] = [:]) {
        // Create modulator with default values
        self.modulator = PeakModulator(name: "Peak", sourceId: id)
        
        super.init(
            id: id,
            nodeType: "peak",
            category: .control,
            displayName: "Peak"
        )
        
        // Apply params if provided
        if let attack = params["attack"] as? Float {
            modulator.attack = attack
        }
        if let hold = params["hold"] as? Float {
            modulator.hold = hold
        }
        if let decay = params["decay"] as? Float {
            modulator.decay = decay
        }
        if let curve = params["curveExponent"] as? Float {
            modulator.curveExponent = curve
        }
        if let prob = params["triggerProbability"] as? Float {
            modulator.triggerProbability = prob
        }
        
        // Expose parameters for UI binding
        self.parameters["attack"] = modulator.attack
        self.parameters["hold"] = modulator.hold
        self.parameters["decay"] = modulator.decay
        self.parameters["curveExponent"] = modulator.curveExponent
        self.parameters["triggerProbability"] = modulator.triggerProbability
    }
    
    required init(from decoder: Decoder) throws {
        self.modulator = PeakModulator(name: "Peak", sourceId: UUID())
        try super.init(from: decoder)
        // Sync modulator from decoded parameters
        if let v = parameters["attack"] as? Float { modulator.attack = v }
        if let v = parameters["hold"] as? Float { modulator.hold = v }
        if let v = parameters["decay"] as? Float { modulator.decay = v }
        if let v = parameters["curveExponent"] as? Float { modulator.curveExponent = v }
        if let v = parameters["triggerProbability"] as? Float { modulator.triggerProbability = v }
    }
    
    // MARK: - BaseGraphNode Overrides
    
    override func audioUnit() -> AVAudioNode? {
        return nil // Control-only node, no audio path
    }
    
    /// Update parameters when changed from UI or graph mutation.
    func updateParameter(id: String, value: Any) {
        parameters[id] = value
        
        // Sync to modulator
        switch id {
        case "attack":
            if let v = value as? Float { modulator.attack = v }
        case "hold":
            if let v = value as? Float { modulator.hold = v }
        case "decay":
            if let v = value as? Float { modulator.decay = v }
        case "curveExponent":
            if let v = value as? Float { modulator.curveExponent = v }
        case "triggerProbability":
            if let v = value as? Float { modulator.triggerProbability = v }
        default:
            break
        }
    }
    
    /// Trigger the envelope. Called when a gate signal arrives.
    func trigger() {
        modulator.trigger()
    }
    
    /// Evaluate control output at time t. Called by ControlGraphEvaluator (Phase 2).
    func evaluate(at time: TimeInterval, dt: Double) -> Float {
        // Create a dummy connection for evaluation (or use first real connection if available)
        let dummyConnection = ModulationConnection(
            destination: ModulationAddress(nodeId: id, parameter: .volume),
            scale: 1.0
        )
        return modulator.evaluate(connection: dummyConnection, dt: dt)
    }
}

// MARK: - Manual Control Node

/// Manual control value node wrapping ControlModulator.
/// Provides a user-adjustable CV source (knob/fader) with slew limiting.
/// Replaces texture/chaos/warmth macros with explicit meta-parameter mapping.
final class ManualControlNode: BaseGraphNode {
    
    /// The underlying modulator (source of truth for parameters).
    let modulator: ControlModulator
    
    override var category: NodeCategory { .control }
    
    override var ports: [NodePort] {
        [NodePort(id: "out", label: "CV OUT", signalType: .control, direction: .output)]
    }
    
    init(id: UUID = UUID(), params: [String: Any] = [:]) {
        // Create modulator with default values
        self.modulator = ControlModulator(name: "Manual Control", sourceId: id)
        
        super.init(
            id: id,
            nodeType: "manual_control",
            category: .control,
            displayName: "Manual Control"
        )
        
        // Apply params if provided
        if let value = params["value"] as? Float {
            modulator.value = value
        }
        if let slew = params["slewRate"] as? Float {
            modulator.slewRate = slew
        }
        
        // Expose parameters for UI binding
        self.parameters["value"] = modulator.value
        self.parameters["slewRate"] = modulator.slewRate
    }
    
    required init(from decoder: Decoder) throws {
        self.modulator = ControlModulator(name: "Manual Control", sourceId: UUID())
        try super.init(from: decoder)
        // Sync modulator from decoded parameters
        if let v = parameters["value"] as? Float { modulator.value = v }
        if let v = parameters["slewRate"] as? Float { modulator.slewRate = v }
    }
    
    // MARK: - BaseGraphNode Overrides
    
    override func audioUnit() -> AVAudioNode? {
        return nil // Control-only node, no audio path
    }
    
    /// Update parameters when changed from UI or graph mutation.
    func updateParameter(id: String, value: Any) {
        parameters[id] = value
        
        // Sync to modulator
        switch id {
        case "value":
            if let v = value as? Float { modulator.value = v }
        case "slewRate":
            if let v = value as? Float { modulator.slewRate = v }
        default:
            break
        }
    }
    
    /// Evaluate control output at time t. Called by ControlGraphEvaluator (Phase 2).
    /// Returns the current manual value directly (0..1), bypassing the
    /// modulator's bipolar/slew path so that control edges see a stable,
    /// predictable 0..1 signal.
    func evaluate(at time: TimeInterval, dt: Double) -> Float {
        return modulator.value
    }
}

// MARK: - MetaParameter Node (Decision D3)

/// Multi-breakpoint envelope generator for meta-parameter automation.
/// Implements D3: MetaParameterNode with breakpoint envelopes.
///
/// Features:
/// - Up to 16 breakpoints (time, value, curve)
/// - Real-time interpolation at 60Hz control rate
/// - Loop mode with optional crossfade
/// - Gate input for one-shot or retrigger
///
/// Architecture: Evaluated by ControlGraphEvaluator, outputs control signals
/// that modulate other node parameters. No audio path.
final class MetaParameterNode: BaseGraphNode {
    
    // Uses shared CurveType and Breakpoint defined at file level
    
    // MARK: - State
    
    /// Breakpoints defining the envelope shape (sorted by time)
    private(set) var breakpoints: [Breakpoint] = []
    
    /// Envelope duration in seconds
    var duration: Float = 1.0 {
        didSet { parameters["duration"] = duration }
    }
    
    /// Loop mode - restart after reaching end
    var loopMode: Bool = false {
        didSet { parameters["loopMode"] = loopMode }
    }
    
    /// Current playback position (0.0...1.0 normalized)
    /// P5 Slice 1: exposed as `private(set)` so the PERFORM envelope
    /// visualization (`EnvelopeCurveView`) can read the live phase
    /// without coupling to the evaluator's internal tick. Mutated only
    /// by `evaluate(dt:)` on the control thread.
    private(set) var phase: Float = 0.0
    
    /// True while gate is high (one-shot plays while high)
    private var isRunning: Bool = false
    
    /// Sample rate for control evaluation (typically 60Hz)
    private let controlRate: Double = 60.0
    
    required init(from decoder: Decoder) throws {
        try super.init(from: decoder)
    }

    
    // MARK: - Ports
    
    override var category: NodeCategory { .control }
    
    override var ports: [NodePort] {
        [
            NodePort(id: "gate", label: "GATE", signalType: .gate, direction: .input),
            NodePort(id: "out", label: "CV OUT", signalType: .control, direction: .output)
        ]
    }
    
    // MARK: - Initialization
    
    init(id: UUID = UUID(), params: [String: Any] = [:]) {
        super.init(
            id: id,
            nodeType: "meta_parameter",
            category: .control,
            displayName: "Meta Param"
        )
        
        // Set default breakpoints (attack-decay-sustain-release shape)
        breakpoints = [
            Breakpoint(time: 0.0, value: 0.0, curve: .linear),
            Breakpoint(time: 0.1, value: 1.0, curve: .exponential),
            Breakpoint(time: 0.3, value: 0.7, curve: .linear),
            Breakpoint(time: 1.0, value: 0.0, curve: .exponential)
        ]
        
        // Apply params if provided
        if let duration = params["duration"] as? Float {
            self.duration = duration
        }
        if let loopMode = params["loopMode"] as? Bool {
            self.loopMode = loopMode
        }
        if let breakpointsData = params["breakpoints"] as? Data,
           let decoded = try? JSONDecoder().decode([Breakpoint].self, from: breakpointsData) {
            self.breakpoints = decoded
        }
        
        // Expose parameters
        updateParameters()
    }
    
    // MARK: - Breakpoint Management
    
    /// Add a new breakpoint at specified time (inserts at correct position)
    func addBreakpoint(time: Float, value: Float, curve: CurveType = .linear) -> Breakpoint {
        let newBreakpoint = Breakpoint(time: time, value: value, curve: curve)
        breakpoints.append(newBreakpoint)
        sortBreakpoints()
        updateParameters()
        return newBreakpoint
    }
    
    /// Remove a breakpoint by ID
    func removeBreakpoint(id: UUID) {
        breakpoints.removeAll { $0.id == id }
        // Ensure at least 2 breakpoints remain
        if breakpoints.count < 2 {
            breakpoints = [
                Breakpoint(time: 0.0, value: 0.0, curve: .linear),
                Breakpoint(time: 1.0, value: 1.0, curve: .linear)
            ]
        }
        updateParameters()
    }
    
    /// Update an existing breakpoint
    func updateBreakpoint(id: UUID, time: Float? = nil, value: Float? = nil, curve: CurveType? = nil) {
        guard let index = breakpoints.firstIndex(where: { $0.id == id }) else { return }
        
        let old = breakpoints[index]
        breakpoints[index] = Breakpoint(
            id: id,
            time: time ?? old.time,
            value: value ?? old.value,
            curve: curve ?? old.curve
        )
        
        if time != nil {
            sortBreakpoints()
        }
        updateParameters()
    }
    
    /// Sort breakpoints by time (ensures monotonic order)
    private func sortBreakpoints() {
        breakpoints.sort { $0.time < $1.time }
    }
    
    /// Sync node parameters with current state
    private func updateParameters() {
        parameters["duration"] = duration
        parameters["loopMode"] = loopMode
        if let encoded = try? JSONEncoder().encode(breakpoints) {
            parameters["breakpoints"] = encoded
        }
        parameters["breakpointCount"] = Float(breakpoints.count)
    }
    
    // MARK: - BaseGraphNode Overrides
    
    override func audioUnit() -> AVAudioNode? {
        return nil // Control-only node
    }
    
    /// Update parameters from UI or graph mutation
    func updateParameter(id: String, value: Any) {
        parameters[id] = value
        
        switch id {
        case "duration":
            if let v = value as? Float { duration = v }
        case "loopMode":
            if let v = value as? Bool { loopMode = v }
        default:
            break
        }
    }
    
    // MARK: - Real-time Evaluation (ControlGraphEvaluator)
    
    /// Trigger the envelope (gate high)
    func trigger() {
        phase = 0.0
        isRunning = true
    }
    
    /// Release the envelope (gate low)
    func release() {
        isRunning = loopMode // Keep running if looping, else stop
    }
    
    /// Evaluate control output at current time.
    /// Called at control rate (60Hz) by ControlGraphEvaluator.
    ///
    /// - Parameter dt: Delta time since last evaluation
    /// - Returns: Current interpolated value
    func evaluate(dt: Double) -> Float {
        guard isRunning || loopMode else { return 0.0 }
        guard breakpoints.count >= 2 else { return breakpoints.first?.value ?? 0.0 }
        
        // Advance phase
        let phaseIncrement = Float(dt / Double(duration))
        phase += phaseIncrement
        
        // Handle looping or termination
        if phase >= 1.0 {
            if loopMode {
                phase = phase - 1.0 // Wrap around
            } else {
                phase = 1.0
                isRunning = false
                return breakpoints.last?.value ?? 0.0
            }
        }
        
        // Find current segment
        guard let (from, to, t) = findSegment(phase: phase) else {
            return interpolateValue(between: breakpoints.first!, and: breakpoints.last!, t: phase)
        }
        
        // Interpolate with curve
        return interpolateValue(between: from, and: to, t: t)
    }
    
    /// Find the segment containing the given phase position.
    /// Returns (start breakpoint, end breakpoint, normalized position within segment)
    private func findSegment(phase: Float) -> (Breakpoint, Breakpoint, Float)? {
        guard breakpoints.count >= 2 else { return nil }
        
        for i in 0..<(breakpoints.count - 1) {
            let current = breakpoints[i]
            let next = breakpoints[i + 1]
            
            if phase >= current.time && phase <= next.time {
                let segmentDuration = next.time - current.time
                guard segmentDuration > 0.0001 else { continue }
                
                let t = (phase - current.time) / segmentDuration
                return (current, next, t)
            }
        }
        
        // Phase might be exactly at the end
        if let last = breakpoints.last, abs(phase - last.time) < 0.0001 {
            return (last, last, 0.0)
        }
        
        return nil
    }
    
    /// Interpolate between two breakpoints using the specified curve
    private func interpolateValue(between from: Breakpoint, and to: Breakpoint, t: Float) -> Float {
        let curve = from.curve // Use curve from start breakpoint
        
        let shapedT: Float
        switch curve {
        case .linear:
            shapedT = t
        case .exponential:
            shapedT = t * t // x^2
        case .logarithmic:
            shapedT = sqrt(t) // sqrt(x)
        case .sCurve:
            // Smooth step: 3t^2 - 2t^3
            shapedT = 3 * t * t - 2 * t * t * t
        case .step:
            shapedT = t < 0.5 ? 0.0 : 1.0
        }
        
        return from.value + (to.value - from.value) * shapedT
    }
    
    /// Evaluate at a specific absolute time (for testing and debugging)
    func valueAt(time: Float) -> Float {
        let normalizedTime = time / duration
        guard normalizedTime >= 0.0 && normalizedTime <= 1.0 else {
            return normalizedTime < 0.0 ? (breakpoints.first?.value ?? 0.0) : (breakpoints.last?.value ?? 0.0)
        }
        
        guard let (from, to, t) = findSegment(phase: normalizedTime) else {
            return breakpoints.first?.value ?? 0.0
        }
        
        return interpolateValue(between: from, and: to, t: t)
    }
}

// MARK: - Markov Sequencer Node (Whitepaper §1.2 — Xenakis Stochastic Synthesis)

/// Probabilistic sequencer using first-order Markov chain.
/// Transitions between states based on row-stochastic transition matrix.
/// Temperature parameter controls randomness: 0=deterministic, 1=true probs, >1=more random.
///
/// Philosophy: Xenakis *Formalized Music* (1971) — stochastic composition as structural principle.
/// Flatness-driven temperature = cybernetic feedback (Wiener) between spectral analysis and composition.
final class MarkovSequencerNode: BaseGraphNode {
    
    // MARK: - Parameters
    
    /// Number of states in the Markov chain
    @Published var stateCount: Int = 4 {
        didSet {
            // Resize matrix and values when state count changes
            if stateCount != oldValue {
                resizeToStateCount(stateCount)
            }
        }
    }
    
    /// NxN row-stochastic transition matrix (each row sums to 1.0)
    /// matrix[currentState][nextState] = probability
    @Published var transitionMatrix: [[Float]] = []
    
    /// Temperature: 0=deterministic (always pick highest prob),
    /// 1=use probabilities as-is, >1=more random (boltzmann-like)
    @Published var temperature: Float = 1.0
    
    /// Optional labels for each state (for text output to PromptBankNode)
    @Published var stateLabels: [String] = []
    
    /// Output control value for each state (normalized 0.0-1.0)
    @Published var stateValues: [Float] = []
    
    // MARK: - State
    
    /// Current state index (0..<stateCount)
    private var currentState: Int = 0
    
    /// RNG state for deterministic sequences
    private var rngState: UInt64 = 0
    
    /// Last clock time to prevent double-triggering
    private var lastClockTime: TimeInterval = 0
    
    // MARK: - Init
    
    init(id: UUID = UUID(), params: [String: Any] = [:]) {
        // Seed RNG with time
        self.rngState = UInt64(Date().timeIntervalSince1970 * 1000)
        
        super.init(
            id: id,
            nodeType: "markov_sequencer",
            category: .control,
            displayName: "Markov Sequencer"
        )
        
        // Apply params if provided
        if let count = params["stateCount"] as? Int {
            stateCount = max(2, min(16, count))
        }
        if let temp = params["temperature"] as? Float {
            temperature = temp
        }
        if let matrix = params["transitionMatrix"] as? [[Float]] {
            transitionMatrix = matrix
        } else {
            // Default to uniform matrix
            transitionMatrix = Self.uniformMatrix(size: stateCount)
        }
        
        // Initialize state values (evenly distributed)
        stateValues = (0..<stateCount).map { Float($0) / Float(stateCount - 1) }
        
        // Initialize empty labels
        stateLabels = Array(repeating: "", count: stateCount)
    }
    
    required init(from decoder: Decoder) throws {
        self.rngState = UInt64(Date().timeIntervalSince1970 * 1000)
        try super.init(from: decoder)
        // State will be restored by Codable
    }
    
    // MARK: - Matrix Factory Methods
    
    /// Create uniform random transition matrix (each state equally likely).
    static func uniformMatrix(size: Int) -> [[Float]] {
        let prob = 1.0 / Float(size)
        return (0..<size).map { _ in
            [Float](repeating: prob, count: size)
        }
    }
    
    /// Create cyclic transition matrix (deterministic: 0→1→2→...→0).
    static func cyclicMatrix(size: Int) -> [[Float]] {
        var matrix = [[Float]](repeating: [Float](repeating: 0, count: size), count: size)
        for i in 0..<size {
            matrix[i][(i + 1) % size] = 1.0
        }
        return matrix
    }
    
    /// Create self-loop biased matrix (high probability to stay in state).
    static func selfLoopMatrix(size: Int, stayProb: Float = 0.85) -> [[Float]] {
        let moveProb = (1.0 - stayProb) / Float(size - 1)
        return (0..<size).map { i in
            (0..<size).map { j in
                i == j ? stayProb : moveProb
            }
        }
    }
    
    // MARK: - Ports
    
    override var category: NodeCategory { .control }
    
    override var ports: [NodePort] {
        [
            NodePort(id: "value_out", label: "VALUE", signalType: .control, direction: .output),
            NodePort(id: "gate_out", label: "GATE", signalType: .gate, direction: .output),
            NodePort(id: "prompt_out", label: "PROMPT", signalType: .control, direction: .output),
            NodePort(id: "clock_in", label: "CLOCK", signalType: .gate, direction: .input),
            NodePort(id: "reset_in", label: "RESET", signalType: .gate, direction: .input),
            NodePort(id: "temp_cv", label: "TEMP", signalType: .control, direction: .input)
        ]
    }
    
    // MARK: - Evaluation
    
    func evaluateControl(portId: String, at time: TimeInterval) -> Float {
        switch portId {
        case "value_out":
            return stateValues[safe: currentState] ?? 0.0
        case "gate_out":
            // Gate is high for a short pulse after state change (50 ms inclusive)
            let timeSinceChange = time - lastClockTime
            return timeSinceChange <= 0.05 ? 1.0 : 0.0
        default:
            return 0.0
        }
    }
    
    /// Get text label for current state (for PromptBankNode integration)
    func evaluateText(portId: String) -> String? {
        guard portId == "prompt_out" else { return nil }
        guard currentState < stateLabels.count else { return nil }
        return stateLabels[currentState].isEmpty ? nil : stateLabels[currentState]
    }
    
    // MARK: - State Management
    
    /// Advance to next state based on Markov transition probabilities.
    /// Called when clock gate triggers.
    func onClockTrigger(currentTime: TimeInterval, tempCV: Float = 1.0) {
        // Debounce: prevent triggering faster than 10ms
        guard currentTime - lastClockTime > 0.01 else { return }
        lastClockTime = currentTime
        
        // Get transition probabilities for current state
        let probs = transitionMatrix[safe: currentState] ?? Array(repeating: 1.0 / Float(stateCount), count: stateCount)
        
        // Apply temperature: T<1 = more deterministic (sharpen distribution)
        // T>1 = more random (flatten/boltzmann distribution)
        let effectiveTemp = temperature * tempCV
        let adjustedProbs = applyTemperature(probs, temperature: effectiveTemp)
        
        // Select next state
        currentState = selectState(probabilities: adjustedProbs)
        
        objectWillChange.send()
    }
    
    /// Reset to state 0.
    func onResetTrigger() {
        currentState = 0
        objectWillChange.send()
    }
    
    /// Set specific state (for external control).
    func setState(_ state: Int) {
        currentState = max(0, min(stateCount - 1, state))
        objectWillChange.send()
    }
    
    /// Get current state for UI display.
    func getCurrentState() -> Int { currentState }
    
    // MARK: - Matrix Editing
    
    /// Set probability for a specific transition.
    /// Validates row-stochastic constraint (row sums to ~1.0).
    func setTransition(from: Int, to: Int, probability: Float) -> Bool {
        guard from >= 0 && from < stateCount else { return false }
        guard to >= 0 && to < stateCount else { return false }
        
        transitionMatrix[from][to] = max(0.0, min(1.0, probability))
        
        // Normalize row to maintain stochastic property
        let rowSum = transitionMatrix[from].reduce(0, +)
        if rowSum > 0 {
            transitionMatrix[from] = transitionMatrix[from].map { $0 / rowSum }
        }
        
        objectWillChange.send()
        return true
    }
    
    /// Resize matrix to new state count.
    private func resizeToStateCount(_ newCount: Int) {
        // Create new uniform matrix at new size
        transitionMatrix = Self.uniformMatrix(size: newCount)
        
        // Resize values and labels
        stateValues = (0..<newCount).map { Float($0) / Float(max(newCount - 1, 1)) }
        
        var newLabels = Array(repeating: "", count: newCount)
        for i in 0..<min(stateLabels.count, newCount) {
            newLabels[i] = stateLabels[i]
        }
        stateLabels = newLabels
        
        // Clamp current state
        currentState = min(currentState, newCount - 1)
    }
    
    // MARK: - Private Helpers
    
    /// Apply temperature to probability distribution.
    /// T<1: sharpen (raise to power 1/T)
    /// T>1: flatten using softmax-like transformation
    private func applyTemperature(_ probs: [Float], temperature: Float) -> [Float] {
        guard temperature > 0 else { return probs }
        
        if temperature < 1.0 {
            // Sharpen: raise to power 1/T
            let power = 1.0 / temperature
            let sharpened = probs.map { pow($0, power) }
            let sum = sharpened.reduce(0, +)
            return sum > 0 ? sharpened.map { $0 / sum } : probs
        } else if temperature > 1.0 {
            // Flatten: apply log and rescale (boltzmann-like)
            let flattened = probs.map { pow($0, temperature) }
            let sum = flattened.reduce(0, +)
            return sum > 0 ? flattened.map { $0 / sum } : probs
        }
        
        return probs
    }
    
    /// Select next state based on probability distribution.
    private func selectState(probabilities: [Float]) -> Int {
        guard !probabilities.isEmpty else { return 0 }
        
        // Generate random number 0..1 using xorshift
        let r = xorshiftFloat()
        
        // Cumulative probability selection
        var cumulative: Float = 0.0
        for (i, prob) in probabilities.enumerated() {
            cumulative += prob
            if r <= cumulative {
                return i
            }
        }
        
        return probabilities.count - 1
    }
    
    /// Xorshift64* RNG for deterministic sequences.
    private func xorshiftFloat() -> Float {
        rngState ^= rngState << 12
        rngState ^= rngState >> 25
        rngState ^= rngState << 27
        return Float(rngState & 0xFFFFFFFF) / Float(0xFFFFFFFF)
    }
}

// MARK: - Array Safety Extension

private extension Array {
    subscript(safe index: Int) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Gesture Recorder Node (D11 — MPE Trajectory Capture)

/// Captures MPE gestures (XY pad, crossfader, pressure) as recordable/replayable trajectories.
/// Integrates with MetaParameter breakpoint envelopes for complex modulation shapes.
///
/// Philosophy: MPE (MIDI Polyphonic Expression) extended beyond pitch/pressure
/// to any performance gesture. Trajectories become compositional material.
///
/// Architecture:
/// - Record: Captures (x, y, pressure, timestamp) at 60Hz during performance
/// - Store: Trajectory as array of GesturePoint (Codable for persistence)
/// - Replay: Outputs control signals matching recorded path
/// - Modulate: Apply to MetaParameter for envelope-like behavior
final class GestureRecorderNode: BaseGraphNode {
    
    // MARK: - Types
    
    /// Single point in a gesture trajectory
    struct GesturePoint: Codable {
        let x: Float        // 0.0-1.0 (XY pad X or crossfader position)
        let y: Float        // 0.0-1.0 (XY pad Y or pressure)
        let pressure: Float // 0.0-1.0 (MPE pressure/aftertouch)
        let time: Double    // Seconds from start of gesture
    }
    
    enum RecorderState: String, Codable {
        case idle       // Waiting to record
        case recording  // Capturing input
        case playing    // Replaying captured gesture
        case paused     // Paused during playback
    }
    
    // MARK: - Parameters
    
    /// Current state of the recorder
    @Published var state: RecorderState = .idle
    
    /// Maximum recording duration in seconds (default: 10s)
    @Published var maxDuration: Double = 10.0
    
    /// Playback speed multiplier (1.0 = normal, 2.0 = double speed)
    @Published var playbackRate: Float = 1.0
    
    /// Loop playback when reaching end
    @Published var loopPlayback: Bool = false
    
    /// Smooth interpolation between points (0=linear, 1=smoothstep)
    @Published var smoothness: Float = 0.5
    
    // MARK: - Trajectory Storage
    
    /// The recorded gesture trajectory
    @Published var trajectory: [GesturePoint] = []
    
    /// Named trajectories for quick recall (name → points)
    @Published var savedTrajectories: [String: [GesturePoint]] = [:]
    
    // MARK: - Runtime State
    
    private var recordingStartTime: Date?
    private var playbackStartTime: Date?
    private var currentPlaybackIndex: Int = 0
    private var recordTimer: Timer?
    private var playbackTimer: Timer?
    
    /// Temporary buffer during recording
    private var recordingBuffer: [GesturePoint] = []
    
    // MARK: - Input State (set externally from MPE/XY pad)
    
    /// Current input X (0.0-1.0) — set by external XY pad
    @Published var inputX: Float = 0.0
    
    /// Current input Y (0.0-1.0) — set by external XY pad  
    @Published var inputY: Float = 0.0
    
    /// Current pressure (0.0-1.0) — set by external MPE controller
    @Published var inputPressure: Float = 0.0
    
    // MARK: - Init
    
    init(id: UUID = UUID(), params: [String: Any] = [:]) {
        super.init(
            id: id,
            nodeType: "gesture_recorder",
            category: .control,
            displayName: "Gesture Recorder"
        )
        
        // Apply params
        if let maxDur = params["maxDuration"] as? Double {
            maxDuration = maxDur
        }
    }
    
    required init(from decoder: Decoder) throws {
        try super.init(from: decoder)
        // Timers and runtime state will be reset, trajectory data is loaded by Codable
    }

    // MARK: - Ports
    
    override var category: NodeCategory { .control }
    
    override var ports: [NodePort] {
        [
            // Outputs (modulation signals)
            NodePort(id: "x_out", label: "X", signalType: .control, direction: .output),
            NodePort(id: "y_out", label: "Y", signalType: .control, direction: .output),
            NodePort(id: "pressure_out", label: "PRESS", signalType: .control, direction: .output),
            NodePort(id: "gate_out", label: "GATE", signalType: .gate, direction: .output),
            
            // Control inputs
            NodePort(id: "record_trig", label: "REC", signalType: .gate, direction: .input),
            NodePort(id: "play_trig", label: "PLAY", signalType: .gate, direction: .input),
            NodePort(id: "stop_trig", label: "STOP", signalType: .gate, direction: .input),
            NodePort(id: "rate_cv", label: "RATE", signalType: .control, direction: .input)
        ]
    }
    
    // MARK: - Evaluation (Control Output)
    
    func evaluateControl(portId: String, at time: TimeInterval) -> Float {
        switch portId {
        case "x_out":
            return currentOutputX()
        case "y_out":
            return currentOutputY()
        case "pressure_out":
            return currentOutputPressure()
        case "gate_out":
            return (state == .recording || state == .playing) ? 1.0 : 0.0
        default:
            return 0.0
        }
    }
    
    /// Get current X output (live input during recording, trajectory during playback)
    func currentOutputX() -> Float {
        switch state {
        case .recording:
            return inputX
        case .playing:
            return interpolatedValue(at: currentPlaybackTime(), dimension: \.x)
        default:
            return trajectory.last?.x ?? inputX
        }
    }
    
    /// Get current Y output
    func currentOutputY() -> Float {
        switch state {
        case .recording:
            return inputY
        case .playing:
            return interpolatedValue(at: currentPlaybackTime(), dimension: \.y)
        default:
            return trajectory.last?.y ?? inputY
        }
    }
    
    /// Get current pressure output
    func currentOutputPressure() -> Float {
        switch state {
        case .recording:
            return inputPressure
        case .playing:
            return interpolatedValue(at: currentPlaybackTime(), dimension: \.pressure)
        default:
            return trajectory.last?.pressure ?? inputPressure
        }
    }
    
    /// Current playback position in seconds
    private func currentPlaybackTime() -> Double {
        guard let start = playbackStartTime else { return 0 }
        let elapsed = Date().timeIntervalSince(start)
        let scaled = elapsed * Double(playbackRate)
        
        guard let duration = trajectory.last?.time else { return 0 }
        
        if loopPlayback {
            return scaled.truncatingRemainder(dividingBy: duration)
        } else {
            return min(scaled, duration)
        }
    }
    
    /// Interpolate value at specific time from trajectory
    private func interpolatedValue(at time: Double, dimension: KeyPath<GesturePoint, Float>) -> Float {
        guard !trajectory.isEmpty else { return 0 }
        guard trajectory.count > 1 else { return trajectory[0][keyPath: dimension] }
        
        // Find surrounding points
        let before = trajectory.last { $0.time <= time }
        let after = trajectory.first { $0.time > time }
        
        guard let b = before else { return trajectory[0][keyPath: dimension] }
        guard let a = after else { return trajectory.last![keyPath: dimension] }
        
        // Linear interpolation (can be enhanced with smoothstep)
        let t = (time - b.time) / (a.time - b.time)
        let valB = b[keyPath: dimension]
        let valA = a[keyPath: dimension]
        
        if smoothness > 0 {
            // Smoothstep interpolation
            let smoothT = t * t * (3 - 2 * t)
            return valB + (valA - valB) * Float(smoothT)
        } else {
            return valB + (valA - valB) * Float(t)
        }
    }
    
    // MARK: - Control Interface
    
    /// Start recording a new gesture
    func startRecording() {
        guard state != .recording else { return }
        
        recordingBuffer = []
        recordingStartTime = Date()
        state = .recording
        
        // Start 60Hz capture timer
        recordTimer = Timer.scheduledTimer(withTimeInterval: 1.0/60.0, repeats: true) { [weak self] _ in
            self?.capturePoint()
        }
        
        // Auto-stop at maxDuration
        DispatchQueue.main.asyncAfter(deadline: .now() + maxDuration) { [weak self] in
            if self?.state == .recording {
                self?.stopRecording()
            }
        }
        
        objectWillChange.send()
    }
    
    /// Stop recording and store trajectory
    func stopRecording() {
        guard state == .recording else { return }
        
        // Capture the final input state so short recordings/tests have at least one point.
        capturePoint()
        
        recordTimer?.invalidate()
        recordTimer = nil
        
        trajectory = recordingBuffer
        state = .idle
        
        objectWillChange.send()
    }
    
    /// Start playback of recorded trajectory
    func startPlayback() {
        guard !trajectory.isEmpty else { return }
        guard state != .playing else { return }
        
        playbackStartTime = Date()
        state = .playing
        
        // Check for end of playback if not looping
        if !loopPlayback {
            if let duration = trajectory.last?.time {
                DispatchQueue.main.asyncAfter(deadline: .now() + duration / Double(playbackRate)) { [weak self] in
                    if self?.state == .playing {
                        self?.state = .idle
                        self?.objectWillChange.send()
                    }
                }
            }
        }
        
        objectWillChange.send()
    }
    
    /// Stop playback
    func stopPlayback() {
        guard state == .playing else { return }
        state = .idle
        objectWillChange.send()
    }
    
    /// Pause/unpause playback
    func togglePause() {
        if state == .playing {
            state = .paused
        } else if state == .paused {
            state = .playing
            // Adjust start time to account for pause
            playbackStartTime = Date().addingTimeInterval(-currentPlaybackTime())
        }
        objectWillChange.send()
    }
    
    /// Clear recorded trajectory
    func clear() {
        trajectory = []
        recordingBuffer = []
        state = .idle
        objectWillChange.send()
    }
    
    /// Save current trajectory with name
    func saveTrajectory(name: String) {
        guard !trajectory.isEmpty else { return }
        savedTrajectories[name] = trajectory
        objectWillChange.send()
    }
    
    /// Load saved trajectory by name
    func loadTrajectory(name: String) -> Bool {
        guard let saved = savedTrajectories[name] else { return false }
        trajectory = saved
        state = .idle
        objectWillChange.send()
        return true
    }
    
    /// Delete saved trajectory
    func deleteTrajectory(name: String) {
        savedTrajectories.removeValue(forKey: name)
        objectWillChange.send()
    }
    
    /// Convert trajectory to MetaParameterNode breakpoints
    /// Maps Y dimension to breakpoint values, time preserved
    func toMetaParameterCurve(curveType: CurveType = .linear) -> [Breakpoint] {
        trajectory.map { point in
            Breakpoint(
                time: Float(point.time),
                value: point.y,
                curve: curveType
            )
        }
    }
    
    /// Load trajectory from MetaParameterNode breakpoints
    func fromMetaParameterCurve(_ breakpoints: [Breakpoint], xValues: [Float]? = nil) {
        trajectory = breakpoints.enumerated().map { index, bp in
            GesturePoint(
                x: xValues?[safe: index] ?? Float(index) / Float(max(1, breakpoints.count - 1)),
                y: bp.value,
                pressure: bp.value,  // Use value as pressure if no explicit data
                time: Double(bp.time)
            )
        }
        objectWillChange.send()
    }
    
    // MARK: - Private
    
    /// Capture current input state at 60Hz during recording.
    /// - Parameter time: Optional absolute time; if omitted, the current time is used.
    func capturePoint(at time: TimeInterval? = nil) {
        guard state == .recording else { return }
        guard let start = recordingStartTime else { return }
        
        let t = time ?? Date().timeIntervalSince(start)
        let point = GesturePoint(
            x: inputX,
            y: inputY,
            pressure: inputPressure,
            time: t
        )
        
        recordingBuffer.append(point)
    }
    
    /// Handle gate triggers (called by ControlGraphEvaluator)
    func onGate(portId: String, trigger: Bool) {
        guard trigger else { return }
        
        switch portId {
        case "record_trig":
            if state == .recording {
                stopRecording()
            } else {
                startRecording()
            }
        case "play_trig":
            startPlayback()
        case "stop_trig":
            stopPlayback()
        default:
            break
        }
    }
}
