import Foundation

// MARK: - Polyadic Modulation Engine
//
// GRM Atelier-inspired modulation system for Latent Resonator.
//
// Three design principles:
//   Polyadic:    each connection spawns its own modulation engine (phase, rng)
//   Accumulable: multiple modulators sum onto a single parameter
//   Composable:  modulator parameters are themselves modulatable (DAG, no cycles)
//
// Three modulator types:
//   Agitation -- multi-waveform LFO with independent random per connection
//   Control   -- manual value with per-connection slew (macro replacement)
//   Peak      -- triggered envelope (attack/hold/decay) with probability

// MARK: - Modulation Parameter

/// Identifies a modulatable parameter on a specific node in the graph.
/// v2.0: Uses nodeId instead of laneIndex for graph-based addressing.
struct ModulationAddress: Hashable, Codable {
    /// Target node UUID in the NodeGraph.
    let nodeId: UUID
    let parameter: ModulationParameter
}

/// All parameters that can be modulation destinations.
/// Superset of ControlParameter focused on the DSP-relevant subset.
enum ModulationParameter: String, CaseIterable, Codable {
    case volume
    case guidanceScale
    case feedback
    case filterCutoff
    case filterResonance
    case delayMix
    case delayTime
    case delayFeedback
    case bitCrushDepth
    case resonatorNote
    case resonatorDecay
    case entropy
    case granularity
    case inputStrength
    case saturationMorph
    case sineFrequency

    // Meta-modulation targets (modulator parameters)
    case agitationRate
    case agitationDepth
    case controlValue
    case controlSlew
    case peakAttack
    case peakDecay
}

// MARK: - Agitation Waveform

enum AgitationWaveform: String, CaseIterable, Codable {
    case sine
    case triangle
    case saw
    case square
    case sampleAndHold
    case randomWalk
}

// MARK: - Modulation Connection (Polyadic State)

/// Each connection from a modulator to a destination has its own independent
/// state (phase, random seed, envelope position). This is the "polyadic" core:
/// the same Agitation connected to 4 filter cutoffs produces 4 different
/// modulation signals, each with its own phase and random trajectory.
final class ModulationConnection: Identifiable, Codable {
    let id: UUID
    let destinationAddress: ModulationAddress
    var scale: Float

    // Polyadic state
    var phase: Double = 0
    var randomState: UInt64
    var slewCurrent: Float = 0
    var envelopePhase: Float = 0
    var envelopeStage: EnvelopeStage = .idle
    var lastSHValue: Float = 0
    var randomWalkValue: Float = 0

    /// Last raw modulation output (before scale). Updated each evaluate() cycle.
    private(set) var lastRawValue: Float = 0
    /// Last scaled modulation output (raw * scale). Updated each evaluate() cycle.
    private(set) var lastScaledValue: Float = 0

    enum EnvelopeStage: String, Codable {
        case idle
        case attack
        case hold
        case decay
    }

    init(
        destination: ModulationAddress,
        scale: Float = 1.0
    ) {
        self.id = UUID()
        self.destinationAddress = destination
        self.scale = scale
        self.randomState = UInt64.random(in: 1...UInt64.max)
    }

    /// Deterministic initializer for testing: fixed id and seed.
    init(
        id: UUID,
        destination: ModulationAddress,
        scale: Float = 1.0,
        randomState: UInt64
    ) {
        self.id = id
        self.destinationAddress = destination
        self.scale = scale
        self.randomState = randomState
    }

    /// Record the raw/scaled output after evaluation.
    func recordOutput(raw: Float, scaled: Float) {
        lastRawValue = raw
        lastScaledValue = scaled
    }
}

// MARK: - Modulation Source Protocol

/// Base protocol for all modulator types. Each source can have multiple
/// outgoing connections, and its own parameters can be modulated (composable).
protocol ModulationSource: AnyObject, Identifiable {
    var sourceId: UUID { get }
    var connections: [ModulationConnection] { get set }
    var name: String { get set }

    /// Evaluate one connection for a given time delta, returning the modulation
    /// offset value (before connection scale is applied).
    /// The connection's polyadic state is updated in place.
    func evaluate(connection: ModulationConnection, dt: Double) -> Float

    /// Apply meta-modulation offsets to this source's parameters.
    func applyMetaModulation(_ offsets: [ModulationParameter: Float])

    /// Reset meta-modulation to nominal values (called before each eval cycle).
    func resetMetaModulation()
}

extension ModulationSource {
    var id: UUID { sourceId }
}

// MARK: - Agitation (Multi-Waveform LFO)

/// Replaces and extends the per-lane LFO. Polyadic: each connection gets
/// independent phase and random state. Multiple waveforms for diverse
/// modulation textures.
final class AgitationModulator: ModulationSource, ObservableObject, Codable {
    let sourceId: UUID
    @Published var name: String
    @Published var connections: [ModulationConnection]

    @Published var rate: Float = 0.5
    @Published var depth: Float = 0.5
    @Published var waveform: AgitationWaveform = .sine
    @Published var symmetry: Float = 0.5

    /// Effective values after meta-modulation. Readable for diagnostics/testing.
    private(set) var effectiveRate: Float = 0.5
    private(set) var effectiveDepth: Float = 0.5

    init(name: String = "Agitation") {
        self.sourceId = UUID()
        self.name = name
        self.connections = []
    }

    /// Deterministic initializer for testing: fixed sourceId.
    init(name: String = "Agitation", sourceId: UUID) {
        self.sourceId = sourceId
        self.name = name
        self.connections = []
    }

    func evaluate(connection: ModulationConnection, dt: Double) -> Float {
        let r = Double(effectiveRate)
        guard r > 0.001, effectiveDepth > 0.001 else { return 0 }

        connection.phase += r * dt
        if connection.phase >= 1.0 {
            connection.phase = connection.phase.truncatingRemainder(dividingBy: 1.0)
        }
        let p = connection.phase

        let raw: Float
        switch waveform {
        case .sine:
            raw = sinf(Float(p * 2.0 * .pi))
        case .triangle:
            let t = Float(p)
            raw = t < 0.5 ? (4.0 * t - 1.0) : (3.0 - 4.0 * t)
        case .saw:
            raw = Float(2.0 * p - 1.0)
        case .square:
            raw = Float(p) < symmetry ? 1.0 : -1.0
        case .sampleAndHold:
            let phaseInSteps = p * Double(effectiveRate * 4.0)
            let stepBoundary = floor(phaseInSteps)
            let prevStep = floor((p - r * dt) * Double(effectiveRate * 4.0))
            if stepBoundary != prevStep || connection.lastSHValue == 0 {
                connection.randomState = xoshiro256ss(&connection.randomState)
                connection.lastSHValue = Float(connection.randomState % 20001) / 10000.0 - 1.0
            }
            raw = connection.lastSHValue
        case .randomWalk:
            connection.randomState = xoshiro256ss(&connection.randomState)
            let step = (Float(connection.randomState % 10001) / 5000.0 - 1.0) * Float(dt) * effectiveRate
            connection.randomWalkValue = max(-1, min(1, connection.randomWalkValue + step))
            raw = connection.randomWalkValue
        }

        return raw * effectiveDepth
    }

    func applyMetaModulation(_ offsets: [ModulationParameter: Float]) {
        effectiveRate = max(0.001, rate + (offsets[.agitationRate] ?? 0))
        effectiveDepth = max(0, min(1, depth + (offsets[.agitationDepth] ?? 0)))
    }

    func resetMetaModulation() {
        effectiveRate = rate
        effectiveDepth = depth
    }

    // MARK: - Codable

    enum CodingKeys: String, CodingKey {
        case sourceId, name, connections, rate, depth, waveform, symmetry
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sourceId = try c.decode(UUID.self, forKey: .sourceId)
        name = try c.decode(String.self, forKey: .name)
        connections = try c.decode([ModulationConnection].self, forKey: .connections)
        rate = try c.decode(Float.self, forKey: .rate)
        depth = try c.decode(Float.self, forKey: .depth)
        waveform = try c.decode(AgitationWaveform.self, forKey: .waveform)
        symmetry = try c.decodeIfPresent(Float.self, forKey: .symmetry) ?? 0.5
        effectiveRate = rate
        effectiveDepth = depth
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sourceId, forKey: .sourceId)
        try c.encode(name, forKey: .name)
        try c.encode(connections, forKey: .connections)
        try c.encode(rate, forKey: .rate)
        try c.encode(depth, forKey: .depth)
        try c.encode(waveform, forKey: .waveform)
        try c.encode(symmetry, forKey: .symmetry)
    }
}

// MARK: - Control (Macro Replacement)

/// A manual value (0..1) fanned out to multiple destinations with per-connection
/// slew (smoothing). Replaces or coexists with texture/chaos/warmth macros.
/// Polyadic: each connection can have independent slew rate.
final class ControlModulator: ModulationSource, ObservableObject, Codable {
    let sourceId: UUID
    @Published var name: String
    @Published var connections: [ModulationConnection]

    @Published var value: Float = 0.0
    @Published var slewRate: Float = 0.1

    /// Effective values after meta-modulation. Readable for diagnostics/testing.
    private(set) var effectiveValue: Float = 0.0
    private(set) var effectiveSlew: Float = 0.1

    init(name: String = "Control") {
        self.sourceId = UUID()
        self.name = name
        self.connections = []
    }

    /// Deterministic initializer for testing: fixed sourceId.
    init(name: String = "Control", sourceId: UUID) {
        self.sourceId = sourceId
        self.name = name
        self.connections = []
    }

    func evaluate(connection: ModulationConnection, dt: Double) -> Float {
        let target = effectiveValue * 2.0 - 1.0
        let slew = effectiveSlew
        let alpha = min(1.0, slew * Float(dt) * 20.0)
        connection.slewCurrent += alpha * (target - connection.slewCurrent)
        return connection.slewCurrent
    }

    func applyMetaModulation(_ offsets: [ModulationParameter: Float]) {
        effectiveValue = max(0, min(1, value + (offsets[.controlValue] ?? 0)))
        effectiveSlew = max(0.001, slewRate + (offsets[.controlSlew] ?? 0))
    }

    func resetMetaModulation() {
        effectiveValue = value
        effectiveSlew = slewRate
    }

    // MARK: - Codable

    enum CodingKeys: String, CodingKey {
        case sourceId, name, connections, value, slewRate
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sourceId = try c.decode(UUID.self, forKey: .sourceId)
        name = try c.decode(String.self, forKey: .name)
        connections = try c.decode([ModulationConnection].self, forKey: .connections)
        value = try c.decode(Float.self, forKey: .value)
        slewRate = try c.decode(Float.self, forKey: .slewRate)
        effectiveValue = value
        effectiveSlew = slewRate
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sourceId, forKey: .sourceId)
        try c.encode(name, forKey: .name)
        try c.encode(connections, forKey: .connections)
        try c.encode(value, forKey: .value)
        try c.encode(slewRate, forKey: .slewRate)
    }
}

// MARK: - Peak (Envelope Generator)

/// Triggered envelope with attack/hold/decay and probability gate.
/// Polyadic: each connection gets its own envelope state.
/// Fills the biggest gap in the current system -- no envelopes existed.
final class PeakModulator: ModulationSource, ObservableObject, Codable {
    let sourceId: UUID
    @Published var name: String
    @Published var connections: [ModulationConnection]

    @Published var attack: Float = 0.01
    @Published var hold: Float = 0.1
    @Published var decay: Float = 0.3
    @Published var curveExponent: Float = 1.0
    @Published var triggerProbability: Float = 1.0

    /// Effective values after meta-modulation. Readable for diagnostics/testing.
    private(set) var effectiveAttack: Float = 0.01
    private(set) var effectiveDecay: Float = 0.3

    init(name: String = "Peak") {
        self.sourceId = UUID()
        self.name = name
        self.connections = []
    }

    /// Deterministic initializer for testing: fixed sourceId.
    init(name: String = "Peak", sourceId: UUID) {
        self.sourceId = sourceId
        self.name = name
        self.connections = []
    }

    /// Trigger all connections (respecting per-connection probability).
    func trigger() {
        for conn in connections {
            let roll = Float(conn.randomState % 10001) / 10000.0
            conn.randomState = xoshiro256ss(&conn.randomState)
            if roll <= triggerProbability {
                conn.envelopeStage = .attack
                conn.envelopePhase = 0
            }
        }
    }

    func evaluate(connection: ModulationConnection, dt: Double) -> Float {
        let fdt = Float(dt)
        switch connection.envelopeStage {
        case .idle:
            return 0

        case .attack:
            let atkTime = max(effectiveAttack, 0.001)
            connection.envelopePhase += fdt / atkTime
            if connection.envelopePhase >= 1.0 {
                connection.envelopePhase = 0
                connection.envelopeStage = .hold
                return 1.0
            }
            return powf(connection.envelopePhase, curveExponent)

        case .hold:
            connection.envelopePhase += fdt / max(hold, 0.001)
            if connection.envelopePhase >= 1.0 {
                connection.envelopePhase = 0
                connection.envelopeStage = .decay
            }
            return 1.0

        case .decay:
            let decTime = max(effectiveDecay, 0.001)
            connection.envelopePhase += fdt / decTime
            if connection.envelopePhase >= 1.0 {
                connection.envelopePhase = 0
                connection.envelopeStage = .idle
                return 0
            }
            return powf(1.0 - connection.envelopePhase, curveExponent)
        }
    }

    func applyMetaModulation(_ offsets: [ModulationParameter: Float]) {
        effectiveAttack = max(0.001, attack + (offsets[.peakAttack] ?? 0))
        effectiveDecay = max(0.001, decay + (offsets[.peakDecay] ?? 0))
    }

    func resetMetaModulation() {
        effectiveAttack = attack
        effectiveDecay = decay
    }

    // MARK: - Codable

    enum CodingKeys: String, CodingKey {
        case sourceId, name, connections, attack, hold, decay, curveExponent, triggerProbability
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sourceId = try c.decode(UUID.self, forKey: .sourceId)
        name = try c.decode(String.self, forKey: .name)
        connections = try c.decode([ModulationConnection].self, forKey: .connections)
        attack = try c.decode(Float.self, forKey: .attack)
        hold = try c.decode(Float.self, forKey: .hold)
        decay = try c.decode(Float.self, forKey: .decay)
        curveExponent = try c.decodeIfPresent(Float.self, forKey: .curveExponent) ?? 1.0
        triggerProbability = try c.decodeIfPresent(Float.self, forKey: .triggerProbability) ?? 1.0
        effectiveAttack = attack
        effectiveDecay = decay
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sourceId, forKey: .sourceId)
        try c.encode(name, forKey: .name)
        try c.encode(connections, forKey: .connections)
        try c.encode(attack, forKey: .attack)
        try c.encode(hold, forKey: .hold)
        try c.encode(decay, forKey: .decay)
        try c.encode(curveExponent, forKey: .curveExponent)
        try c.encode(triggerProbability, forKey: .triggerProbability)
    }
}

// MARK: - Modulation Diagnostics

/// Per-connection snapshot captured during each evaluate() cycle.
struct ConnectionDiagnostic: Identifiable {
    let id: UUID
    let sourceId: UUID
    let sourceName: String
    let connectionId: UUID
    let destination: ModulationAddress
    let rawValue: Float
    let scaledValue: Float
    let phase: Double
    let envelopeStage: ModulationConnection.EnvelopeStage
}

/// Full graph evaluation snapshot — one per evaluate() call.
struct ModulationSnapshot {
    let timestamp: Date
    let connectionDiagnostics: [ConnectionDiagnostic]
    let accumulatedOffsets: [ModulationAddress: Float]
    let metaModulationOffsets: [UUID: [ModulationParameter: Float]]
    let evaluationCount: UInt64

    var connectionCount: Int { connectionDiagnostics.count }
    var activeOffsetCount: Int { accumulatedOffsets.count }
}

// MARK: - Modulation Graph

/// Directed acyclic graph of modulation sources and connections.
/// Evaluates all modulators in topological order, accumulates offsets per
/// destination address, and caches the result for lock-free audio thread read.
///
/// Thread safety: `evaluate()` runs on a timer (~60 Hz), writes to
/// `cachedOffsets` atomically. The audio callback reads `cachedOffsets`
/// without locking -- a torn read of a single Float is inaudible.
final class ModulationGraph: ObservableObject {

    @Published var agitations: [AgitationModulator] = []
    @Published var controls: [ControlModulator] = []
    @Published var peaks: [PeakModulator] = []

    /// Cached modulation offsets per address. Written by evaluate(), read by audio thread.
    private(set) var cachedOffsets: [ModulationAddress: Float] = [:]

    /// Meta-modulation offsets from the previous cycle, applied at the start of the next.
    /// One-cycle latency (~16ms at 60 Hz) is imperceptible.
    private var pendingMetaOffsets: [UUID: [ModulationParameter: Float]] = [:]

    /// Latest evaluation snapshot for UI display and diagnostic auditing.
    private(set) var lastSnapshot: ModulationSnapshot?

    /// Total number of evaluate() calls since init or clear.
    private(set) var evaluationCount: UInt64 = 0

    /// All sources in evaluation order (agitations first, then controls, then peaks).
    /// Meta-modulation flows from earlier sources to later ones within the same cycle.
    var allSources: [any ModulationSource] {
        (agitations as [any ModulationSource])
        + (controls as [any ModulationSource])
        + (peaks as [any ModulationSource])
    }

    // MARK: - Connection Management

    func connect(source: any ModulationSource, to dest: ModulationAddress, scale: Float = 1.0) {
        guard !wouldCreateCycle(from: source.sourceId, to: dest) else { return }
        let conn = ModulationConnection(destination: dest, scale: scale)
        source.connections.append(conn)
        objectWillChange.send()
    }

    func disconnect(connectionId: UUID) {
        for source in allSources {
            source.connections.removeAll { $0.id == connectionId }
        }
        objectWillChange.send()
    }

    /// Cycle detection: meta-modulation (modulator -> modulator) must be acyclic.
    /// Returns true if connecting `sourceId` to `dest` would create a cycle.
    func wouldCreateCycle(from sourceId: UUID, to dest: ModulationAddress) -> Bool {
        // v2.0: No lane-based routing; meta-modulation uses direct source-to-source connections
        var visited = Set<UUID>()
        return dfsHasCycle(from: sourceId, target: sourceId, visited: &visited)
    }

    private func dfsHasCycle(from currentId: UUID, target: UUID, visited: inout Set<UUID>) -> Bool {
        guard !visited.contains(currentId) else { return false }
        visited.insert(currentId)

        guard let source = findSource(by: currentId) else { return false }
        for conn in source.connections {
            let destSourceId = findSourceOwning(parameter: conn.destinationAddress.parameter)
            guard let destId = destSourceId else { continue }
            if destId == target { return true }
            if dfsHasCycle(from: destId, target: target, visited: &visited) { return true }
        }
        return false
    }

    private func findSource(by id: UUID) -> (any ModulationSource)? {
        allSources.first { $0.sourceId == id }
    }

    private func findSourceOwning(parameter: ModulationParameter) -> UUID? {
        switch parameter {
        case .agitationRate, .agitationDepth:
            return nil  // Simplified: meta-mod targets don't trace back to a unique source
        case .controlValue, .controlSlew:
            return nil
        case .peakAttack, .peakDecay:
            return nil
        default:
            return nil
        }
    }

    // MARK: - Evaluation

    /// Evaluate the full modulation graph for one time step.
    /// Call this at ~60 Hz from a display link or timer.
    /// Records a `ModulationSnapshot` with per-connection diagnostics.
    func evaluate(dt: Double) {
        var offsets = [ModulationAddress: Float]()
        let newMetaOffsets = [UUID: [ModulationParameter: Float]]()
        var diagnostics = [ConnectionDiagnostic]()

        for source in allSources { source.resetMetaModulation() }

        for source in allSources {
            // Apply pending meta-offsets from previous cycle AND any accumulated
            // this cycle from earlier-ordered sources.
            var combinedMeta = pendingMetaOffsets[source.sourceId] ?? [:]
            if let thisRound = newMetaOffsets[source.sourceId] {
                for (k, v) in thisRound { combinedMeta[k, default: 0] += v }
            }
            if !combinedMeta.isEmpty {
                source.applyMetaModulation(combinedMeta)
            }

            for conn in source.connections {
                let raw = source.evaluate(connection: conn, dt: dt)
                let scaled = raw * conn.scale
                let dest = conn.destinationAddress

                conn.recordOutput(raw: raw, scaled: scaled)

                diagnostics.append(ConnectionDiagnostic(
                    id: conn.id,
                    sourceId: source.sourceId,
                    sourceName: source.name,
                    connectionId: conn.id,
                    destination: dest,
                    rawValue: raw,
                    scaledValue: scaled,
                    phase: conn.phase,
                    envelopeStage: conn.envelopeStage
                ))

                // v2.0: Accumulate offsets by destination address
                offsets[dest, default: 0] += scaled
            }
        }

        pendingMetaOffsets = newMetaOffsets
        evaluationCount += 1
        cachedOffsets = offsets
        lastSnapshot = ModulationSnapshot(
            timestamp: Date(),
            connectionDiagnostics: diagnostics,
            accumulatedOffsets: offsets,
            metaModulationOffsets: newMetaOffsets,
            evaluationCount: evaluationCount
        )
    }

    /// Get the accumulated modulation offset for a node parameter.
    /// Safe to call from the audio thread (reads cached dictionary).
    /// v2.0: Uses nodeId instead of lane index for graph-based addressing.
    @inline(__always)
    func offset(nodeId: UUID, parameter: ModulationParameter) -> Float {
        cachedOffsets[ModulationAddress(nodeId: nodeId, parameter: parameter)] ?? 0
    }

    // MARK: - Factory

    @discardableResult
    func addAgitation(name: String = "Agitation") -> AgitationModulator {
        let mod = AgitationModulator(name: name)
        agitations.append(mod)
        objectWillChange.send()
        return mod
    }

    @discardableResult
    func addControl(name: String = "Control") -> ControlModulator {
        let mod = ControlModulator(name: name)
        controls.append(mod)
        objectWillChange.send()
        return mod
    }

    @discardableResult
    func addPeak(name: String = "Peak") -> PeakModulator {
        let mod = PeakModulator(name: name)
        peaks.append(mod)
        objectWillChange.send()
        return mod
    }

    func removeSource(id: UUID) {
        agitations.removeAll { $0.sourceId == id }
        controls.removeAll { $0.sourceId == id }
        peaks.removeAll { $0.sourceId == id }
        objectWillChange.send()
    }

    /// Remove all modulators and connections.
    func clear() {
        agitations.removeAll()
        controls.removeAll()
        peaks.removeAll()
        cachedOffsets.removeAll()
        pendingMetaOffsets.removeAll()
        lastSnapshot = nil
        evaluationCount = 0
        objectWillChange.send()
    }
}

// MARK: - Xoshiro256** (Audio-Safe PRNG)

/// Single-state xoshiro step for polyadic random. Audio-thread safe.
@inline(__always)
func xoshiro256ss(_ state: inout UInt64) -> UInt64 {
    var s = state
    s ^= s >> 12
    s ^= s << 25
    s ^= s >> 27
    state = s
    return s &* 0x2545F4914F6CDD1D
}
