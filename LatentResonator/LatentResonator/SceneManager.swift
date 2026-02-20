import Foundation
import Combine

/// Manages scene bank and scene operations: apply, capture, crossfade.
/// Extracted from NeuralEngine to reduce its size and separate concerns.
///
/// Caller (NeuralEngine) must invoke `updateFeedbackRouting()` after
/// `applyScene` and `updateLaneMixerState()` after `applyScene` / `applyCrossfader`.
final class SceneManager: ObservableObject {
    @Published var sceneBank: SceneBank = SceneBank()

    // MARK: - Scene Application

    /// Apply scene at index to lanes. Caller must call `updateFeedbackRouting()`
    /// and `updateLaneMixerState()` after this.
    func applyScene(at index: Int, lanes: [ResonatorLane]) {
        guard index >= 0, index < sceneBank.scenes.count else { return }
        let scene = sceneBank.scenes[index]
        for (i, lane) in lanes.enumerated() where i < scene.laneSnapshots.count {
            lane.applySnapshot(scene.laneSnapshots[i])
            if let srcIdx = scene.laneSnapshots[i].feedbackSourceLaneIndex,
               srcIdx >= 0, srcIdx < lanes.count {
                lane.feedbackSourceLaneId = lanes[srcIdx].id
            } else {
                lane.feedbackSourceLaneId = nil
            }
        }
        sceneBank.currentSceneIndex = index
    }

    // MARK: - Crossfade Blend

    /// Blend two lane snapshots for crossfader position t (0 = start, 1 = end).
    func blendLaneSnapshot(start: LaneSnapshot, end: LaneSnapshot, t: Float) -> LaneSnapshot {
        func lerp(_ a: Float, _ b: Float) -> Float { a + (b - a) * t }
        return LaneSnapshot(
            volume: lerp(start.volume, end.volume),
            isMuted: t < 0.5 ? start.isMuted : end.isMuted,
            isSoloed: t < 0.5 ? start.isSoloed : end.isSoloed,
            texture: lerp(start.texture, end.texture),
            chaos: lerp(start.chaos, end.chaos),
            warmth: lerp(start.warmth, end.warmth),
            guidanceScale: lerp(start.guidanceScale, end.guidanceScale),
            feedbackAmount: lerp(start.feedbackAmount, end.feedbackAmount),
            inputStrength: lerp(start.inputStrength, end.inputStrength),
            promptPhaseIndex: t < 0.5 ? start.promptPhaseIndex : end.promptPhaseIndex,
            excitationModeRaw: t < 0.5 ? start.excitationModeRaw : end.excitationModeRaw,
            entropyLevel: lerp(start.entropyLevel, end.entropyLevel),
            granularity: lerp(start.granularity, end.granularity),
            delayTime: lerp(start.delayTime, end.delayTime),
            delayFeedback: lerp(start.delayFeedback, end.delayFeedback),
            delayMix: lerp(start.delayMix, end.delayMix),
            bitCrushDepth: lerp(start.bitCrushDepth, end.bitCrushDepth),
            resonatorNote: lerp(start.resonatorNote, end.resonatorNote),
            resonatorDecay: lerp(start.resonatorDecay, end.resonatorDecay),
            filterCutoff: lerp(start.filterCutoff, end.filterCutoff),
            filterResonance: lerp(start.filterResonance, end.filterResonance),
            filterModeRaw: t < 0.5 ? start.filterModeRaw : end.filterModeRaw,
            saturationModeRaw: t < 0.5 ? start.saturationModeRaw : end.saturationModeRaw,
            spectralFreezeActive: t < 0.5 ? start.spectralFreezeActive : end.spectralFreezeActive,
            denoiseStrength: lerp(start.denoiseStrength ?? 1.0, end.denoiseStrength ?? 1.0),
            autoDecayEnabled: t < 0.5 ? start.autoDecayEnabled : end.autoDecayEnabled,
            feedbackSourceLaneIndex: t < 0.5 ? start.feedbackSourceLaneIndex : end.feedbackSourceLaneIndex,
            archiveRecallIndex: t < 0.5 ? start.archiveRecallIndex : end.archiveRecallIndex,
            saturationMorph: lerp(start.saturationMorph ?? 0.0, end.saturationMorph ?? 0.0)
        )
    }

    /// Apply crossfader blend between scene A and B. Caller must call `updateLaneMixerState()` after.
    func applyCrossfader(sceneAIndex a: Int, sceneBIndex b: Int, t: Float, lanes: [ResonatorLane]) {
        guard a >= 0, a < sceneBank.scenes.count, b >= 0, b < sceneBank.scenes.count else { return }
        let clampedT = min(max(t, 0), 1)
        let sceneA = sceneBank.scenes[a]
        let sceneB = sceneBank.scenes[b]
        for (i, lane) in lanes.enumerated() {
            let startSnap = i < sceneA.laneSnapshots.count ? sceneA.laneSnapshots[i] : lane.makeSnapshot()
            let endSnap = i < sceneB.laneSnapshots.count ? sceneB.laneSnapshots[i] : startSnap
            lane.applySnapshot(blendLaneSnapshot(start: startSnap, end: endSnap, t: clampedT))
        }
    }

    // MARK: - Capture

    /// Capture current lane state into scene at index.
    func captureCurrentToScene(at index: Int, lanes: [ResonatorLane]) {
        guard index >= 0 else { return }
        var snapshots: [LaneSnapshot] = []
        for lane in lanes {
            var snap = lane.makeSnapshot()
            if let srcId = lane.feedbackSourceLaneId,
               let srcIdx = lanes.firstIndex(where: { $0.id == srcId }) {
                snap.feedbackSourceLaneIndex = srcIdx
            }
            snapshots.append(snap)
        }
        while sceneBank.scenes.count <= index {
            sceneBank.scenes.append(PerformanceScene(name: "Scene \(sceneBank.scenes.count + 1)", laneSnapshots: []))
        }
        let existingName = index < sceneBank.scenes.count ? sceneBank.scenes[index].name : "Scene \(index + 1)"
        sceneBank.scenes[index] = PerformanceScene(name: existingName, laneSnapshots: snapshots)
        sceneBank.currentSceneIndex = index
    }

    /// When entering Perform from Setup, sync current lane state into Scene A and B if empty.
    func syncSetupToScenesOnEnterPerform(sceneAIndex a: Int, sceneBIndex b: Int, lanes: [ResonatorLane]) {
        guard a >= 0, a < sceneBank.scenes.count, b >= 0, b < sceneBank.scenes.count else { return }
        let sceneA = sceneBank.scenes[a]
        let sceneB = sceneBank.scenes[b]
        let aIsEmpty = sceneA.laneSnapshots.isEmpty
        let bIsEmpty = sceneB.laneSnapshots.isEmpty
        guard aIsEmpty || bIsEmpty else { return }
        if aIsEmpty { captureCurrentToScene(at: a, lanes: lanes) }
        if bIsEmpty { captureCurrentToScene(at: b, lanes: lanes) }
    }

    // MARK: - Lane Count Sync

    /// Append a fresh lane snapshot to all scenes (e.g. when adding a lane).
    func appendLaneSnapshotToAllScenes(_ snapshot: LaneSnapshot) {
        for i in sceneBank.scenes.indices {
            sceneBank.scenes[i].laneSnapshots.append(snapshot)
        }
    }

    /// Remove lane snapshot at index from all scenes and adjust feedbackSourceLaneIndex.
    func removeLaneSnapshotFromAllScenes(at index: Int) {
        for i in sceneBank.scenes.indices {
            if index < sceneBank.scenes[i].laneSnapshots.count {
                sceneBank.scenes[i].laneSnapshots.remove(at: index)
            }
            for j in sceneBank.scenes[i].laneSnapshots.indices {
                var snap = sceneBank.scenes[i].laneSnapshots[j]
                if let src = snap.feedbackSourceLaneIndex {
                    if src == index {
                        snap.feedbackSourceLaneIndex = nil
                    } else if src > index {
                        snap.feedbackSourceLaneIndex = src - 1
                    }
                    sceneBank.scenes[i].laneSnapshots[j] = snap
                }
            }
        }
    }
}
