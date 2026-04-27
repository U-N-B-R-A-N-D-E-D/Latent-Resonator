import SwiftUI
import Combine

// MARK: - Performance Feed Entry
/// A curated performance metric entry for the terminal feed.
struct PerformanceFeedEntry: Identifiable, Equatable {
    let id = UUID()
    let timestamp: Date
    let category: FeedCategory
    let message: String
    let value: Double?
    let unit: String?
    
    enum FeedCategory: String, CaseIterable {
        case audio = "AUDIO"
        case latency = "LATENCY"
        case neural = "NEURAL"
        case system = "SYSTEM"
        case scene = "SCENE"
        
        var color: Color {
            switch self {
            case .audio: return .green
            case .latency: return .yellow
            case .neural: return .cyan
            case .system: return .gray
            case .scene: return .purple
            }
        }
    }
    
    var formattedValue: String? {
        guard let v = value, let u = unit else { return nil }
        return String(format: "%.2f %@", v, u)
    }
}

// MARK: - Performance Feed Manager
/// Curates and manages performance metrics for terminal display.
/// Captures audio levels, latencies, and system metrics at ~5Hz.
@MainActor
final class PerformanceFeedManager: ObservableObject {
    // MARK: - Published State
    @Published var entries: [PerformanceFeedEntry] = []
    @Published var isEnabled: Bool = true
    
    // MARK: - Configuration
    let maxEntries: Int = 100
    let updateInterval: TimeInterval = 0.2  // 5Hz update rate
    
    // MARK: - Private State
    private var updateTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    
    // Feed categories toggle
    var enabledCategories: Set<PerformanceFeedEntry.FeedCategory> = [.audio, .latency, .neural]
    
    // MARK: - Init
    init() {
        // Start feed when enabled
        $isEnabled
            .sink { [weak self] enabled in
                if enabled {
                    self?.startFeed()
                } else {
                    self?.stopFeed()
                }
            }
            .store(in: &cancellables)
    }
    
    // MARK: - Control
    func startFeed() {
        stopFeed()
        updateTimer = Timer.scheduledTimer(withTimeInterval: updateInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.captureFrame()
            }
        }
    }
    
    func stopFeed() {
        updateTimer?.invalidate()
        updateTimer = nil
    }
    
    func clear() {
        entries.removeAll()
    }
    
    // MARK: - Capture Methods
    
    /// Capture one frame of performance metrics.
    /// Called automatically at updateInterval when feed is enabled.
    func captureFrame() {
        guard isEnabled else { return }
        
        // Audio metrics from NeuralEngine (if available)
        if enabledCategories.contains(.audio) {
            captureAudioMetrics()
        }
        
        // Latency metrics
        if enabledCategories.contains(.latency) {
            captureLatencyMetrics()
        }
        
        // System resource metrics
        if enabledCategories.contains(.system) {
            captureSystemMetrics()
        }
    }
    
    /// Add a manual entry (for scene changes, neural inference, etc.)
    func addEntry(_ entry: PerformanceFeedEntry) {
        guard isEnabled else { return }
        entries.append(entry)
        trimEntries()
    }
    
    // MARK: - Private Capture Methods
    
    private func captureAudioMetrics() {
        // Placeholder: These would be populated from MacroNode telemetry
        // Actual implementation would query macro nodes for RMS, spectral data
    }
    
    private func captureLatencyMetrics() {
        // Placeholder: WebViewBridge latency measurements
    }
    
    private func captureSystemMetrics() {
        // Placeholder: CPU/memory usage
    }
    
    private func trimEntries() {
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }
}

// MARK: - Terminal Console View
//
// Mecha Metal terminal UI for displaying Python bridge server logs AND
// curated performance feed (D8 - Week 7).
//
// Design: High-contrast monospaced font on black background with phosphor
// green text, inspired by military/engineering terminal aesthetics.
// Features tabbed interface for Logs vs. Performance metrics.

private typealias DS = LRConstants.DS

struct TerminalConsoleView: View {
    @ObservedObject var bridgeProcess: BridgeProcessManager
    @StateObject private var feedManager = PerformanceFeedManager()
    @State private var autoScroll = true
    @State private var selectedTab: Tab = .logs
    
    enum Tab: String, CaseIterable {
        case logs = "LOGS"
        case performance = "PERFORMANCE"
    }
    
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
