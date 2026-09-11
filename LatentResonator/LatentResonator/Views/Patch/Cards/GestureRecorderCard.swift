import SwiftUI

// MARK: - Gesture Recorder Card
//
// Native node panel for `GestureRecorderNode` — MPE trajectory capture.
// Provides transport buttons (REC / PLAY / STOP / CLEAR) and a live readout
// of the recorder state. The actual gesture coordinates are fed from the
// PERFORM-mode XY pad (see `PerformanceMotherbaseView`).
//
// Ports (rendered by `NodeCardChrome`'s port rails):
//   inputs:  [record_trig, play_trig, stop_trig, rate_cv]
//   outputs: [x_out, y_out, pressure_out, gate_out]

private typealias DS = LRConstants.DS

struct GestureRecorderCard: View {

    @ObservedObject var node: GestureRecorderNode
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
                transportButtons
                stateReadout
            }
        }
    }

    // MARK: - Sub-views

    private var transportButtons: some View {
        HStack(spacing: 6) {
            transportButton(
                label: node.state == .recording ? "STOP" : "REC",
                color: node.state == .recording ? DS.danger : DS.danger,
                action: { node.onGate(portId: "record_trig", trigger: true) }
            )
            transportButton(
                label: "PLAY",
                color: DS.neonTurquesa,
                action: { node.onGate(portId: "play_trig", trigger: true) }
            )
            transportButton(
                label: "STOP",
                color: DS.textTertiary,
                action: { node.onGate(portId: "stop_trig", trigger: true) }
            )
            transportButton(
                label: "CLR",
                color: DS.warning,
                action: { node.clear() }
            )
        }
    }

    private func transportButton(
        label: String,
        color: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(label)
                .font(DS.font(DS.fontCaption2, weight: .bold))
                .foregroundColor(.black)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(color)
                .cornerRadius(DS.radiusSM)
        }
        .buttonStyle(.plain)
    }

    private var stateReadout: some View {
        HStack(spacing: DS.spacingXS) {
            Circle()
                .fill(stateColor)
                .frame(width: DS.dotSM, height: DS.dotSM)
            Text(stateLabel)
                .font(DS.font(DS.fontCaption2, weight: .bold))
                .foregroundColor(DS.textTertiary)
                .tracking(DS.trackingLab)
            Spacer()
            Text("\(node.trajectory.count) PTS")
                .font(DS.font(DS.fontCaption2, weight: .bold))
                .foregroundColor(DS.textDisabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Helpers

    private var stateColor: Color {
        switch node.state {
        case .recording:
            return DS.danger
        case .playing:
            return DS.neonTurquesa
        case .paused:
            return DS.warning
        case .idle:
            return DS.textDisabled
        }
    }

    private var stateLabel: String {
        switch node.state {
        case .recording:
            return "RECORDING"
        case .playing:
            return "PLAYING"
        case .paused:
            return "PAUSED"
        case .idle:
            return "IDLE"
        }
    }

    private var footerText: String {
        String(
            format: "X:%.2f Y:%.2f P:%.2f",
            node.currentOutputX(),
            node.currentOutputY(),
            node.currentOutputPressure()
        )
    }
}
