import SwiftUI

// MARK: - Oscillator Card
//
// Native node panel for `OscillatorNode`. Single waveform picker on top,
// three knobs (FREQ, AMP, DRIFT) below — the parameters that matter for
// patch identity. Advanced parameters (pulse width, Euclidean k/n) live
// in the right-click inspector and are NOT cluttering the card.
//
// Ports (rendered by NodeCardChrome's port rails):
//   inputs:  [freq_cv (control)]
//   outputs: [out (audio)]

private typealias DS = LRConstants.DS

struct OscillatorCard: View {

    @ObservedObject var node: OscillatorNode
    let lockMode: PatchLockMode
    let isFocused: Bool

    var body: some View {
        NodeCardChrome(
            node: node,
            lockMode: lockMode,
            isFocused: isFocused,
            footerText: "\(node.waveform.rawValue) · \(formattedFrequency)"
        ) {
            VStack(spacing: 6) {
                waveformPicker
                knobRow
            }
        }
    }

    // MARK: - Sub-views

    private var waveformPicker: some View {
        LRSegmentPicker(
            items: ExcitationMode.allCases,
            selected: node.waveform,
            color: NodeCategory.source.color,
            labelForItem: { $0.rawValue },
            onSelect: { node.waveform = $0 }
        )
    }

    private var knobRow: some View {
        HStack(spacing: 8) {
            knob(label: "FREQ", binding: frequencyBinding,    range: 20...20_000, color: DS.neonTurquesa)
            knob(label: "AMP",  binding: amplitudeBinding,    range: 0...1,       color: DS.neonAmbar)
            knob(label: "DRIFT", binding: pitchDriftBinding,  range: 0...1,       color: NodeCategory.source.color)
            knob(label: "RATE",  binding: driftRateBinding,   range: 0...1,       color: NodeCategory.source.color)
        }
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

    private var frequencyBinding: Binding<Float> {
        Binding(get: { node.frequency }, set: { node.frequency = $0 })
    }

    private var amplitudeBinding: Binding<Float> {
        Binding(get: { node.amplitude }, set: { node.amplitude = $0 })
    }

    private var pitchDriftBinding: Binding<Float> {
        Binding(
            get: { node.getParam("pitchDrift", default: Float(0)) },
            set: { node.setParam("pitchDrift", value: $0) }
        )
    }

    private var driftRateBinding: Binding<Float> {
        Binding(
            get: { node.getParam("driftRate", default: Float(0)) },
            set: { node.setParam("driftRate", value: $0) }
        )
    }

    // MARK: - Formatting

    private var formattedFrequency: String {
        let f = node.frequency
        return f >= 1000
            ? String(format: "%.2f kHz", f / 1000)
            : String(format: "%.1f Hz", f)
    }
}
