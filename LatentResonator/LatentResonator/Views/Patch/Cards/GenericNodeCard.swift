import SwiftUI

// MARK: - Generic Node Card
//
// Fallback panel for any `GraphNode` that does not have a hand-crafted
// card yet. Renders the node's parameters as a uniform list of knobs +
// fields driven entirely by `parameters: [String: Any]` introspection.
//
// This keeps the canvas honest: every node in the user's patch shows up
// with a recognizable identity (icon, name, color), even before its
// dedicated card lands. Once a card is built we just add a case in
// `NodeCardFactory`; the generic path remains as the safety net.

private typealias DS = LRConstants.DS

struct GenericNodeCard: View {

    @ObservedObject var node: BaseGraphNode
    let lockMode: PatchLockMode
    let isFocused: Bool

    var body: some View {
        NodeCardChrome(
            node: node,
            lockMode: lockMode,
            isFocused: isFocused,
            footerText: "\(parameterEntries.count) params"
        ) {
            if parameterEntries.isEmpty {
                emptyBody
            } else {
                parameterList
            }
        }
    }

    // MARK: - Sub-views

    private var emptyBody: some View {
        Text("NO PARAMETERS")
            .font(DS.font(DS.fontCaption2, weight: .bold))
            .foregroundColor(DS.textTertiary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 6)
    }

    private var parameterList: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(parameterEntries, id: \.key) { entry in
                parameterRow(key: entry.key, value: entry.value)
            }
        }
    }

    private func parameterRow(key: String, value: Any) -> some View {
        HStack(spacing: 6) {
            Text(key.uppercased())
                .font(DS.font(DS.fontCaption2, weight: .bold))
                .foregroundColor(DS.textTertiary)
                .frame(minWidth: 70, alignment: .leading)
            Spacer(minLength: 4)
            Text(format(value))
                .font(DS.font(DS.fontCaption, weight: .semibold))
                .foregroundColor(DS.textPrimary)
                .lineLimit(1)
        }
    }

    // MARK: - Helpers

    /// Stable, alphabetized parameter listing so the card layout doesn't
    /// flicker as Swift's dictionary order changes between runs.
    private var parameterEntries: [(key: String, value: Any)] {
        node.parameters
            .sorted { $0.key < $1.key }
            .map { ($0.key, $0.value) }
    }

    private func format(_ value: Any) -> String {
        if let f = value as? Float {
            return String(format: "%.3g", f)
        }
        if let d = value as? Double {
            return String(format: "%.3g", d)
        }
        if let i = value as? Int {
            return "\(i)"
        }
        if let b = value as? Bool {
            return b ? "ON" : "OFF"
        }
        if let s = value as? String {
            return s
        }
        return String(describing: value)
    }
}
