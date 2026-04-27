import Foundation

/// Persistent storage for NodeGraph state.
/// Automatically saves to ~/Library/Application Support/LatentResonator/node_graph.json
struct NodeGraphStore {
    
    private static var saveURL: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let appDir = appSupport.appendingPathComponent("LatentResonator", isDirectory: true)
        
        // Ensure directory exists
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        
        return appDir.appendingPathComponent("node_graph.json")
    }
    
    /// Save the node graph to disk.
    static func save(_ graph: NodeGraph) {
        let serialized = graph.serialize()
        
        do {
            let data = try JSONEncoder().encode(serialized)
            try data.write(to: saveURL)
            print("[GraphStore] ✓ Saved: \(serialized.nodes.count) nodes, \(serialized.edges.count) edges to \(saveURL.path)")
        } catch {
            print("[GraphStore] ✗ Failed to save: \(error.localizedDescription)")
        }
    }
    
    /// Load the node graph from disk. Returns nil if no saved graph exists.
    static func load() -> SerializedGraph? {
        guard FileManager.default.fileExists(atPath: saveURL.path) else {
            print("[GraphStore] No saved graph at \(saveURL.path)")
            return nil
        }
        
        do {
            let data = try Data(contentsOf: saveURL)
            let serialized = try JSONDecoder().decode(SerializedGraph.self, from: data)
            print("[GraphStore] ✓ Loaded: \(serialized.nodes.count) nodes, \(serialized.edges.count) edges from \(saveURL.path)")
            return serialized
        } catch {
            print("[GraphStore] ✗ Failed to load: \(error.localizedDescription)")
            return nil
        }
    }
    
    // MARK: - Graph Loading with Fallback
    
    /// Load graph with comprehensive logging and fallback chain.
    /// Tries: saved graph → KickstartTemplate → emergency minimal graph.
    static func loadGraphOrBootstrap() -> NodeGraph {
        print("[GraphStore] === Graph Loading Sequence ===")
        
        // Try 1: Load saved graph
        if let saved = load() {
            print("[GraphStore] Using saved graph")
            let graph = NodeGraph()
            do {
                try graph.deserialize(saved)
                print("[GraphStore] ✓ Restored: \(graph.nodes.count) nodes, \(graph.edges.count) edges")
                return graph
            } catch {
                print("[GraphStore] ✗ Failed to deserialize saved graph: \(error)")
            }
        }
        
        print("[GraphStore] No saved graph found, trying KickstartTemplate...")
        
        // Try 2: Load KickstartTemplate
        if let template = loadKickstartTemplate() {
            print("[GraphStore] ✓ Loaded KickstartTemplate")
            return template
        }
        
        print("[GraphStore] ✗ KickstartTemplate failed, creating emergency graph...")
        
        // Try 3: Emergency minimal graph (220 Hz saw)
        let emergency = createEmergencyGraph()
        print("[GraphStore] ✓ Created emergency graph: 220 Hz saw")
        return emergency
    }
    
    /// Load KickstartTemplate.json from bundle.
    private static func loadKickstartTemplate() -> NodeGraph? {
        guard let url = Bundle.main.url(forResource: "KickstartTemplate", withExtension: "json") else {
            print("[GraphStore] ✗ KickstartTemplate.json not found in bundle")
            return nil
        }
        
        do {
            let data = try Data(contentsOf: url)
            print("[GraphStore] KickstartTemplate data: \(data.count) bytes")
            
            let decoder = JSONDecoder()
            let serialized = try decoder.decode(SerializedGraph.self, from: data)
            print("[GraphStore] ✓ Decoded: \(serialized.nodes.count) nodes")
            
            let graph = NodeGraph()
            try graph.deserialize(serialized)
            return graph
        } catch {
            print("[GraphStore] ✗ Failed to decode KickstartTemplate: \(error)")
            return nil
        }
    }
    
    /// Create minimal emergency graph with 220 Hz saw.
    private static func createEmergencyGraph() -> NodeGraph {
        print("[GraphStore] Creating emergency graph...")
        let graph = NodeGraph()
        
        // Add oscillator at 220 Hz
        let osc = OscillatorNode(params: [
            "frequency": 220.0,
            "amplitude": 0.5,
            "waveform": "saw"
        ])
        osc.x = 100
        osc.y = 200
        graph.nodes[osc.id] = osc
        
        // Add master output
        let master = MasterOutputNode(name: "Master Out", x: 400, y: 200)
        graph.nodes[master.id] = master
        
        // Create edge
        let edge = GraphEdge(
            id: UUID(),
            sourceNodeId: osc.id,
            sourcePortId: "out",
            targetNodeId: master.id,
            targetPortId: "in",
            signalType: .audio
        )
        graph.edges[edge.id] = edge
        
        print("[GraphStore] Emergency graph: Oscillator(220Hz saw) → MasterOutput")
        return graph
    }
    
    // MARK: - Parameter Normalization
    
    /// Normalizes parameter values from various JSON formats to Swift types.
    /// Handles: wrapped format {"float": 65.41} → 65.41, flat format 65.41 → 65.41
    static func normalizeParameterValue(_ value: Any) -> Any {
        // Handle wrapped format {"float": 65.41}
        if let dict = value as? [String: Any] {
            if let floatVal = dict["float"] as? Float {
                return floatVal
            }
            if let doubleVal = dict["float"] as? Double {
                return Float(doubleVal)
            }
            if let intVal = dict["int"] as? Int {
                return intVal
            }
            if let stringVal = dict["string"] as? String {
                return stringVal
            }
            if let boolVal = dict["bool"] as? Bool {
                return boolVal
            }
            // Handle numeric strings that should be floats
            if let numStr = dict["float"] as? String,
               let parsed = Float(numStr) {
                return parsed
            }
        }
        
        // Handle Double→Float conversion (JSONDecoder often produces Double)
        if let doubleVal = value as? Double {
            return Float(doubleVal)
        }
        
        // Handle Int→Float conversion
        if let intVal = value as? Int {
            return Float(intVal)
        }
        
        return value
    }
    
    /// Normalizes all parameters in a dictionary.
    static func normalizeParameters(_ params: [String: Any]) -> [String: Any] {
        params.mapValues { normalizeParameterValue($0) }
    }
}
