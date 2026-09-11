import Foundation
import Combine

/// Manages scene bank and scene operations: apply, capture, crossfade.
/// Extracted from NeuralEngine to reduce its size and separate concerns.
///
/// v2.0: Scene persistence uses GraphSnapshot (NodeGraph parameters) as source of truth.
/// Scenes capture the entire NodeGraph state and apply/crossfade via NodeGraph.
///
/// v2.0.1 (Musician P0.2): `applyScene(at:to:)` now performs a short main-thread
/// parameter ramp (default `crossfadeDuration`, falling back to ~100 ms when 0/unset)
/// instead of a hard jump, eliminating recall clicks/pops. The audio thread is
/// untouched — `setParameter` is still main-thread; the ramp only schedules
/// interpolated main-thread writes. Callers may opt out via
/// `applyScene(at:to:crossfade: false)`.
///
/// v2.0: Audio graph state updates automatically via AudioGraphMapper.
/// No manual routing or mixer updates required after scene operations.
final class SceneManager: ObservableObject {
    @Published var sceneBank: SceneBank = SceneBank()

    // MARK: - Crossfade Ramp State (Musician P0.2)

    /// One in-flight parameter ramp target.
    struct RampTask {
        let nodeId: UUID
        let key: String
        let startValue: Float
        let endValue: Float
    }

    /// Opaque handle returned by a ramp scheduler; cancelling it stops the
    /// driving timer. The default scheduler returns a `Timer`-backed handle;
    /// tests inject a no-op handle and drive `_advanceRamp(now:)` manually.
    final class RampHandle {
        let cancel: () -> Void
        init(cancel: @escaping () -> Void) { self.cancel = cancel }
    }

    /// Default ramp duration used when `sceneBank.crossfadeDuration` is 0/unset.
    /// ~100 ms is enough to suppress recall clicks without feeling sluggish.
    static let defaultRampDuration: TimeInterval = 0.100

    /// Tick interval for the production ramp timer (~120 Hz). Main-thread only.
    private static let rampTickInterval: TimeInterval = 1.0 / 120.0

    /// Active ramp tasks. Cleared when the ramp completes or is cancelled.
    /// Exposed internally for deterministic crossfade tests.
    var rampTasks: [RampTask] = []
    var rampStartTime: Date = .distantPast
    fileprivate var rampDuration: TimeInterval = 0

    /// Currently active ramp driver. Replacing a scene mid-ramp cancels this.
    fileprivate var rampHandle: RampHandle?

    /// Injectable scheduler so tests can drive the ramp deterministically
    /// without a real `Timer`. Production uses `makeTimerRamp`.
    /// Signature: `(start, duration, tick) -> RampHandle` where `tick(now)`
    /// is called repeatedly until the handle is cancelled.
    var rampScheduler: (Date, TimeInterval, @escaping (Date) -> Void) -> RampHandle = SceneManager.makeTimerRamp

    /// Optional filter: returns true when the parameter (nodeId, key) is
    /// currently locked by the active step and should be skipped by scene
    /// apply/crossfade so it holds its current value.
    var lockedParameterFilter: ((UUID, String) -> Bool)?

    private func isLocked(nodeId: UUID, key: String) -> Bool {
        lockedParameterFilter?(nodeId, key) ?? false
    }

    // MARK: - Graph-Based Scene Operations (v2.0)

    /// Apply scene at index to NodeGraph.
    ///
    /// Reads graphSnapshots from the scene and applies them to the NodeGraph.
    /// Lanes automatically reflect changes via their computed properties and RT snapshots.
    ///
    /// - Parameters:
    ///   - index: Scene index in sceneBank
    ///   - nodeGraph: The NodeGraph to apply parameters to
    func applyScene(at index: Int, to nodeGraph: NodeGraph) {
        // Default behavior is crossfade ON so existing callers (scene buttons,
        // 1-8 hotkeys) get the click fix without touching their files.
        applyScene(at: index, to: nodeGraph, crossfade: true)
    }

    /// Apply scene at index to NodeGraph, optionally ramping parameters to
    /// suppress recall clicks.
    ///
    /// - Parameter crossfade: When `true` (default), parameters ramp linearly
    ///   from their current value to the scene's target value over
    ///   `sceneBank.crossfadeDuration` seconds (falling back to
    ///   `defaultRampDuration` when that field is 0/unset). When `false`,
    ///   parameters jump immediately (legacy behavior).
    func applyScene(at index: Int, to nodeGraph: NodeGraph, crossfade: Bool) {
        guard index >= 0, index < sceneBank.scenes.count else { return }
        let scene = sceneBank.scenes[index]

        // Cancel any in-flight ramp before issuing a new one — overlapping
        // ramps would fight over the same parameters.
        cancelRamp()

        // Resolve ramp duration. `crossfadeDuration` is the crossfader field
        // (seconds); when 0/unset we fall back to the ~100 ms anti-click default.
        let duration = sceneBank.crossfadeDuration > 0
            ? sceneBank.crossfadeDuration
            : Self.defaultRampDuration

        if !crossfade || duration <= 0 {
            // Legacy hard-jump path.
            applySceneImmediate(scene, to: nodeGraph)
        } else {
            // Build ramp tasks from current value -> target value for every
            // parameter present in the scene's graphSnapshots.
            var tasks: [RampTask] = []
            for (_, snapshot) in scene.graphSnapshots {
                for (key, endValue) in snapshot.parameters {
                    // Locked parameters keep their current value through the
                    // whole morph — do not include them in the ramp.
                    guard !isLocked(nodeId: snapshot.nodeId, key: key) else { continue }
                    let startValue = currentParameterValue(
                        nodeId: snapshot.nodeId, key: key, in: nodeGraph
                    ) ?? endValue
                    // Skip no-op ramps to keep the timer work minimal.
                    if startValue == endValue { continue }
                    tasks.append(RampTask(
                        nodeId: snapshot.nodeId,
                        key: key,
                        startValue: startValue,
                        endValue: endValue
                    ))
                }
            }

            if tasks.isEmpty {
                // Nothing to ramp; just bump the index.
                sceneBank.currentSceneIndex = index
                return
            }

            rampTasks = tasks
            rampStartTime = Date()
            rampDuration = duration
            sceneBank.currentSceneIndex = index

            // Drive the ramp via the (injectable) scheduler. Each tick calls
            // `_advanceRamp(now:)`, which performs the main-thread
            // `setParameter` writes.
            rampHandle = rampScheduler(rampStartTime, duration) { [weak self] now in
                self?._advanceRamp(now: now, nodeGraph: nodeGraph)
            }
        }
    }

    /// Hard-jump application of a scene's parameters. Legacy recall path.
    private func applySceneImmediate(_ scene: PerformanceScene, to nodeGraph: NodeGraph) {
        for (_, snapshot) in scene.graphSnapshots {
            for (key, value) in snapshot.parameters {
                guard !isLocked(nodeId: snapshot.nodeId, key: key) else { continue }
                nodeGraph.setParameter(nodeId: snapshot.nodeId, key: key, value: value)
            }
        }
        if let idx = sceneBank.scenes.firstIndex(where: { $0.id == scene.id }) {
            sceneBank.currentSceneIndex = idx
        }
    }

    /// Reads the current Float value of a parameter on a node, if present.
    private func currentParameterValue(nodeId: UUID, key: String, in nodeGraph: NodeGraph) -> Float? {
        guard let node = nodeGraph.nodes[nodeId] else { return nil }
        return node.parameters[key] as? Float
    }

    /// Advances the active ramp to `now`, writing interpolated parameter
    /// values via `setParameter` (main-thread). Finalizes (cancels) the ramp
    /// once `now` passes `rampStartTime + rampDuration`.
    ///
    /// Internal for testability — tests inject a no-op `rampScheduler` and
    /// call this directly with simulated timestamps.
    func _advanceRamp(now: Date, nodeGraph: NodeGraph) {
        guard !rampTasks.isEmpty else { return }
        let elapsed = now.timeIntervalSince(rampStartTime)
        // Clamp t to [0, 1].
        let t = rampDuration > 0
            ? min(max(elapsed / rampDuration, 0), 1)
            : 1

        for task in rampTasks {
            let value = task.startValue + (task.endValue - task.startValue) * Float(t)
            nodeGraph.setParameter(nodeId: task.nodeId, key: task.key, value: value)
        }

        if t >= 1 {
            // Ramp complete — tear down.
            cancelRamp()
        }
    }

    /// Cancels the active ramp (if any) and clears ramp state.
    private func cancelRamp() {
        rampHandle?.cancel()
        rampHandle = nil
        rampTasks = []
        rampStartTime = .distantPast
        rampDuration = 0
    }

    /// Capture current NodeGraph state into a scene.
    ///
    /// Captures all nodes in the NodeGraph into GraphSnapshots.
    ///
    /// - Parameters:
    ///   - index: Scene index to capture to
    ///   - nodeGraph: The NodeGraph containing current parameter states
    func captureScene(at index: Int, from nodeGraph: NodeGraph) {
        guard index >= 0 else { return }

        var snapshots: [UUID: GraphSnapshot] = [:]

        // Capture all nodes in the graph
        for (_, node) in nodeGraph.nodes {
            let snapshot = GraphSnapshot(from: node)
            snapshots[node.id] = snapshot
        }

        // Ensure scene bank has enough slots
        while sceneBank.scenes.count <= index {
            sceneBank.scenes.append(PerformanceScene(name: "Scene \(sceneBank.scenes.count + 1)"))
        }

        let existingName = sceneBank.scenes[index].name
        sceneBank.scenes[index] = PerformanceScene(
            id: sceneBank.scenes[index].id,  // Preserve existing ID
            name: existingName,
            graphSnapshots: snapshots
        )
        sceneBank.currentSceneIndex = index
    }

    /// Crossfade between two scenes by interpolating shared parameters.
    ///
    /// Only morphs parameters present in BOTH scenes.
    /// Orphaned nodes stay at their current values during crossfade.
    ///
    /// - Parameters:
    ///   - t: Crossfade position [0..1], 0 = sceneA, 1 = sceneB
    ///   - sceneAIndex: Source scene index
    ///   - sceneBIndex: Destination scene index
    ///   - nodeGraph: The NodeGraph to apply interpolated parameters to
    func applyCrossfader(t: Float, sceneAIndex: Int, sceneBIndex: Int, to nodeGraph: NodeGraph) {
        guard sceneAIndex >= 0, sceneAIndex < sceneBank.scenes.count,
              sceneBIndex >= 0, sceneBIndex < sceneBank.scenes.count else { return }
        let sceneA = sceneBank.scenes[sceneAIndex]
        let sceneB = sceneBank.scenes[sceneBIndex]

        let clampedT = min(max(t, 0), 1)

        // Find common node IDs (shared nodes between both scenes)
        let commonNodeIds = Set(sceneA.graphSnapshots.keys).intersection(sceneB.graphSnapshots.keys)

        for nodeId in commonNodeIds {
            guard let snapA = sceneA.graphSnapshots[nodeId],
                  let snapB = sceneB.graphSnapshots[nodeId] else { continue }

            // Find common parameters between the two snapshots
            let commonParams = Set(snapA.parameters.keys).intersection(snapB.parameters.keys)

            for paramKey in commonParams {
                // Locked parameters keep their current value during crossfade.
                guard !isLocked(nodeId: nodeId, key: paramKey) else { continue }
                guard let valA = snapA.parameters[paramKey],
                      let valB = snapB.parameters[paramKey] else { continue }

                // Linear interpolation
                let interpolated = valA + (valB - valA) * clampedT
                nodeGraph.setParameter(nodeId: nodeId, key: paramKey, value: interpolated)
            }
        }

        // Note: Orphaned nodes (present in only one scene) stay at their current values
    }

    // MARK: - Scene Bank Operations

    /// Ensures the scene bank has the required capacity, filling with empty scenes.
    func ensureSceneCapacity(_ capacity: Int) {
        while sceneBank.scenes.count < capacity {
            sceneBank.scenes.append(PerformanceScene(name: "Scene \(sceneBank.scenes.count + 1)"))
        }
    }

    /// Clear all scenes to empty state.
    func clearAllScenes() {
        cancelRamp()
        for i in sceneBank.scenes.indices {
            sceneBank.scenes[i].graphSnapshots = [:]
        }
    }

    // MARK: - Ramp Scheduler (production)

    /// Default ramp scheduler: a main-thread `Timer` driving `tick(now:)`
    /// at ~120 Hz until the returned handle is cancelled.
    fileprivate static func makeTimerRamp(
        start: Date,
        duration: TimeInterval,
        tick: @escaping (Date) -> Void
    ) -> RampHandle {
        var timer: Timer?
        let runLoop = RunLoop.main
        timer = Timer(timeInterval: rampTickInterval, repeats: true) { _ in
            tick(Date())
        }
        // `.common` modes so the ramp keeps ticking during modal interactions
        // (e.g. drag/tracking) where the default mode would stall.
        runLoop.add(timer!, forMode: .common)
        return RampHandle { [weak timer] in
            timer?.invalidate()
        }
    }
}
