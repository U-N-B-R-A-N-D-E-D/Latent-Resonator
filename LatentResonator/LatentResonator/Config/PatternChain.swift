import Foundation

// MARK: - Pattern Chain (Whitepaper v2 — Composition Layer §5.3)
//
// Pattern Chain provides song-level arrangement of Scenes.
// A chain is a sequence of steps, each specifying:
//   - Which scene to play
//   - How long to crossfade into it (in bars)
//   - How long to hold it (in bars)
//
// This enables compositional structures: intro → verse → break → drop → outro.
// The chain plays automatically during transport, looping when complete.
//
// PatternChain sits atop SceneManager — it triggers scene blends at the
// macro scale while reusing all existing per-scene parameter logic.
//
// Example chain (4-bar measures at 120 BPM):
//   [Scene A | cross 4 bars | hold 16 bars]  // 20 bars total
//   [Scene B | cross 2 bars | hold 8 bars]   // 10 bars total
//   [Scene A | cross 8 bars | hold 32 bars]  // 40 bars total

// MARK: - Pattern Chain Step

/// One step in a Pattern Chain — a scene with transition and hold durations.
struct PatternChainStep: Codable, Equatable, Identifiable {
    let id: UUID
    var sceneID: UUID          // Which scene to activate
    var crossfadeBars: Int     // Duration of the crossfade (in bars)
    var holdBars: Int          // Duration to hold the scene after crossfade (in bars)

    init(
        id: UUID = UUID(),
        sceneID: UUID,
        crossfadeBars: Int = 2,
        holdBars: Int = 8
    ) {
        self.id = id
        self.sceneID = sceneID
        self.crossfadeBars = max(1, crossfadeBars)
        self.holdBars = max(1, holdBars)
    }

    /// Total duration of this step (crossfade + hold).
    var totalBars: Int { crossfadeBars + holdBars }

    /// Human-readable description for UI.
    var description: String {
        "Scene for \(totalBars) bars (cross: \(crossfadeBars), hold: \(holdBars))"
    }
}

// MARK: - Pattern Chain

/// A sequence of steps forming a complete arrangement.
struct PatternChain: Codable, Equatable {
    var id: UUID
    var name: String
    var steps: [PatternChainStep]
    var isLooping: Bool        // Whether to loop back to step 0 after completion
    var bpm: Int              // BPM for time calculations (independent of global BPM)

    init(
        id: UUID = UUID(),
        name: String = "Untitled Chain",
        steps: [PatternChainStep] = [],
        isLooping: Bool = true,
        bpm: Int = LRConstants.stepTimeBPMDefault
    ) {
        self.id = id
        self.name = name
        self.steps = steps
        self.isLooping = isLooping
        self.bpm = max(30, min(300, bpm))
    }

    /// Total duration of the chain in bars.
    var totalBars: Int {
        steps.reduce(0) { $0 + $1.totalBars }
    }

    /// Estimated duration in seconds at current BPM.
    func durationSeconds() -> Double {
        let bars = Double(totalBars)
        let beatsPerBar = 4.0
        let secondsPerBeat = 60.0 / Double(bpm)
        return bars * beatsPerBar * secondsPerBeat
    }

    /// Human-readable duration string.
    var durationDescription: String {
        let seconds = durationSeconds()
        let minutes = Int(seconds) / 60
        let secs = Int(seconds) % 60
        if minutes > 0 {
            return "\(minutes)m \(secs)s"
        } else {
            return "\(secs)s"
        }
    }
}

// MARK: - Pattern Chain Player State

/// Runtime state of a playing Pattern Chain.
enum PatternChainPlayerState: Equatable {
    case stopped
    case playing(stepIndex: Int, stepProgress: Double, crossfadeProgress: Double)
    case paused(stepIndex: Int)
}

// MARK: - Pattern Chain Player

/// Real-time player for Pattern Chain — advances through steps, triggers scene changes.
///
/// Integration with SceneManager:
///   - On crossfade start: calls sceneManager.beginCrossfade(to:sceneB, duration:)
///   - On crossfade end: sceneManager completes the blend automatically
///   - On hold phase: no action (scene holds steady)
///
/// Thread safety: All public methods must be called on the main thread.
/// The audio thread is not involved — this is UI/transport-level timing.
@MainActor
final class PatternChainPlayer: ObservableObject {

    // MARK: - Published State

    @Published private(set) var state: PatternChainPlayerState = .stopped
    @Published private(set) var currentChain: PatternChain? = nil

    // MARK: - Dependencies

    private weak var sceneManager: SceneManager?

    // MARK: - Private State

    private var displayLink: CADisplayLink? = nil
    private var currentStepIndex: Int = 0
    private var stepStartTime: TimeInterval = 0
    private var crossfadeDuration: TimeInterval = 0
    private var holdDuration: TimeInterval = 0
    private var isInCrossfade: Bool = false

    // MARK: - Init

    init(sceneManager: SceneManager? = nil) {
        self.sceneManager = sceneManager
    }

    // MARK: - Transport Control

    /// Start playing a chain from the beginning.
    func play(chain: PatternChain) {
        stop()
        guard !chain.steps.isEmpty else { return }

        currentChain = chain
        currentStepIndex = 0
        _enterStep(at: 0)

        // Start display link for UI updates (60fps)
        displayLink = CADisplayLink(target: self, selector: #selector(_tick))
        displayLink?.add(to: .main, forMode: .common)

        state = .playing(stepIndex: 0, stepProgress: 0, crossfadeProgress: 0)
    }

    /// Stop playback and reset to beginning.
    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        state = .stopped
        currentStepIndex = 0
        isInCrossfade = false
    }

    /// Pause at current position.
    func pause() {
        displayLink?.invalidate()
        displayLink = nil
        state = .paused(stepIndex: currentStepIndex)
    }

    /// Resume from paused state.
    func resume() {
        if case .paused(let index) = state {
            state = .playing(stepIndex: index, stepProgress: 0, crossfadeProgress: 0)
            displayLink = CADisplayLink(target: self, selector: #selector(_tick))
            displayLink?.add(to: .main, forMode: .common)
        }
    }

    /// Jump to a specific step in the chain.
    func jumpToStep(index: Int) {
        guard let chain = currentChain, index >= 0, index < chain.steps.count else { return }
        currentStepIndex = index
        _enterStep(at: index)
        state = .playing(stepIndex: index, stepProgress: 0, crossfadeProgress: 0)
    }

    // MARK: - Private Step Logic

    private func _enterStep(at index: Int) {
        guard let chain = currentChain, index < chain.steps.count else { return }
        let step = chain.steps[index]

        // Calculate durations based on BPM
        let secondsPerBar = _secondsPerBar(bpm: chain.bpm)
        crossfadeDuration = Double(step.crossfadeBars) * secondsPerBar
        holdDuration = Double(step.holdBars) * secondsPerBar
        stepStartTime = CACurrentMediaTime()
        isInCrossfade = true

        // Trigger the scene change via SceneManager
        sceneManager?.beginCrossfadeToScene(id: step.sceneID, duration: crossfadeDuration)
    }

    private func _secondsPerBar(bpm: Int) -> Double {
        let beatsPerBar = 4.0
        let secondsPerBeat = 60.0 / Double(bpm)
        return beatsPerBar * secondsPerBeat
    }

    @objc private func _tick() {
        guard case .playing(_, _, _) = state,
              let chain = currentChain,
              currentStepIndex < chain.steps.count else { return }

        let now = CACurrentMediaTime()
        let elapsed = now - stepStartTime
        let step = chain.steps[currentStepIndex]
        let stepDuration = crossfadeDuration + holdDuration

        // Calculate progress
        let stepProgress = min(1.0, elapsed / stepDuration)
        let crossfadeProgress: Double

        if isInCrossfade {
            if elapsed >= crossfadeDuration {
                // Crossfade complete, enter hold phase
                isInCrossfade = false
                crossfadeProgress = 1.0
            } else {
                crossfadeProgress = elapsed / crossfadeDuration
            }
        } else {
            crossfadeProgress = 1.0
        }

        // Update state
        state = .playing(
            stepIndex: currentStepIndex,
            stepProgress: stepProgress,
            crossfadeProgress: crossfadeProgress
        )

        // Check for step completion
        if stepProgress >= 1.0 {
            _advanceToNextStep()
        }
    }

    private func _advanceToNextStep() {
        guard let chain = currentChain else { return }

        let nextIndex = currentStepIndex + 1
        if nextIndex < chain.steps.count {
            // More steps in chain
            currentStepIndex = nextIndex
            _enterStep(at: nextIndex)
        } else if chain.isLooping {
            // Loop back to beginning
            currentStepIndex = 0
            _enterStep(at: 0)
        } else {
            // Chain complete
            stop()
        }
    }
}

// MARK: - Pattern Chain Store

/// Persistence for user-authored Pattern Chains.
enum PatternChainStore {

    private static let directoryName = "PatternChains"
    private static let fileExtension = "chain"

    private static var storeDirectory: URL {
        if let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first {
            return appSupport.appendingPathComponent("LatentResonator/\(directoryName)", isDirectory: true)
        }
        return URL(fileURLWithPath: "/tmp/LatentResonator/\(directoryName)", isDirectory: true)
    }

    /// Save a chain to disk.
    static func save(_ chain: PatternChain) throws {
        let dir = storeDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let fileURL = dir.appendingPathComponent("\(chain.id.uuidString).\(fileExtension)")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(chain)
        try data.write(to: fileURL, options: .atomic)
    }

    /// Load all saved chains.
    static func loadAll() -> [PatternChain] {
        let dir = storeDirectory
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }

        do {
            let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            return files
                .filter { $0.pathExtension == fileExtension }
                .compactMap { url -> PatternChain? in
                    guard let data = try? Data(contentsOf: url) else { return nil }
                    return try? JSONDecoder().decode(PatternChain.self, from: data)
                }
                .sorted { $0.name < $1.name }
        } catch {
            print("PatternChainStore: Failed to load chains -- \(error)")
            return []
        }
    }

    /// Delete a chain.
    static func delete(_ chain: PatternChain) {
        let fileURL = storeDirectory.appendingPathComponent("\(chain.id.uuidString).\(fileExtension)")
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Factory preset chains shipped with the app.
    static let factoryChains: [PatternChain] = [
        // Simple A → B → A structure
        PatternChain(
            name: "AB Form",
            steps: [
                PatternChainStep(sceneID: UUID(), crossfadeBars: 2, holdBars: 16),
                PatternChainStep(sceneID: UUID(), crossfadeBars: 2, holdBars: 16),
                PatternChainStep(sceneID: UUID(), crossfadeBars: 4, holdBars: 32),
            ]
        ),
        // Build-up structure
        PatternChain(
            name: "Build & Release",
            steps: [
                PatternChainStep(sceneID: UUID(), crossfadeBars: 1, holdBars: 8),
                PatternChainStep(sceneID: UUID(), crossfadeBars: 2, holdBars: 8),
                PatternChainStep(sceneID: UUID(), crossfadeBars: 4, holdBars: 16),
                PatternChainStep(sceneID: UUID(), crossfadeBars: 2, holdBars: 8),
            ]
        ),
    ]
}

// MARK: - Integration with PerformanceState

extension PerformanceStateSnapshot {

    /// Encode Pattern Chain data into the state snapshot.
    /// Uses a special key in a parallel structure to avoid breaking v1.x decoding.
    var patternChainData: PatternChain? {
        get {
            // Accessed via dedicated store, not main state
            nil
        }
        set {
            // Stored separately via PatternChainStore
        }
    }
}

// MARK: - SceneManager Extension for Pattern Chain

extension SceneManager {

    /// Begin a crossfade to a scene by its UUID.
    /// Called by PatternChainPlayer during chain playback.
    func beginCrossfadeToScene(id sceneID: UUID, duration: TimeInterval) {
        // Find the scene index from the scene bank
        guard let sceneIndex = bank.scenes.firstIndex(where: { $0.id == sceneID }) else {
            print("SceneManager: Scene \(sceneID) not found in bank")
            return
        }

        // Determine which side of the crossfader to use
        let targetSceneLetter = sceneIndex == sceneASceneIndex ? "A" : "B"

        // Set up the crossfade
        if targetSceneLetter == "A" {
            // Crossfade to A means B → A
            if sceneBSceneIndex != sceneIndex {
                // Load the target scene into the opposite slot first
                loadScene(index: sceneIndex, into: .b)
            }
            beginCrossfade(to: .a, duration: duration)
        } else {
            // Crossfade to B means A → B
            if sceneASceneIndex != sceneIndex {
                loadScene(index: sceneIndex, into: .a)
            }
            beginCrossfade(to: .b, duration: duration)
        }
    }

    private func loadScene(index: Int, into slot: SceneSlot) {
        // Helper to load a scene into the specified slot
        switch slot {
        case .a:
            sceneASceneIndex = index
            recallSceneA()
        case .b:
            sceneBSceneIndex = index
            recallSceneB()
        }
    }

    private enum SceneSlot {
        case a, b
    }
}
