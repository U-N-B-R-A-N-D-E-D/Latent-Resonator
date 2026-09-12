import SwiftUI
import Combine

// MARK: - Terminal Console View
//
// Mecha Metal terminal UI for displaying the Python bridge server log.
// High-contrast monospaced font on black background with phosphor green
// text, inspired by military/engineering terminal aesthetics.
//
// The log is fed live from `BridgeProcessManager.realtimeLog`, which is
// populated by the `Pipe` readability handler attached to the Python
// process stdout/stderr. Auto-scroll keeps the tail visible; text is
// selectable for error reporting. The performance-profile toggle (D6)
// lives in the header bar.
//
// Note: a "PERFORMANCE" tab with telemetry feed was stubbed here in an
// earlier iteration but never wired to real metrics — it has been removed
// rather than shipped as a fake feature. When real telemetry (bridge
// latency, macro RMS/spectral centroid, DSP state) is available, a new
// panel can be added that actually populates from `NeuralEngine` and
// `ACEStepBridge` published state.

private typealias DS = LRConstants.DS

struct TerminalConsoleView: View {
    @ObservedObject var bridgeProcess: BridgeProcessManager
    @State private var autoScroll = true
    
    var body: some View {
        VStack(spacing: 0) {
            // Header bar with status and profile selector
            HStack(spacing: 12) {
                // Status indicator
                HStack(spacing: 6) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                        .shadow(color: statusColor.opacity(0.6), radius: 2)

                    Text(bridgeProcess.state.rawValue)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(.green.opacity(0.8))
                }

                // Performance Profile Toggle (D6)
                HStack(spacing: 2) {
                    ForEach(PerformanceProfile.allCases) { profile in
                        profileButton(profile)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.black.opacity(0.6))
                .cornerRadius(4)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.green.opacity(0.3), lineWidth: 1)
                )
                .help("Performance Profile: \(bridgeProcess.currentProfile.description). Switching disabled during playback (D6).")

                if !bridgeProcess.canSwitchProfile {
                    Text("Profile locked while DSP ON")
                        .font(DS.font(DS.fontCaption2, weight: .bold))
                        .foregroundColor(DS.warning)
                }

                Spacer()

                Toggle("Auto-scroll", isOn: $autoScroll)
                    .font(.system(size: 10))
                    .toggleStyle(.switch)
            }
            .padding(8)
            .background(Color.black.opacity(0.9))
            
            // Log output - ALL text selectable for easy error reporting
            ScrollViewReader { proxy in
                ScrollView {
                    // Use VStack instead of LazyVStack for better text selection
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(bridgeProcess.realtimeLog.enumerated()), id: \.offset) { idx, line in
                            Text(line)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.green.opacity(0.7))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(idx)
                        }
                    }
                    .padding(8)
                    // Enable text selection for entire content, not just individual lines
                    .textSelection(.enabled)
                }
                .background(Color.black.opacity(0.95))
                .onChange(of: bridgeProcess.realtimeLog.count) { _, _ in
                    if autoScroll, let lastIdx = bridgeProcess.realtimeLog.indices.last {
                        withAnimation(.easeOut(duration: 0.1)) {
                            proxy.scrollTo(lastIdx, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .frame(height: 200)
        .overlay(
            Rectangle()
                .stroke(statusColor.opacity(0.3), lineWidth: 1)
        )
    }
    
    private var statusColor: Color {
        switch bridgeProcess.state {
        case .running:
            return .green
        case .error:
            return .red
        case .launching, .settingUp, .installing:
            return .yellow
        case .stopping:
            return .orange
        default:
            return .gray
        }
    }

    // MARK: - Performance Profile Toggle

    private func profileButton(_ profile: PerformanceProfile) -> some View {
        let isSelected = bridgeProcess.currentProfile == profile
        let isEnabled = bridgeProcess.canSwitchProfile

        return Button(action: {
            if !isSelected {
                _ = bridgeProcess.switchProfile(to: profile)
            }
        }) {
            Text(profile.shortLabel)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(isSelected ? .black : (isEnabled ? .green : .gray))
                .frame(width: 20, height: 18)
                .background(isSelected ? Color.green : Color.clear)
                .cornerRadius(2)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help("\(profile.rawValue): \(profile.description)")
    }
}
