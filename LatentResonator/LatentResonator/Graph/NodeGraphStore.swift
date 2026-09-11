import Foundation

/// Persistent storage for NodeGraph state.
/// Automatically saves to ~/Library/Application Support/LatentResonator/node_graph.json
struct NodeGraphStore {

    // MARK: - Shared canvas editing state (Wave B)
    //
    // The single history owner lives at the store level because the graph is
    // a single source of truth and there is only one active canvas. Both the
    // canvas view and `RootView` keyboard shortcuts reach the same history
    // through this static reference. Selection and clipboard are also here
    // so keyboard shortcuts can read/write the same view state without passing
    // bindings through every layer.
    static let history = GraphHistory()
    static let selection = CanvasSelectionHandler()
    static var clipboard: SerializedGraph? = nil

    // MARK: - Bootstrap Load Guard
    //
    // The topology reservoir sheet's `hasSavedSession` was evaluating
    // `NodeGraphStore.load()` on every SwiftUI body pass during bootstrap,
    // producing the "[GraphStore] ✓ Loaded" line up to six times. The guard
    // below ensures the disk is read once per app session; the cache is
    // invalidated whenever the graph is saved so explicit reloads remain fresh.
    private static var bootstrapLoadCompleted: Bool = false
    private static var bootstrapLoadResult: SerializedGraph?

    /// Test-only override for all disk writes. When set, saves and loads are
    /// redirected to this directory instead of the production Application Support
    /// folder. The test bundle sets this in `StoreIsolationTests.swift`.
    private static var testingOverrideDirectory: URL? = nil

    /// Redirects all NodeGraphStore disk writes to the given directory for the
    /// duration of the process. Used by the test bundle to isolate production
    /// data from unit-test side effects.
    internal static func setTestingOverrideDirectory(_ url: URL?) {
        testingOverrideDirectory = url
        // Any cached bootstrap load came from the previous directory; clear it
        // so the next explicit load reads from the new location.
        bootstrapLoadCompleted = false
        bootstrapLoadResult = nil
    }

    /// True when the process is running under XCTest. Used to auto-redirect
    /// disk writes to a temp directory so that unit tests never touch the
    /// production Application Support store.
    private static var isRunningTests: Bool {
        NSClassFromString("XCTestCase") != nil
    }

    /// Lazily-created per-process temp directory used when no explicit override
    /// has been set and the test bundle is loaded.
    private static var testAutoDirectory: URL? = nil

    private static var testStoreDirectory: URL {
        if let existing = testAutoDirectory { return existing }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LatentResonatorTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        testAutoDirectory = dir
        return dir
    }

    private static var applicationSupportDirectory: URL {
        if let override = testingOverrideDirectory {
            try? FileManager.default.createDirectory(at: override, withIntermediateDirectories: true)
            return override
        }

        if isRunningTests {
            return testStoreDirectory
        }

        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let appDir = appSupport.appendingPathComponent("LatentResonator", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        return appDir
    }

    private static var saveURL: URL {
        applicationSupportDirectory.appendingPathComponent("node_graph.json")
    }

    private static var userTopologiesDirectory: URL {
        let dir = applicationSupportDirectory.appendingPathComponent("UserTopologies", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Test-only access to the effective save URL so the isolation test can verify
    /// that writes land in the override directory.
    internal static var testingSaveURL: URL { saveURL }
    
    /// Save the current graph as a named user topology in Application Support.
    static func saveUserTopology(_ graph: NodeGraph, name: String) throws -> String {
        let slug = slugify(name)
        let url = userTopologiesDirectory.appendingPathComponent("\(slug).json")
        let serialized = graph.serialize()
        let wrapper = UserTopologyDocument(
            metadata: UserTopologyMetadata(
                name: name,
                description: "User patch saved from STAGES canvas",
                tags: ["user"]
            ),
            graph: serialized
        )
        let data = try JSONEncoder().encode(wrapper)
        try data.write(to: url)
        print("[GraphStore] ✓ Saved user topology '\(name)' → \(url.path)")
        return slug
    }

    /// List user-saved topology files (filename without `.json`).
    static func listUserTopologyFiles() -> [String] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: userTopologiesDirectory,
            includingPropertiesForKeys: nil
        ) else { return [] }
        return urls
            .filter { $0.pathExtension == "json" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }

    /// Load a user topology by slug (filename without extension).
    static func loadUserTopology(fileName: String) throws -> SerializedGraph {
        let url = userTopologiesDirectory.appendingPathComponent("\(fileName).json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw TopologyTemplates.TopologyError.notFound(fileName)
        }
        let data = try Data(contentsOf: url)
        let doc = try JSONDecoder().decode(UserTopologyDocument.self, from: data)
        return doc.graph
    }

    /// Catalog entries for user topologies (RESERVOIR picker).
    static func userTopologyCatalog() -> [TopologyTemplates.CatalogEntry] {
        listUserTopologyFiles().compactMap { slug in
            let url = userTopologiesDirectory.appendingPathComponent("\(slug).json")
            guard let data = try? Data(contentsOf: url),
                  let doc = try? JSONDecoder().decode(UserTopologyDocument.self, from: data) else {
                return TopologyTemplates.CatalogEntry(
                    fileName: slug,
                    displayName: slug.replacingOccurrences(of: "-", with: " "),
                    description: "User-saved topology",
                    tags: ["user"],
                    isUserSaved: true
                )
            }
            return TopologyTemplates.CatalogEntry(
                fileName: slug,
                displayName: doc.metadata.name,
                description: doc.metadata.description,
                tags: doc.metadata.tags,
                isUserSaved: true
            )
        }
    }

    private static func slugify(_ name: String) -> String {
        let lowered = name.lowercased()
        let allowed = lowered.map { char -> Character in
            if char.isLetter || char.isNumber { return char }
            if char == " " || char == "-" || char == "_" { return "-" }
            return "-"
        }
        let slug = String(allowed)
            .replacingOccurrences(of: "--", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? "topology-\(Int(Date().timeIntervalSince1970))" : slug
    }
    
    /// True if a saved session exists on disk. Does not decode the file, so it
    /// is safe to call from SwiftUI body recomputations without triggering the
    /// repeated "[GraphStore] ✓ Loaded" cascade.
    static var hasSavedSession: Bool {
        FileManager.default.fileExists(atPath: saveURL.path)
    }

    /// Save the node graph to disk.
    static func save(_ graph: NodeGraph) {
        // After a save, the bootstrap cache must be cleared so the next explicit
        // reload (e.g. loadTopology(from: .savedSession)) reads the new graph.
        bootstrapLoadCompleted = false
        bootstrapLoadResult = nil

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
    /// Uses a one-shot bootstrap cache so repeated calls during app launch do not
    /// re-read and re-decode the same JSON.
    static func load() -> SerializedGraph? {
        if bootstrapLoadCompleted {
            return bootstrapLoadResult
        }

        guard FileManager.default.fileExists(atPath: saveURL.path) else {
            print("[GraphStore] No saved graph at \(saveURL.path)")
            bootstrapLoadCompleted = true
            bootstrapLoadResult = nil
            return nil
        }

        do {
            let data = try Data(contentsOf: saveURL)
            let serialized = try JSONDecoder().decode(SerializedGraph.self, from: data)
            print("[GraphStore] ✓ Loaded: \(serialized.nodes.count) nodes, \(serialized.edges.count) edges from \(saveURL.path)")
            bootstrapLoadCompleted = true
            bootstrapLoadResult = serialized
            return serialized
        } catch {
            print("[GraphStore] ✗ Failed to load: \(error.localizedDescription)")
            bootstrapLoadCompleted = true
            bootstrapLoadResult = nil
            return nil
        }
    }
    
    // MARK: - Graph Loading with Fallback
    
    /// Load graph with comprehensive logging and fallback chain.
    /// Tries: saved graph → default factory topology → emergency minimal graph.
    /// After a successful load the shared history is re-bound to the new graph
    /// and cleared, and the canvas selection is reset, because a topology load
    /// is a fresh document from the performer's perspective.
    static func loadGraphOrBootstrap() -> NodeGraph {
        print("[GraphStore] === Graph Loading Sequence ===")

        var graph: NodeGraph? = nil

        // Try 1: Load saved graph
        if let saved = load() {
            print("[GraphStore] Using saved graph")
            let candidate = NodeGraph()
            do {
                try candidate.deserialize(saved)
                graph = candidate
                print("[GraphStore] ✓ Restored: \(candidate.nodes.count) nodes, \(candidate.edges.count) edges")
            } catch {
                print("[GraphStore] ✗ Failed to deserialize saved graph: \(error)")
            }
        }

        // Try 2: Load default factory topology (seed → feedback → flat)
        if graph == nil {
            print("[GraphStore] No saved graph found, trying factory topology '\(LRConstants.defaultFactoryTopologyFileName)'...")
            if let template = loadDefaultFactoryTopology() {
                graph = template
                print("[GraphStore] ✓ Loaded factory topology")
            }
        }

        // Try 3: Emergency minimal graph (220 Hz saw)
        if graph == nil {
            print("[GraphStore] ✗ Factory topology failed, creating emergency graph...")
            graph = createEmergencyGraph()
            print("[GraphStore] ✓ Created emergency graph: 220 Hz saw")
        }

        let finalGraph = graph!
        history.graph = finalGraph
        history.clear()
        selection.selectedNodeIds.removeAll()
        return finalGraph
    }
    
    /// Load the default factory topology from `Resources/Topologies/`.
    private static func loadDefaultFactoryTopology() -> NodeGraph? {
        do {
            let serialized = try TopologyTemplates.loadSerialized(LRConstants.defaultFactoryTopologyFileName)
            print("[GraphStore] ✓ Decoded factory topology: \(serialized.nodes.count) nodes")
            let graph = NodeGraph()
            try graph.deserialize(serialized)
            return graph
        } catch {
            print("[GraphStore] ✗ Failed to load factory topology: \(error)")
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
        
        print("[GraphStore] Emergency graph: Oscillator(220Hz saw) → MasterOutput [fail-safe health-check only — not the instrument]")
        return graph
    }
    
    // MARK: - User Topology Document
    
    struct UserTopologyMetadata: Codable {
        var name: String
        var description: String
        var tags: [String]
    }
    
    struct UserTopologyDocument: Codable {
        var metadata: UserTopologyMetadata
        var graph: SerializedGraph
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
