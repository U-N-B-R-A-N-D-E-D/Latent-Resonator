import Foundation
import AVFoundation

/// Helper for loading factory topology JSON files bundled in `Resources/Topologies`.
///
/// The JSON format matches `KickstartTemplate.json` – a `SerializedGraph`
/// representation with a top‑level `metadata` object that contains a user‑facing
/// `name` and `description`. All node types referenced in the topology must be
/// supported by `NodeFactory` (see `NodeGraph`).
///
/// Example usage:
/// ```swift
/// let graph = TopologyTemplates.load("feedback_basic")
/// let list = TopologyTemplates.allTemplates()
/// ```
enum TopologyTemplates {

    /// The subdirectory inside the app bundle where topology JSON files live.
    private static let subdirectory = "Topologies"

    /// The filename extension for topology files.
    private static let fileExtension = "json"

    // MARK: - Public API

    /// Loads a topology by name (without the `.json` extension) and returns a
    /// fully‑deserialized `NodeGraph`. Crashes if the file cannot be loaded or
    /// decoded – this is intentional because a missing factory topology is a
    /// developer‑level error.
    static func load(_ name: String) -> NodeGraph {
        guard let url = Bundle.main.url(forResource: name, withExtension: fileExtension, subdirectory: subdirectory) else {
            fatalError("❌ Topology \(name) not found in bundle subdirectory \(subdirectory)")
        }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            let serialized = try decoder.decode(SerializedGraph.self, from: data)
            let graph = NodeGraph()
            try graph.deserialize(serialized)
            return graph
        } catch {
            fatalError("❌ Failed to load topology \(name): \(error)")
        }
    }

    /// Returns an array of `(name, description)` for every topology JSON file
    /// bundled under `Resources/Topologies`. The `name` is the value from the
    /// file's `metadata.name` field; the `description` comes from
    /// `metadata.description`. Files that cannot be parsed are ignored – they
    /// will not appear in the list.
    static func allTemplates() -> [(name: String, description: String)] {
        guard let resourceURL = Bundle.main.resourceURL else { return [] }
        let topologiesURL = resourceURL.appendingPathComponent(subdirectory)
        guard let fileURLs = try? FileManager.default.contentsOfDirectory(at: topologiesURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        var results: [(String, String)] = []
        for url in fileURLs where url.pathExtension.lowercased() == fileExtension {
            if let meta = parseMetadata(from: url) {
                results.append((meta.name, meta.description))
            }
        }
        return results
    }

    // MARK: - Metadata parsing

    private struct TopologyMetadata: Decodable {
        let name: String
        let description: String
    }

    private struct Wrapper: Decodable {
        let metadata: TopologyMetadata
    }

    private static func parseMetadata(from url: URL) -> TopologyMetadata? {
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            let wrapper = try decoder.decode(Wrapper.self, from: data)
            return wrapper.metadata
        } catch {
            // Silently ignore malformed files – they will not be listed.
            return nil
        }
    }
}
