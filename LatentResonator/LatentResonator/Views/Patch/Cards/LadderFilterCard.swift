import SwiftUI

// MARK: - Ladder Filter Card
//
// Native node panel for `LadderFilterNode`. Mode picker (LP / HP / BP)
// on top, two knobs (CUT, RES) below. Cutoff range is 20 Hz — 20 kHz on
// a logarithmic-feeling 270° sweep so musical ranges (200 Hz — 5 kHz)
// land in the middle of the dial.
//
// Ports (rendered by NodeCardChrome's port rails):
//   inputs:  [in (audio), cutoff_cv (control), res_cv (control)]
//   outputs: [out (audio)]

private typealias DS = LRConstants.DS

struct LadderFilterCard: View {

    @ObservedObject var node: LadderFilterNode
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
                modePicker
                knobRow
            }
        }
    }

    // MARK: - Sub-views

    private var modePicker: some View {
        LRSegmentPicker(
            items: FilterMode.allCases,
            selected: node.mode,
            color: NodeCategory.effect.color,
            labelForItem: { $0.rawValue },
            onSelect: { node.mode = $0 }
        )
    }

    private var knobRow: some View {
        HStack(spacing: 8) {
            VStack(spacing: 2) {
                RetroKnob(
                    label: "CUT",
                    value: cutoffBinding,
                    range: 20...20_000,
                    accentColor: DS.neonTurquesa,
                    size: NodeCardMetrics.knobSize
                )
                Text("CUT")
                    .font(DS.font(DS.fontCaption2, weight: .bold))
                    .foregroundColor(DS.textTertiary)
            }
            VStack(spacing: 2) {
                RetroKnob(
                    label: "RES",
                    value: resonanceBinding,
                    range: 0...0.95,
                    accentColor: DS.neonAmbar,
                    size: NodeCardMetrics.knobSize
                )
                Text("RES")
                    .font(DS.font(DS.fontCaption2, weight: .bold))
                    .foregroundColor(DS.textTertiary)
            }
        }
    }

    // MARK: - Bindings

    private var cutoffBinding: Binding<Float> {
        Binding(get: { node.cutoff }, set: { node.cutoff = $0 })
    }

    private var resonanceBinding: Binding<Float> {
        Binding(get: { node.resonance }, set: { node.resonance = $0 })
    }

    // MARK: - Footer

    private var footerText: String {
        let cutoff = node.cutoff
        let cutoffStr = cutoff >= 1000
            ? String(format: "%.1fk", cutoff / 1000)
            : String(format: "%.0fHz", cutoff)
        return "\(node.mode.rawValue) · \(cutoffStr) · Q\(String(format: "%.2f", node.resonance))"
    }
}
