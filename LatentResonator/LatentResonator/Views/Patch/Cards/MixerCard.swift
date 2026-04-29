import SwiftUI

// MARK: - Mixer Card
//
// Native node panel for `MixerNode`. Four channel faders (G1…G4) matched
// to the four audio inputs (in1…in4 on the left port rail), plus a
// MASTER knob on the right. The fader-not-knob choice is deliberate: a
// vertical fader strip makes balancing levels feel like a console, and
// the visual scales naturally with the input count.
//
// Ports (rendered by NodeCardChrome's port rails):
//   inputs:  [in1, in2, in3, in4 (audio), gain_cv (control)]
//   outputs: [out (audio)]

private typealias DS = LRConstants.DS

struct MixerCard: View {

    @ObservedObject var node: MixerNode
    let lockMode: PatchLockMode
    let isFocused: Bool

    var body: some View {
        NodeCardChrome(
            node: node,
            lockMode: lockMode,
            isFocused: isFocused,
            footerText: "MASTER \(Int(node.masterGain * 100))%"
        ) {
            HStack(spacing: 10) {
                ForEach(1...MixerNode.maxInputs, id: \.self) { idx in
                    channelStrip(index: idx)
                }
                Divider()
                    .frame(height: 70)
                    .background(DS.border)
                masterKnob
            }
        }
    }

    // MARK: - Sub-views

    private func channelStrip(index: Int) -> some View {
        VStack(spacing: 4) {
            Text("\(index)")
                .font(DS.font(DS.fontCaption2, weight: .bold))
                .foregroundColor(DS.textTertiary)
                .tracking(1)

            CompactFader(
                value: gainBinding(for: index),
                range: 0...1,
                accent: NodeCategory.routing.color
            )
            .frame(width: 16, height: 60)

            Text("\(Int(gainBinding(for: index).wrappedValue * 100))")
                .font(DS.font(DS.fontCaption2))
                .foregroundColor(DS.textTertiary)
                .frame(minWidth: 22)
        }
    }

    private var masterKnob: some View {
        VStack(spacing: 2) {
            RetroKnob(
                label: "MAS",
                value: masterGainBinding,
                range: 0...1,
                accentColor: DS.neonAmbar,
                size: NodeCardMetrics.knobSize
            )
            Text("MAS")
                .font(DS.font(DS.fontCaption2, weight: .bold))
                .foregroundColor(DS.textTertiary)
        }
    }

    // MARK: - Bindings

    private func gainBinding(for index: Int) -> Binding<Float> {
        let key = "gain\(index)"
        return Binding(
            get: { node.getParam(key, default: Float(1.0)) },
            set: { node.setParam(key, value: $0) }
        )
    }

    private var masterGainBinding: Binding<Float> {
        Binding(get: { node.masterGain }, set: { node.masterGain = $0 })
    }
}

// MARK: - Compact Fader

/// Slim vertical fader sized for inline use inside a node card. Drag
/// up/down within the track to set the value.
private struct CompactFader: View {
    @Binding var value: Float
    let range: ClosedRange<Float>
    let accent: Color

    @State private var isDragging = false

    var body: some View {
        GeometryReader { geo in
            let span = max(range.upperBound - range.lowerBound, 1e-6)
            let normalized = CGFloat((value - range.lowerBound) / span)
            let h = geo.size.height
            let knobY = h - normalized * h

            ZStack(alignment: .top) {
                // Track
                RoundedRectangle(cornerRadius: 2)
                    .fill(LRConstants.DS.surfacePrimary)
                    .overlay(
                        RoundedRectangle(cornerRadius: 2)
                            .stroke(LRConstants.DS.border, lineWidth: 1)
                    )
                // Fill
                RoundedRectangle(cornerRadius: 2)
                    .fill(accent.opacity(0.55))
                    .frame(height: max(0, h - knobY))
                    .offset(y: knobY)
                // Knob cap
                RoundedRectangle(cornerRadius: 2)
                    .fill(accent)
                    .frame(width: geo.size.width + 6, height: 6)
                    .offset(x: -3, y: max(0, min(h - 6, knobY - 3)))
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        isDragging = true
                        let normalized = 1.0 - (drag.location.y / h)
                        let clamped = min(max(Float(normalized), 0), 1)
                        value = range.lowerBound + clamped * span
                    }
                    .onEnded { _ in isDragging = false }
            )
        }
    }
}
