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

struct AddNodeCommand: GraphCommand {
    let node: BaseGraphNode
    
    func execute(on graph: NodeGraph) throws {
        try graph.applyMutation(.addNode(
            id: node.id,
            nodeType: node.nodeType,
            position: CGPoint(x: node.x, y: node.y),
            params: node.parameters
        ))
    }
    
    func undo(on graph: NodeGraph) throws {
        try graph.applyMutation(.removeNode(id: node.id))
    }
}

struct RemoveNodeCommand: GraphCommand {
    let nodeId: UUID
    let snapshot: BaseGraphNode? // Captured for undo
    let connectedEdges: [GraphEdge] // Edges to restore on undo
    
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
        
        // Restore edges
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
    
    func execute(on graph: NodeGraph) throws {
        try graph.applyMutation(.disconnectEdge(id: edgeId))
    }
    
    func undo(on graph: NodeGraph) throws {
        guard let edge = snapshot else { return }
        try graph.applyMutation(.connectEdge(edge: edge))
    }
}

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

// MARK: - History Manager

class GraphHistory: ObservableObject {
    @Published var canUndo: Bool = false
    @Published var canRedo: Bool = false
    
    private var undoStack: [GraphCommand] = []
    private var redoStack: [GraphCommand] = []
    private let maxHistorySize: Int = 100
    
    weak var graph: NodeGraph?
    
    init(graph: NodeGraph? = nil) {
        self.graph = graph
    }
    
    // MARK: - Command Execution
    
    func execute(_ command: GraphCommand) {
        guard let graph = graph else { return }
        
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
        } catch {
            print("GraphHistory: command execution failed - \(error)")
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
