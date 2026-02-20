import Foundation

// MARK: - Performance State (Motherbase UX)
//
// Data model for Scenes, Step Grid, and parameter locks.
// Whitepaper §4.2.2 -- recursive drift as performable arc; §7 -- CFG at hand.

// MARK: - Lane Snapshot

/// Snapshot of performable parameters for one lane. Used by Scenes and crossfade.
struct LaneSnapshot: Codable, Equatable {
    var volume: Float
    var isMuted: Bool
    var isSoloed: Bool
    var texture: Float
    var chaos: Float
    var warmth: Float
    var guidanceScale: Float
    var feedbackAmount: Float
    var inputStrength: Float
    var promptPhaseIndex: Int       // 1, 2, or 3 (§4.2.2)
    var excitationModeRaw: String   // ExcitationMode.rawValue
    var entropyLevel: Float
    var granularity: Float
    var delayTime: Float
    var delayFeedback: Float
    var delayMix: Float
    var bitCrushDepth: Float
    var resonatorNote: Float
    var resonatorDecay: Float
    var filterCutoff: Float
    var filterResonance: Float
    var filterModeRaw: String       // FilterMode.rawValue
    var saturationModeRaw: String  // SaturationMode.rawValue
    var spectralFreezeActive: Bool
    /// Per-lane denoise default (0-1). Scene recall restores this. Nil when decoding old snapshots -> treated as 1.0.
    var denoiseStrength: Float?
}

// MARK: - Performance Scene (snapshot; name avoids shadowing SwiftUI.Scene)

/// Full snapshot of all lanes' performable parameters. One scene = one recallable state.
struct PerformanceScene: Codable, Equatable {
    var name: String
    var laneSnapshots: [LaneSnapshot]

    init(name: String = "Scene", laneSnapshots: [LaneSnapshot] = []) {
        self.name = name
        self.laneSnapshots = laneSnapshots
    }
}

// MARK: - Scene Bank

/// Bank of 4 or 8 scenes; current index; crossfade duration.
struct SceneBank: Codable {
    var scenes: [PerformanceScene]
    var currentSceneIndex: Int
    var crossfadeDuration: TimeInterval

    static let maxScenes = LRConstants.sceneCount

    init(scenes: [PerformanceScene] = [], currentSceneIndex: Int = 0, crossfadeDuration: TimeInterval = LRConstants.crossfadeDefaultDuration) {
        self.scenes = Array(scenes.prefix(Self.maxScenes))
        self.currentSceneIndex = min(max(0, currentSceneIndex), max(0, Self.maxScenes - 1))
        self.crossfadeDuration = crossfadeDuration
    }

    mutating func ensureCapacity() {
        while scenes.count < Self.maxScenes {
            scenes.append(PerformanceScene(name: "Scene \(scenes.count + 1)", laneSnapshots: []))
        }
    }
}

// MARK: - Trig Type (Sequencer v2)

/// Determines how a step fires during pattern playback.
/// - note: Full inference cycle (default). Red in UI.
/// - lock: Applies P-Locks without triggering inference (trigless). Yellow in UI.
/// - oneShot: Fires once per pattern pass, then skips. Green in UI.
/// - skip: Step is entirely skipped. Dim gray in UI.
enum TrigType: String, Codable, CaseIterable {
    case note
    case lock
    case oneShot
    case skip
}

// MARK: - Performance Step (Parameter Lock)

/// One step in the grid. Holds a trig type, optional probability gate,
/// and up to 13 lockable parameters applied when the step is active.
///
/// Backward compatibility: decodes the legacy `dspOnly: Bool` field
/// (mapping `true` -> `.lock`) so old `performance_state.json` files
/// load without error.
struct PerformanceStep: Equatable {

    // -- Trig identity --
    var trigType: TrigType
    var probability: Float?       // 0..1; nil = always fire (100%)

    // -- Inference locks --
    var cfg: Float?               // locked guidance scale (γ)
    var feedback: Float?          // locked feedback amount
    var promptPhase: Int?         // 1, 2, or 3
    var denoiseStrength: Float?   // 0 = DSP-only, 1 = full ACE; nil = default

    // -- DSP / macro locks --
    var texture: Float?
    var chaos: Float?
    var warmth: Float?
    var filterCutoff: Float?
    var filterResonance: Float?
    var excitationMode: String?   // ExcitationMode.rawValue
    var delayMix: Float?
    var bitCrushDepth: Float?

    /// Per-step microtiming offset in step units (-0.5...0.5).
    /// Negative = early (push), positive = late (drag).
    var microtiming: Double = 0.0

    init(
        trigType: TrigType = .note,
        probability: Float? = nil,
        cfg: Float? = nil,
        feedback: Float? = nil,
        promptPhase: Int? = nil,
        denoiseStrength: Float? = nil,
        texture: Float? = nil,
        chaos: Float? = nil,
        warmth: Float? = nil,
        filterCutoff: Float? = nil,
        filterResonance: Float? = nil,
        excitationMode: String? = nil,
        delayMix: Float? = nil,
        bitCrushDepth: Float? = nil,
        microtiming: Double = 0.0
    ) {
        self.trigType = trigType
        self.probability = probability
        self.cfg = cfg
        self.feedback = feedback
        self.promptPhase = promptPhase
        self.denoiseStrength = denoiseStrength
        self.texture = texture
        self.chaos = chaos
        self.warmth = warmth
        self.filterCutoff = filterCutoff
        self.filterResonance = filterResonance
        self.excitationMode = excitationMode
        self.delayMix = delayMix
        self.bitCrushDepth = bitCrushDepth
        self.microtiming = microtiming
    }

    /// Backward-compat computed getter (used by engine for .lock trig behavior).
    var dspOnly: Bool { trigType == .lock }

    var hasLock: Bool {
        cfg != nil || feedback != nil || promptPhase != nil
        || denoiseStrength != nil || texture != nil || chaos != nil
        || warmth != nil || filterCutoff != nil || filterResonance != nil
        || excitationMode != nil || delayMix != nil || bitCrushDepth != nil
        || trigType == .lock
    }

    /// Number of non-nil parameter locks (for compact UI display).
    var lockCount: Int {
        let optionals: [Any?] = [
            cfg, feedback, promptPhase, denoiseStrength,
            texture, chaos, warmth, filterCutoff, filterResonance,
            excitationMode, delayMix, bitCrushDepth
        ]
        return optionals.compactMap({ $0 }).count
    }
}

// MARK: - PerformanceStep Codable (backward-compatible)

extension PerformanceStep: Codable {

    private enum CodingKeys: String, CodingKey {
        case trigType, probability
        case cfg, feedback, promptPhase, denoiseStrength
        case texture, chaos, warmth, filterCutoff, filterResonance
        case excitationMode, delayMix, bitCrushDepth
        case microtiming
        // Legacy key read during decode only
        case dspOnly
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        // Trig type: prefer new key, fall back to legacy dspOnly
        if let tt = try c.decodeIfPresent(TrigType.self, forKey: .trigType) {
            trigType = tt
        } else if let legacy = try c.decodeIfPresent(Bool.self, forKey: .dspOnly), legacy {
            trigType = .lock
        } else {
            trigType = .note
        }

        probability      = try c.decodeIfPresent(Float.self,  forKey: .probability)
        cfg              = try c.decodeIfPresent(Float.self,  forKey: .cfg)
        feedback         = try c.decodeIfPresent(Float.self,  forKey: .feedback)
        promptPhase      = try c.decodeIfPresent(Int.self,    forKey: .promptPhase)
        denoiseStrength  = try c.decodeIfPresent(Float.self,  forKey: .denoiseStrength)
        texture          = try c.decodeIfPresent(Float.self,  forKey: .texture)
        chaos            = try c.decodeIfPresent(Float.self,  forKey: .chaos)
        warmth           = try c.decodeIfPresent(Float.self,  forKey: .warmth)
        filterCutoff     = try c.decodeIfPresent(Float.self,  forKey: .filterCutoff)
        filterResonance  = try c.decodeIfPresent(Float.self,  forKey: .filterResonance)
        excitationMode   = try c.decodeIfPresent(String.self, forKey: .excitationMode)
        delayMix         = try c.decodeIfPresent(Float.self,  forKey: .delayMix)
        bitCrushDepth    = try c.decodeIfPresent(Float.self,  forKey: .bitCrushDepth)
        microtiming      = try c.decodeIfPresent(Double.self, forKey: .microtiming) ?? 0.0
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)

        try c.encode(trigType, forKey: .trigType)
        try c.encodeIfPresent(probability,     forKey: .probability)
        try c.encodeIfPresent(cfg,             forKey: .cfg)
        try c.encodeIfPresent(feedback,        forKey: .feedback)
        try c.encodeIfPresent(promptPhase,     forKey: .promptPhase)
        try c.encodeIfPresent(denoiseStrength, forKey: .denoiseStrength)
        try c.encodeIfPresent(texture,         forKey: .texture)
        try c.encodeIfPresent(chaos,           forKey: .chaos)
        try c.encodeIfPresent(warmth,          forKey: .warmth)
        try c.encodeIfPresent(filterCutoff,    forKey: .filterCutoff)
        try c.encodeIfPresent(filterResonance, forKey: .filterResonance)
        try c.encodeIfPresent(excitationMode,  forKey: .excitationMode)
        try c.encodeIfPresent(delayMix,        forKey: .delayMix)
        try c.encodeIfPresent(bitCrushDepth,   forKey: .bitCrushDepth)
        if microtiming != 0.0 {
            try c.encode(microtiming, forKey: .microtiming)
        }
        // NOTE: dspOnly is NOT encoded -- trigType replaces it
    }
}

// MARK: - Step Grid

/// Grid of up to 16 performance steps with trig types, probability,
/// chain length, and one-shot tracking.
struct StepGrid: Equatable {
    var steps: [PerformanceStep]
    var currentStepIndex: Int
    var advanceMode: StepAdvanceMode
    var stepAdvanceDivisor: Int     // advance one step every N iterations (when mode == .iteration)
    var chainLength: Int            // active step count (1...maxSteps); pattern loops over this many
    var stepTimeBPM: Int            // BPM for .time advance mode (steps per minute)

    /// Transient: tracks which one-shot steps have already fired in the current pattern pass.
    /// NOT persisted. Cleared when the pattern wraps.
    var oneShotFired: Set<Int> = []

    static let maxSteps = LRConstants.performanceStepCount

    enum StepAdvanceMode: String, Codable, CaseIterable {
        case time = "time"           // timer-based (BPM clock)
        case iteration = "iteration" // global cycle % steps
        case manual = "manual"       // tap only
    }

    init(
        steps: [PerformanceStep] = [],
        currentStepIndex: Int = 0,
        advanceMode: StepAdvanceMode = .iteration,
        stepAdvanceDivisor: Int = LRConstants.stepAdvanceDivisor,
        chainLength: Int = LRConstants.chainLengthDefault,
        stepTimeBPM: Int = LRConstants.stepTimeBPMDefault
    ) {
        var s = steps
        while s.count < Self.maxSteps {
            s.append(PerformanceStep())
        }
        self.steps = Array(s.prefix(Self.maxSteps))
        self.currentStepIndex = min(max(0, currentStepIndex), Self.maxSteps - 1)
        self.advanceMode = advanceMode
        self.stepAdvanceDivisor = max(1, stepAdvanceDivisor)
        self.chainLength = min(max(1, chainLength), Self.maxSteps)
        self.stepTimeBPM = min(max(stepTimeBPM, LRConstants.stepTimeBPMRange.lowerBound),
                               LRConstants.stepTimeBPMRange.upperBound)
    }

    func step(at index: Int) -> PerformanceStep? {
        guard index >= 0, index < steps.count else { return nil }
        return steps[index]
    }

    mutating func setStep(_ step: PerformanceStep, at index: Int) {
        guard index >= 0, index < steps.count else { return }
        steps[index] = step
    }

    /// Active portion of the grid (0..<chainLength).
    var activeSteps: ArraySlice<PerformanceStep> {
        steps[0..<min(chainLength, steps.count)]
    }
}

// MARK: - StepGrid Codable (backward-compatible)

extension StepGrid: Codable {

    private enum CodingKeys: String, CodingKey {
        case steps, currentStepIndex, advanceMode, stepAdvanceDivisor, chainLength, stepTimeBPM
        // oneShotFired is intentionally excluded -- transient state
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decodedSteps = try c.decode([PerformanceStep].self, forKey: .steps)
        let idx   = try c.decode(Int.self, forKey: .currentStepIndex)
        let mode  = try c.decode(StepAdvanceMode.self, forKey: .advanceMode)
        let div   = try c.decode(Int.self, forKey: .stepAdvanceDivisor)
        let chain = try c.decodeIfPresent(Int.self, forKey: .chainLength) ?? decodedSteps.count
        let bpm   = try c.decodeIfPresent(Int.self, forKey: .stepTimeBPM) ?? LRConstants.stepTimeBPMDefault
        self.init(steps: decodedSteps, currentStepIndex: idx, advanceMode: mode,
                  stepAdvanceDivisor: div, chainLength: chain, stepTimeBPM: bpm)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(steps,             forKey: .steps)
        try c.encode(currentStepIndex,  forKey: .currentStepIndex)
        try c.encode(advanceMode,       forKey: .advanceMode)
        try c.encode(stepAdvanceDivisor, forKey: .stepAdvanceDivisor)
        try c.encode(chainLength,       forKey: .chainLength)
        try c.encode(stepTimeBPM,       forKey: .stepTimeBPM)
    }
}


// MARK: - Full Performance State (Persistence Container)

/// Top-level container for all persistable performance data:
/// scene bank + step grid. Saved as JSON to Application Support.
struct PerformanceStateSnapshot: Codable {
    var sceneBank: SceneBank
    var stepGrid: StepGrid
    var crossfaderSceneAIndex: Int
    var crossfaderSceneBIndex: Int
}

// MARK: - Performance State Store

/// Handles JSON serialization of the full performance state to disk.
/// Saves to ~/Library/Application Support/LatentResonator/.
enum PerformanceStateStore {

    private static let fileName = "performance_state.json"

    private static var storeDirectory: URL {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else {
            fatalError("Could not locate Application Support directory")
        }
        return appSupport.appendingPathComponent("LatentResonator", isDirectory: true)
    }

    private static var fileURL: URL {
        storeDirectory.appendingPathComponent(fileName)
    }

    /// Save the current performance state to disk.
    ///
    /// - Parameter state: Snapshot of scenes, step grid, and crossfader config
    /// - Throws: Encoding or file-system errors
    static func save(_ state: PerformanceStateSnapshot) throws {
        let dir = storeDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        try data.write(to: fileURL, options: .atomic)
    }

    /// Load the saved performance state from disk.
    ///
    /// - Returns: The decoded snapshot, or nil if no saved state exists
    static func load() -> PerformanceStateSnapshot? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        do {
            let data = try Data(contentsOf: fileURL)
            return try JSONDecoder().decode(PerformanceStateSnapshot.self, from: data)
        } catch {
            print(">> PerformanceStateStore: Failed to load -- \(error.localizedDescription)")
            return nil
        }
    }

    /// Delete the saved state file.
    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
