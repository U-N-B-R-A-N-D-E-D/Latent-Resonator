import Foundation

// MARK: - Graph History (Phase 6)
//
// Command pattern for undo/redo in node graph editing.
// Each mutation is wrapped in a Command that can execute and undo.
//
// Shortcuts:
// - Cmd+Z: undo
// - Cmd+Shift+Z: redo

protocol GraphCommand {
    func execute(on graph: NodeGraph) throws
    func undo(on graph: NodeGraph) throws
}

// MARK: - Commands

/// Adds a node by type/position at execution time. Kept as a class so the
/// caller can read `createdNodeId` after `execute` to set focus / selection.
final class AddNodeCommand: GraphCommand {
    let nodeType: String
    let position: CGPoint
    let params: [String: Any]
    private(set) var createdNodeId: UUID? = nil

    init(nodeType: String, position: CGPoint, params: [String: Any] = [:]) {
        self.nodeType = nodeType
        self.position = position
        self.params = params
    }

    func execute(on graph: NodeGraph) throws {
        createdNodeId = graph.addNode(type: nodeType, position: position, params: params)
        if createdNodeId == nil {
            throw GraphHistoryError.commandFailed("AddNodeCommand: unknown node type '\(nodeType)'")
        }
    }

    func undo(on graph: NodeGraph) throws {
        if let id = createdNodeId {
            graph.removeNode(id: id)
        }
    }
}

struct RemoveNodeCommand: GraphCommand {
    let nodeId: UUID
    let snapshot: BaseGraphNode? // Captured for undo
    let connectedEdges: [GraphEdge] // Edges to restore on undo

    init(nodeId: UUID, graph: NodeGraph) {
        self.nodeId = nodeId
        self.snapshot = graph.nodes[nodeId] as? BaseGraphNode
        self.connectedEdges = graph.edges.values.filter { edge in
            edge.sourceNodeId == nodeId || edge.targetNodeId == nodeId
        }
    }

    func execute(on graph: NodeGraph) throws {
        try graph.applyMutation(.removeNode(id: nodeId))
    }

    func undo(on graph: NodeGraph) throws {
        guard let node = snapshot else { return }
        try graph.applyMutation(.addNode(
            id: node.id,
            nodeType: node.nodeType,
            position: CGPoint(x: node.x, y: node.y),
            params: node.parameters
        ))
        for edge in connectedEdges {
            try graph.applyMutation(.connectEdge(edge: edge))
        }
    }
}

struct ConnectEdgeCommand: GraphCommand {
    let edge: GraphEdge

    func execute(on graph: NodeGraph) throws {
        try graph.applyMutation(.connectEdge(edge: edge))
    }

    func undo(on graph: NodeGraph) throws {
        try graph.applyMutation(.disconnectEdge(id: edge.id))
    }
}

struct DisconnectEdgeCommand: GraphCommand {
    let edgeId: UUID
    let snapshot: GraphEdge? // Captured for undo

    init(edgeId: UUID, graph: NodeGraph) {
        self.edgeId = edgeId
        self.snapshot = graph.edges[edgeId]
    }

    func execute(on graph: NodeGraph) throws {
        try graph.applyMutation(.disconnectEdge(id: edgeId))
    }

    func undo(on graph: NodeGraph) throws {
        guard let edge = snapshot else { return }
        try graph.applyMutation(.connectEdge(edge: edge))
    }
}

/// Moves one or more nodes in a single undo step. `before` and `after` are
/// dictionaries of node positions so the whole gesture can be undone at once.
struct MoveNodesCommand: GraphCommand {
    let before: [UUID: CGPoint]
    let after: [UUID: CGPoint]

    func execute(on graph: NodeGraph) throws {
        for (id, position) in after {
            graph.setNodePosition(id: id, x: Double(position.x), y: Double(position.y))
        }
    }

    func undo(on graph: NodeGraph) throws {
        for (id, position) in before {
            graph.setNodePosition(id: id, x: Double(position.x), y: Double(position.y))
        }
    }
}

/// Groups multiple commands so they are pushed and undone as a single step.
/// Used for re-route (disconnect + connect) and multi-node delete.
struct CompoundCommand: GraphCommand {
    let commands: [GraphCommand]

    func execute(on graph: NodeGraph) throws {
        var executed: [GraphCommand] = []
        do {
            for command in commands {
                try command.execute(on: graph)
                executed.append(command)
            }
        } catch {
            // Roll back any partial work so the graph never ends up in a
            // half-applied state after a failed compound step.
            for command in executed.reversed() {
                try? command.undo(on: graph)
            }
            throw error
        }
    }

    func undo(on graph: NodeGraph) throws {
        for command in commands.reversed() {
            try command.undo(on: graph)
        }
    }
}

/// Expands a macro node and captures its pre-expansion state so the operation
/// can be undone. The scoped inverse removes only the nodes and edges that the
/// expand promoted, then restores the macro node from the snapshot. A full
/// snapshot of the macro's internal graph is also captured as a safety record.
final class ExpandMacroCommand: GraphCommand {
    let macroId: UUID
    private let macroSnapshot: SerializedNode
    private let internalGraphSnapshot: SerializedGraph
    private let wasExpanded: Bool

    init?(macroId: UUID, graph: NodeGraph) {
        guard let macroNode = graph.nodes[macroId] as? MacroNode else {
            return nil
        }
        self.macroId = macroId
        self.macroSnapshot = SerializedNode(from: macroNode)
        self.internalGraphSnapshot = macroNode.internalGraph.serialize()
        self.wasExpanded = macroNode.isExpanded
    }

    func execute(on graph: NodeGraph) throws {
        try graph.expand(macroId: macroId)
    }

    func undo(on graph: NodeGraph) throws {
        graph.collapseExpanded(macroId: macroId, restoring: macroSnapshot)
    }
}

/// Pastes a serialized subgraph with new UUIDs and an offset. Kept as a class
/// so the caller can read the new node IDs to set the selection afterwards.
final class PasteSubgraphCommand: GraphCommand {
    let subgraph: SerializedGraph
    let offset: CGPoint
    private(set) var pastedNodeIds: [UUID] = []

    init(subgraph: SerializedGraph, offset: CGPoint) {
        self.subgraph = subgraph
        self.offset = offset
    }

    func execute(on graph: NodeGraph) throws {
        pastedNodeIds = graph.pasteSubgraph(subgraph, offset: offset)
    }

    func undo(on graph: NodeGraph) throws {
        for id in pastedNodeIds {
            graph.removeNode(id: id)
        }
    }
}

// NOTE: `SetParameterCommand` is intentionally NOT wired into the canvas
// sliders. Continuous gestures (dragging a Slider) would flood the history
// stack with one entry per frame, which violates Max-style structural-only
// undo semantics. Parameter edits remain live and non-undoable, matching the
// v2 audio-thread design where `DSPNode.render` reads the current value on
// the next block.
struct SetParameterCommand: GraphCommand {
    let nodeId: UUID
    let paramId: String
    let newValue: Any
    let oldValue: Any? // Captured for undo

    func execute(on graph: NodeGraph) throws {
        graph.setNodeParameter(nodeId: nodeId, paramId: paramId, value: newValue)
    }

    func undo(on graph: NodeGraph) throws {
        if let old = oldValue {
            graph.setNodeParameter(nodeId: nodeId, paramId: paramId, value: old)
        }
    }
}

// MARK: - History Errors

enum GraphHistoryError: Error {
    case commandFailed(String)
}

// MARK: - History Manager

class GraphHistory: ObservableObject {
    @Published var canUndo: Bool = false
    @Published var canRedo: Bool = false
    
    private var undoStack: [GraphCommand] = []
    private var redoStack: [GraphCommand] = []
    /// Maximum number of commands remembered. Capped to avoid unbounded memory
    /// growth during long sessions while preserving a deep enough stack for
    /// exploratory patch editing.
    static let maxHistoryDepth = 100
    private let maxHistorySize: Int = GraphHistory.maxHistoryDepth

    weak var graph: NodeGraph?
    
    init(graph: NodeGraph? = nil) {
        self.graph = graph
    }
    
    // MARK: - Command Execution
    
    @discardableResult
    func execute(_ command: GraphCommand) -> Bool {
        guard let graph = graph else { return false }

        do {
            try command.execute(on: graph)

            // Push to undo stack
            undoStack.append(command)
            if undoStack.count > maxHistorySize {
                undoStack.removeFirst()
            }

            // Clear redo stack (new action invalidates redo history)
            redoStack.removeAll()

            updateState()
            return true
        } catch {
            print("GraphHistory: command execution failed - \(error)")
            return false
        }
    }
    
    // MARK: - Undo/Redo
    
    func undo() {
        guard let graph = graph, !undoStack.isEmpty else { return }
        
        let command = undoStack.removeLast()
        
        do {
            try command.undo(on: graph)
            redoStack.append(command)
            updateState()
        } catch {
            print("GraphHistory: undo failed - \(error)")
            // Restore stack state on failure
            undoStack.append(command)
        }
    }
    
    func redo() {
        guard let graph = graph, !redoStack.isEmpty else { return }
        
        let command = redoStack.removeLast()
        
        do {
            try command.execute(on: graph)
            undoStack.append(command)
            updateState()
        } catch {
            print("GraphHistory: redo failed - \(error)")
            // Restore stack state on failure
            redoStack.append(command)
        }
    }
    
    func clear() {
        undoStack.removeAll()
        redoStack.removeAll()
        updateState()
    }
    
    // MARK: - State
    
    private func updateState() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }
}
