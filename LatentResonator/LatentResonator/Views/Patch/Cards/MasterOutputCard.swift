import SwiftUI

// MARK: - Master Output Card
//
// Native panel for `MasterOutputNode` — the terminal of the audio
// graph. One VOLUME knob, one tiny LIM display showing the limiter
// ceiling in dB. The card is intentionally narrow: it always sits at
// the right edge of a patch, so a tall + slim profile reads "this is
// where everything lands."
//
// Ports (rendered by NodeCardChrome's port rails):
//   inputs:  [in (audio)]
//   outputs: (none — terminal)

private typealias DS = LRConstants.DS

struct MasterOutputCard: View {

    @ObservedObject var node: MasterOutputNode
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
                volumeKnob
                limiterDisplay
            }
        }
    }

    // MARK: - Sub-views

    private var volumeKnob: some View {
        VStack(spacing: 2) {
            RetroKnob(
                label: "VOL",
                value: volumeBinding,
                range: 0...1,
                accentColor: NodeCategory.output.color,
                size: NodeCardMetrics.knobSize
            )
            Text("VOL")
                .font(DS.font(DS.fontCaption2, weight: .bold))
                .foregroundColor(DS.textTertiary)
        }
    }

    private var limiterDisplay: some View {
        VStack(spacing: 4) {
            Text("LIM")
                .font(DS.font(DS.fontCaption2, weight: .bold))
                .foregroundColor(DS.textTertiary)

            Text(String(format: "%.1f dB", node.limiterThreshold))
                .font(DS.font(DS.fontCaption, weight: .semibold))
                .foregroundColor(DS.neonAmbar)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(DS.surfacePrimary)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(DS.border, lineWidth: 1)
                )
        }
    }

    // MARK: - Bindings

    private var volumeBinding: Binding<Float> {
        Binding(get: { node.volume }, set: { node.volume = $0 })
    }

    // MARK: - Footer

    private var footerText: String {
        let percent = Int(node.volume * 100)
        return "OUT · \(percent)%"
    }
}
