import SwiftUI

// MARK: - Node Card Factory
//
// Single dispatch point that turns a `GraphNode` from the data model
// into a SwiftUI view on the patch canvas. Each handcrafted card has
// its own case; everything else falls through to `GenericNodeCard`.
//
// When a new node type lands a dedicated card, you add one case here
// and the canvas automatically picks it up — no other call sites change.

struct NodeCardFactory: View {

    let node: any GraphNode
    let lockMode: PatchLockMode
    let isFocused: Bool

    var body: some View {
        switch node {
        case let osc as OscillatorNode:
            OscillatorCard(node: osc, lockMode: lockMode, isFocused: isFocused)

        case let filter as LadderFilterNode:
            LadderFilterCard(node: filter, lockMode: lockMode, isFocused: isFocused)

        case let delay as DelayLineNode:
            DelayCard(node: delay, lockMode: lockMode, isFocused: isFocused)

        case let mixer as MixerNode:
            MixerCard(node: mixer, lockMode: lockMode, isFocused: isFocused)

        case let master as MasterOutputNode:
            MasterOutputCard(node: master, lockMode: lockMode, isFocused: isFocused)

        case let base as BaseGraphNode:
            GenericNodeCard(node: base, lockMode: lockMode, isFocused: isFocused)

        default:
            // GraphNode is a protocol; anything not deriving from
            // BaseGraphNode is unexpected. Render a stripped-down chrome
            // so the canvas stays consistent rather than showing a hole.
            unsupportedFallback
        }
    }

    private var unsupportedFallback: some View {
        Text("UNSUPPORTED NODE: \(node.nodeType)")
            .font(LRConstants.DS.font(LRConstants.DS.fontCaption, weight: .bold))
            .foregroundColor(LRConstants.DS.danger)
            .padding()
            .background(LRConstants.DS.surfacePrimary)
            .cornerRadius(NodeCardMetrics.cornerRadius)
    }
}
