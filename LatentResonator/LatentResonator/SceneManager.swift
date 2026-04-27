import Foundation
import Combine

/// Manages scene bank and scene operations: apply, capture, crossfade.
/// Extracted from NeuralEngine to reduce its size and separate concerns.
///
/// v2.0: Scene persistence uses GraphSnapshot (NodeGraph parameters) as source of truth.
/// Scenes capture the entire NodeGraph state and apply/crossfade via NodeGraph.
///
/// v2.0: Audio graph state updates automatically via AudioGraphMapper.
/// No manual routing or mixer updates required after scene operations.
final class SceneManager: ObservableObject {
    @Published var sceneBank: SceneBank = SceneBank()

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
        guard index >= 0, index < sceneBank.scenes.count else { return }
        let scene = sceneBank.scenes[index]

        // Apply graphSnapshots (node parameters)
        for (_, snapshot) in scene.graphSnapshots {
            for (key, value) in snapshot.parameters {
                nodeGraph.setParameter(nodeId: snapshot.nodeId, key: key, value: value)
            }
        }

        sceneBank.currentSceneIndex = index
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
        for i in sceneBank.scenes.indices {
            sceneBank.scenes[i].graphSnapshots = [:]
        }
    }
}
