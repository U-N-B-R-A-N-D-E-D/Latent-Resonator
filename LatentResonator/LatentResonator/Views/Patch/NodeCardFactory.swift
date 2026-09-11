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

    @ObservedObject var engine: NeuralEngine
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

        // The two neural "soul" nodes — the recursive core (§3.3) and the
        // inference surface that drives it. These MUST be editable from the
        // canvas; falling through to GenericNodeCard read-only would leave
        // the performer unable to touch the instrument's identity.
        case let feedback as FeedbackLoopNode:
            FeedbackLoopCard(node: feedback, lockMode: lockMode, isFocused: isFocused)

        case let infer as ACEStepInferenceNode:
            ACEStepInferenceCard(node: infer, engine: engine, lockMode: lockMode, isFocused: isFocused)

        // Collapsible macro node: dedicated card with the expand/collapse
        // gesture wrapped in an `ExpandMacroCommand` so it participates in
        // the structural undo history. The command captures the macro's
        // pre-expansion state, executes `expand`, and can undo the promotion.
        case let macro as MacroNode:
            MacroCard(
                node: macro,
                lockMode: lockMode,
                isFocused: isFocused
            ) {
                guard let command = ExpandMacroCommand(
                    macroId: macro.id,
                    graph: engine.nodeGraph
                ) else {
                    print("MacroCard: could not create expand command for \(macro.id)")
                    return
                }
                if !NodeGraphStore.history.execute(command) {
                    print("MacroCard: expand command failed for \(macro.id)")
                }
            }

        // Cross-worker contract: Worker ALPHA owns GestureRecorderCard.swift.
        // Class name must be exactly `GestureRecorderCard` and must accept
        // the same `(node:lockMode:isFocused:)` initializer as the other
        // dedicated cards.
        case let gesture as GestureRecorderNode:
            GestureRecorderCard(node: gesture, lockMode: lockMode, isFocused: isFocused)

        case let base as BaseGraphNode:
            GenericNodeCard(node: base, engine: engine, lockMode: lockMode, isFocused: isFocused)

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
