import Foundation
import AVFoundation

/// Helper for loading factory topology JSON files bundled in `Resources/Topologies`.
///
/// The JSON format is a `SerializedGraph`
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

    /// Bundled reservoir entry for the topology picker.
    struct CatalogEntry: Identifiable {
        /// Filename without `.json` — passed to `loadSerialized(_:)` or user load.
        let fileName: String
        let displayName: String
        let description: String
        var tags: [String] = []
        var isUserSaved: Bool = false
        var id: String { (isUserSaved ? "user:" : "bundle:") + fileName }
    }

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
        let graph = NodeGraph()
        do {
            try graph.deserialize(loadSerialized(name))
            return graph
        } catch {
            fatalError("❌ Failed to load topology \(name): \(error)")
        }
    }

    /// Decode a bundled topology without constructing a `NodeGraph`.
    static func loadSerialized(_ fileName: String) throws -> SerializedGraph {
        guard let url = Bundle.main.url(
            forResource: fileName,
            withExtension: fileExtension,
            subdirectory: subdirectory
        ) else {
            throw TopologyError.notFound(fileName)
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(SerializedGraph.self, from: data)
    }

    /// Returns catalog entries for every topology JSON bundled under `Topologies/`.
    static func catalog() -> [CatalogEntry] {
        guard let urls = Bundle.main.urls(
            forResourcesWithExtension: fileExtension,
            subdirectory: subdirectory
        ) else { return [] }

        return urls
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
            .compactMap { fileName in
                guard let url = Bundle.main.url(
                    forResource: fileName,
                    withExtension: fileExtension,
                    subdirectory: subdirectory
                ), let meta = parseMetadata(from: url) else { return nil }
                return CatalogEntry(
                    fileName: fileName,
                    displayName: meta.name,
                    description: meta.description,
                    tags: meta.tags ?? []
                )
            }
    }

    /// Returns an array of `(name, description)` for every topology JSON file
    /// bundled under `Resources/Topologies`. The `name` is the value from the
    /// file's `metadata.name` field; the `description` comes from
    /// `metadata.description`. Files that cannot be parsed are ignored – they
    /// will not appear in the list.
    static func allTemplates() -> [(name: String, description: String)] {
        catalog().map { ($0.displayName, $0.description) }
    }

    enum TopologyError: LocalizedError {
        case notFound(String)
        case decodeFailed(String, Error)

        var errorDescription: String? {
            switch self {
            case .notFound(let name):
                return "Topology '\(name)' not found in bundle."
            case .decodeFailed(let name, let error):
                return "Failed to decode '\(name)': \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Metadata parsing

    private struct TopologyMetadata: Decodable {
        let name: String
        let description: String
        let tags: [String]?
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
