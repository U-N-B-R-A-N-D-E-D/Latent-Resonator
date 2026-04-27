import Foundation
import AVFoundation

// MARK: - Implicit Graph Builder

/// Builds a NodeGraph from a v1.x LanePreset.
/// v2.0: Stub implementation - backward compatibility via direct MacroNode creation.
///
/// Note: This file previously contained complex graph construction logic that relied on
/// private NodeGraph APIs. In v2.0, MacroNodes are created directly via NodeFactory
/// rather than through preset conversion. This stub maintains the interface for
/// any legacy code paths while the actual implementation uses the new API.
struct ImplicitGraphBuilder {

    /// Stub: Returns an empty graph.
    /// v2.0: MacroNodes are now created directly via NodeFactory rather than
    /// through preset-to-graph conversion.
    static func buildGraph(from preset: LanePreset) -> NodeGraph {
        let graph = NodeGraph(autoSaveEnabled: false)

        // v2.0: The concept of building a graph from a LanePreset has been replaced
        // by direct MacroNode creation via NodeFactory.createNode().
        // This stub returns an empty graph; actual preset logic should use:
        //   NodeFactory.createNode(id: UUID(), type: "macro", params: [...])

        print("ImplicitGraphBuilder: v2.0 stub - use NodeFactory for preset creation")

        return graph
    }
}
