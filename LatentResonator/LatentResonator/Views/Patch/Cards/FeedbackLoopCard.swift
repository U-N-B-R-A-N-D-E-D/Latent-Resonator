import SwiftUI

// MARK: - Feedback Loop Card
//
// Native node panel for `FeedbackLoopNode` — the "Resonator Core" that
// implements whitepaper §3.3: S(i+1) = ACE(S(i) + N(μ,σ), P, γ).
//
// Two knobs on the card face: FEEDBACK (loop gain, the recursive blend
// weight) and DELAY (the Lucier-style recirculation window). The
// inference buffer size and bridge wiring are advanced parameters that
// live in the right-click inspector, not on the card — the card shows
// only what the performer touches during play.
//
// Ports (rendered by NodeCardChrome's port rails):
//   inputs:  [in (audio)]
//   outputs: [out (audio)]

private typealias DS = LRConstants.DS

struct FeedbackLoopCard: View {

    @ObservedObject var node: FeedbackLoopNode
    let lockMode: PatchLockMode
    let isFocused: Bool

    var body: some View {
        NodeCardChrome(
            node: node,
            lockMode: lockMode,
            isFocused: isFocused,
            footerText: footerText
        ) {
            VStack(spacing: 6) {
                knobRow
                iterationReadout
            }
        }
    }

    // MARK: - Sub-views

    private var knobRow: some View {
        // P2.9 — DELAY knob removed. `FeedbackLoopNode.render` does not
        // consume `delayTime` (the recirculation path is the multi-second
        // ACE inference round-trip via `feedbackBuffer`, not a sample-level
        // delay line). The knob bound to `node.delayTime` but the value
        // was never read by the DSP — it lied to the performer.
        //
        // To wire it for real (deferred): add a pre-allocated
        // `recircDelayBuffer` (capacity `Int(sampleRate * maxDelayTime)`,
        // sized in init like `DelayLineNode`), a write head, and in
        // `render` read `feedbackBuffer` into the delay buffer with offset
        // `Int(delayTime * sampleRate)` before applying `fb`. The delay
        // line must be RT-safe (pre-allocated, NaN/Inf guarded) and the
        // `delayTime` parameter must be snapshotted at the top of render
        // (P1.5). This changes the instrument's character (Lucier window)
        // and warrants its own turn + listening tests.
        HStack(spacing: 8) {
            knob(label: "FEEDBACK", binding: feedbackBinding, range: 0...1, color: DS.neonTurquesa)
        }
    }

    private var iterationReadout: some View {
        HStack(spacing: DS.spacingXS) {
            Circle()
                .fill(node.inferenceStartedAt != nil ? DS.neonTurquesa : DS.textTertiary)
                .frame(width: DS.dotSM, height: DS.dotSM)
                .opacity(node.inferenceStartedAt != nil ? 1.0 : 0.4)
            Text("ITER \(node.iterationCount)")
                .font(DS.font(DS.fontCaption2, weight: .bold))
                .foregroundColor(DS.textTertiary)
                .tracking(DS.trackingLab)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func knob(
        label: String,
        binding: Binding<Float>,
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

    private var feedbackBinding: Binding<Float> {
        Binding(get: { node.feedback }, set: { node.feedback = $0 })
    }

    // P2.9 — `delayBinding` removed alongside the DELAY knob. The
    // `node.delayTime` property still exists on `FeedbackLoopNode` for
    // serialization compatibility, but is no longer surfaced on the card
    // (it has no DSP effect — see `knobRow` comment for the wire-up plan).

    // MARK: - Footer

    private var footerText: String {
        // P2.9 — drop the delay-ms readout; the DELAY knob is gone and the
        // value has no DSP effect. Keep the feedback + outcome tags so the
        // performer still sees loop state at a glance.
        let outcomeTag: String
        switch node.lastOutcome {
        case .success:   outcomeTag = "✓"
        case .failure:    outcomeTag = "✗"
        case .idle:        outcomeTag = "·"
        }
        return "\(outcomeTag) · fb\(String(format: "%.2f", node.feedback))"
    }
}
