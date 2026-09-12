import SwiftUI

// MARK: - Delay Card
//
// Native node panel for `DelayLineNode`. Three knobs (TIME, FB, MIX)
// matching the saved-patch parameter set 1:1 — same names a Max object
// would surface for `delay~` / `tapout~`.
//
// Ports (rendered by NodeCardChrome's port rails):
//   inputs:  [in (audio), time_cv (control), feedback_cv (control)]
//   outputs: [out (audio)]

private typealias DS = LRConstants.DS

struct DelayCard: View {

    @ObservedObject var node: DelayLineNode
    let lockMode: PatchLockMode
    let isFocused: Bool

    var body: some View {
        NodeCardChrome(
            node: node,
            lockMode: lockMode,
            isFocused: isFocused,
            footerText: footerText
        ) {
            HStack(spacing: 8) {
                knob("TIME", timeBinding, range: 0...2.0, color: DS.neonTurquesa)
                knob("FB",   feedbackBinding, range: 0...0.95, color: DS.neonAmbar)
                knob("MIX",  mixBinding, range: 0...1, color: NodeCategory.effect.color)
            }
        }
    }

    // MARK: - Sub-view

    private func knob(
        _ label: String,
        _ binding: Binding<Float>,
        range: ClosedRange<Float>,
        color: Color
    ) -> some View {
        VStack(spacing: 2) {
            RetroKnob(label: label, value: binding, range: range, accentColor: color, size: NodeCardMetrics.knobSize)
            Text(label)
                .font(DS.font(DS.fontCaption2, weight: .bold))
                .foregroundColor(DS.textTertiary)
        }
    }

    // MARK: - Bindings

    private var timeBinding: Binding<Float> {
        Binding(get: { node.delayTime }, set: { node.delayTime = $0 })
    }

    private var feedbackBinding: Binding<Float> {
        Binding(get: { node.feedback }, set: { node.feedback = $0 })
    }

    private var mixBinding: Binding<Float> {
        Binding(get: { node.wetDryMix }, set: { node.wetDryMix = $0 })
    }

    // MARK: - Footer

    private var footerText: String {
        let timeMs = node.delayTime * 1000.0
        return String(format: "%.0fms · fb %.0f%% · mix %.0f%%",
                      timeMs, node.feedback * 100, node.wetDryMix * 100)
    }
}
