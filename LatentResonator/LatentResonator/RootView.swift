import SwiftUI
import AppKit

// MARK: - Root View (Setup vs Performance)
//
// One window, two modes: Setup (full mixer + DETAIL) or Performance (Motherbase).
// Prep vs perform -- reduces cognitive load during the act.
// Global keyboard shortcut system for hands-on-instrument control.

private typealias DS = LRConstants.DS

struct RootView: View {

    @ObservedObject var engine: NeuralEngine
    @State private var showPerformanceView: Bool = false
    @State private var showSettings: Bool = false
    @AppStorage("LatentResonator.hasSeenOnboarding") private var hasSeenOnboarding = false
    @State private var showOnboarding = false

    var body: some View {
        VStack(spacing: 0) {
            modeToggleBar
            if showPerformanceView {
                PerformanceMotherbaseView(engine: engine)
            } else {
                LatentResonatorView(engine: engine)
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(engine: engine)
        }
        .sheet(isPresented: $showOnboarding) {
            onboardingSheet
        }
        .background(KeyEventHandler(handler: handleKeyEvent))
        .onAppear {
            LRConstants.ModelConfig.ensureDefaultDirectoryExists()
            if !hasSeenOnboarding {
                showOnboarding = true
            }
        }
    }

    // MARK: - Onboarding Sheet

    private var onboardingSheet: some View {
        VStack(spacing: DS.spacingLG) {
            Spacer()

            Text("LATENT RESONATOR")
                .font(DS.font(DS.fontHeadline, weight: .bold))
                .foregroundColor(DS.phosphor)
                .tracking(3)

            Text("Non-Linear Spectral Processor")
                .font(DS.font(DS.fontBody, weight: .medium))
                .foregroundColor(DS.textSecondary)

            LRDivider()
                .padding(.horizontal, 40)

            VStack(alignment: .leading, spacing: DS.spacingMD) {
                onboardingBullet("SETUP mode for sound design -- PERFORM mode for live performance")
                onboardingBullet("Press SPACE to start/stop the neural feedback loop")
                onboardingBullet("TAB switches between SETUP and PERFORM views")
                onboardingBullet("The XY pad controls Texture (X) and Chaos (Y) macros")
                onboardingBullet("MIDI CC 20-37 routes to the focus lane. Cmd+, for full shortcut list")
            }
            .padding(.horizontal, 40)

            Spacer()

            LRActionButton(label: "BEGIN", color: DS.success, style: .primary) {
                hasSeenOnboarding = true
                showOnboarding = false
            }
            .padding(.horizontal, 60)
            .padding(.bottom, DS.spacingXL)
        }
        .frame(width: 480, height: 380)
        .background(DS.surfacePrimary)
    }

    private func onboardingBullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: DS.spacingSM) {
            Circle()
                .fill(DS.phosphor.opacity(0.5))
                .frame(width: 5, height: 5)
                .offset(y: 5)
            Text(text)
                .font(DS.font(DS.fontCaption, weight: .medium))
                .foregroundColor(DS.textSecondary)
        }
    }

    // MARK: - Mode Toggle Bar

    private var modeToggleBar: some View {
        HStack(spacing: 0) {
            modeTab(label: "SETUP", isActive: !showPerformanceView, activeColor: DS.success) {
                showPerformanceView = false
            }
            modeTab(label: "PERFORM", isActive: showPerformanceView, activeColor: DS.warning) {
                showPerformanceView = true
            }

            Button(action: { showSettings = true }) {
                Image(systemName: "gearshape")
                    .font(DS.font(11))
                    .foregroundColor(DS.textSecondary)
                    .frame(width: 32)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.plain)
            .help("Settings (Cmd+,)")
        }
        .overlay(
            Rectangle().fill(DS.border).frame(height: DS.dividerHeight),
            alignment: .bottom
        )
    }

    private func modeTab(label: String, isActive: Bool, activeColor: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 0) {
                Text(label)
                    .font(DS.font(DS.fontBody, weight: .bold))
                    .foregroundColor(isActive ? DS.textPrimary : DS.textTertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)

                Rectangle()
                    .fill(isActive ? activeColor : Color.clear)
                    .frame(height: 2)
            }
        }
        .buttonStyle(.plain)
        .animation(DS.stateTransition, value: isActive)
    }

    // MARK: - Keyboard Shortcut Handler
    //
    // Human-centric hotkey map: all major actions reachable without mouse.
    // Returns true if the event was consumed (prevents further propagation).

    private func handleKeyEvent(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let hasCmd = flags.contains(.command)
        let hasShift = flags.contains(.shift)
        let noMod = flags.isEmpty
        let key = event.charactersIgnoringModifiers ?? ""

        // Cmd+, -- Settings
        if hasCmd && key == "," {
            showSettings = true
            return true
        }

        // Tab -- Toggle SETUP / PERFORM
        if noMod && event.keyCode == 48 { // Tab key
            showPerformanceView.toggle()
            return true
        }

        // Space -- Transport toggle (Start/Stop)
        if noMod && event.keyCode == 49 { // Space
            if engine.bridgeProcess.state == .running || engine.isProcessing {
                engine.toggleProcessing()
            }
            return true
        }

        // Escape -- Panic (force stop)
        if noMod && event.keyCode == 53 { // Escape
            if engine.isProcessing { engine.stopProcessing() }
            return true
        }

        // R -- Master Recording toggle
        if noMod && key == "r" {
            engine.toggleMasterRecording()
            return true
        }

        // M -- Mute focus lane
        if noMod && key == "m" {
            if let lane = engine.focusLane {
                lane.isMuted.toggle()
                engine.updateLaneMixerState()
            }
            return true
        }

        // S -- Solo focus lane
        if noMod && key == "s" {
            if let lane = engine.focusLane {
                lane.isSoloed.toggle()
                engine.updateLaneMixerState()
            }
            return true
        }

        // F -- Spectral Freeze toggle
        if noMod && key == "f" {
            engine.focusLane?.spectralFreezeActive.toggle()
            return true
        }

        // [ and ] -- Navigate focus lane (previous / next)
        if noMod && key == "[" {
            navigateFocusLane(direction: -1)
            return true
        }
        if noMod && key == "]" {
            navigateFocusLane(direction: 1)
            return true
        }

        // 1-8 -- Select scene (A-side)
        if noMod, let digit = Int(key), digit >= 1 && digit <= 8 {
            let idx = digit - 1
            if idx < engine.sceneBank.scenes.count {
                engine.crossfaderSceneAIndex = idx
                engine.applyScene(at: idx)
                engine.crossfaderPosition = 0
            }
            return true
        }

        // Shift+1-8 -- Select scene (B-side)
        // Use charactersIgnoringModifiers because Shift+1 produces "!" on US keyboards.
        if hasShift, let digit = Int(key), digit >= 1 && digit <= 8 {
            let idx = digit - 1
            if idx < engine.sceneBank.scenes.count {
                engine.crossfaderSceneBIndex = idx
                engine.crossfaderPosition = 1
            }
            return true
        }

        // . (period) -- Manual step advance
        if noMod && key == "." {
            let chain = engine.stepGrid.chainLength
            guard chain > 0 else { return true }
            let next = (engine.stepGrid.currentStepIndex + 1) % chain
            var grid = engine.stepGrid
            grid.currentStepIndex = next
            engine.stepGrid = grid
            engine.applyCurrentStepLocks()
            return true
        }

        // , (comma) and Shift+, / Shift+. -- Chain length -/+
        if noMod && key == "," {
            engine.stepGrid.chainLength = max(
                LRConstants.chainLengthRange.lowerBound,
                engine.stepGrid.chainLength - 1
            )
            return true
        }

        // Up / Down -- BPM +/- 10 (when in time mode)
        if noMod && event.keyCode == 126 { // Up arrow
            if engine.stepGrid.advanceMode == .time {
                var grid = engine.stepGrid
                grid.stepTimeBPM = min(grid.stepTimeBPM + 10, LRConstants.stepTimeBPMRange.upperBound)
                engine.stepGrid = grid
                engine.syncStepTimer()
            }
            return true
        }
        if noMod && event.keyCode == 125 { // Down arrow
            if engine.stepGrid.advanceMode == .time {
                var grid = engine.stepGrid
                grid.stepTimeBPM = max(grid.stepTimeBPM - 10, LRConstants.stepTimeBPMRange.lowerBound)
                engine.stepGrid = grid
                engine.syncStepTimer()
            }
            return true
        }

        // Left / Right -- Crossfader nudge
        if noMod && event.keyCode == 123 { // Left arrow
            engine.crossfaderPosition = max(0, engine.crossfaderPosition - 0.05)
            engine.applyCrossfader()
            return true
        }
        if noMod && event.keyCode == 124 { // Right arrow
            engine.crossfaderPosition = min(1, engine.crossfaderPosition + 0.05)
            engine.applyCrossfader()
            return true
        }

        // Shift+. -- Chain length +
        if hasShift && key == "." {
            engine.stepGrid.chainLength = min(
                LRConstants.chainLengthRange.upperBound,
                engine.stepGrid.chainLength + 1
            )
            return true
        }

        return false
    }

    private func navigateFocusLane(direction: Int) {
        guard !engine.lanes.isEmpty else { return }
        let currentIdx = engine.lanes.firstIndex(where: { $0.id == engine.focusLaneId }) ?? 0
        let nextIdx = (currentIdx + direction + engine.lanes.count) % engine.lanes.count
        engine.focusLaneId = engine.lanes[nextIdx].id
    }
}

// MARK: - Key Event Handler (NSViewRepresentable)
//
// Installs a local key-down monitor on the NSView hierarchy.
// Returns true from the handler to consume the event.

private struct KeyEventHandler: NSViewRepresentable {

    let handler: (NSEvent) -> Bool

    func makeNSView(context: Context) -> KeyEventNSView {
        let view = KeyEventNSView()
        view.handler = handler
        return view
    }

    func updateNSView(_ nsView: KeyEventNSView, context: Context) {
        nsView.handler = handler
    }
}

/// First-responder NSView that captures keyDown for the hotkey system.
/// Accepts first-responder status so the window routes key events here.
private final class KeyEventNSView: NSView {

    var handler: ((NSEvent) -> Bool)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if handler?(event) == true { return }
        super.keyDown(with: event)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            self?.window?.makeFirstResponder(self)
        }
    }
}

// MARK: - Settings View
//
// Configuration, keyboard shortcut reference, and MIDI CC map.
// Three-tab layout: CONFIG, SHORTCUTS, MIDI.

private struct SettingsView: View {

    @ObservedObject var engine: NeuralEngine

    @AppStorage(LRConstants.ModelConfig.userDefaultsKey)
    private var customModelPath: String = ""

    @Environment(\.dismiss) private var dismiss

    private let defaultPath = LRConstants.ModelConfig.appSupportModelsDir.path

    enum SettingsTab: String, CaseIterable { case config, shortcuts, midi }
    @State private var selectedTab: SettingsTab = .config
    @State private var midiLearnTarget: ControlParameter?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DS.spacingMD) {
                Text("SETTINGS")
                    .font(DS.font(DS.fontTitle, weight: .bold))
                    .foregroundColor(DS.textPrimary)
                Spacer()
                settingsTabPicker
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, DS.spacingMD)

            LRDivider()

            ScrollView {
                VStack(alignment: .leading, spacing: DS.spacingLG) {
                    switch selectedTab {
                    case .config:    configPanel
                    case .shortcuts: shortcutsPanel
                    case .midi:      midiPanel
                    }
                }
                .padding(20)
            }

            LRDivider()

            HStack {
                Text("(c) 2026 Leonardo Lambertini // [ U N B R A N D E D ]")
                    .font(DS.font(DS.fontCaption2))
                    .foregroundColor(DS.textDisabled)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, DS.spacingMD)
        }
        .frame(width: 600, height: 520)
        .background(DS.surfaceOverlay)
    }

    private var settingsTabPicker: some View {
        HStack(spacing: 2) {
            ForEach(SettingsTab.allCases, id: \.self) { tab in
                Button(action: { selectedTab = tab }) {
                    Text(tab.rawValue.uppercased())
                        .font(DS.font(DS.fontCaption, weight: .bold))
                        .foregroundColor(selectedTab == tab ? .black : DS.textTertiary)
                        .padding(.horizontal, DS.spacingMD)
                        .padding(.vertical, DS.spacingXS)
                        .background(selectedTab == tab ? DS.success.opacity(0.7) : Color.clear)
                        .overlay(RoundedRectangle(cornerRadius: DS.radiusSM)
                            .stroke(selectedTab == tab ? DS.success.opacity(0.5) : DS.border, lineWidth: 1))
                        .cornerRadius(DS.radiusSM)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Config Panel

    private var configPanel: some View {
        VStack(alignment: .leading, spacing: DS.spacingLG) {
            VStack(alignment: .leading, spacing: DS.spacingMD) {
                Text("ACE-Step Model Path")
                    .font(DS.font(DS.fontBody, weight: .semibold))
                    .foregroundColor(DS.textSecondary)

                HStack(spacing: DS.spacingMD) {
                    TextField("Default: \(defaultPath)", text: $customModelPath)
                        .font(DS.font(11))
                        .textFieldStyle(.roundedBorder)

                    Button("Browse...") { browseForModelPath() }
                        .font(DS.font(DS.fontBody))

                    Button("Reset") { customModelPath = "" }
                        .font(DS.font(DS.fontBody))
                        .disabled(customModelPath.isEmpty)
                }

                Text(resolvedPathDescription)
                    .font(DS.font(DS.fontCaption))
                    .foregroundColor(DS.textTertiary)
                    .lineLimit(2)
            }

            LRDivider()

            HStack {
                Text("Bridge Port")
                    .font(DS.font(DS.fontBody, weight: .semibold))
                    .foregroundColor(DS.textSecondary)
                Spacer()
                Text("\(LRConstants.ACEBridge.defaultPort)")
                    .font(DS.font(11))
                    .foregroundColor(DS.textPrimary.opacity(0.7))
            }

            HStack {
                Text("Sample Rate")
                    .font(DS.font(DS.fontBody, weight: .semibold))
                    .foregroundColor(DS.textSecondary)
                Spacer()
                Text("48000 Hz / Stereo")
                    .font(DS.font(11))
                    .foregroundColor(DS.textPrimary.opacity(0.7))
            }

            HStack {
                Text("Version")
                    .font(DS.font(DS.fontBody, weight: .semibold))
                    .foregroundColor(DS.textSecondary)
                Spacer()
                Text(appVersion)
                    .font(DS.font(11))
                    .foregroundColor(DS.textPrimary.opacity(0.7))
            }
        }
    }

    // MARK: - Shortcuts Panel

    private var shortcutsPanel: some View {
        VStack(alignment: .leading, spacing: DS.spacingLG) {
            Text("All controls respond to scroll wheel and trackpad. Knobs respond to vertical drag.")
                .font(DS.font(DS.fontCaption))
                .foregroundColor(DS.textTertiary)

            shortcutSection("TRANSPORT", shortcuts: [
                ("Space", "Start / Stop engine"),
                ("Escape", "Panic -- force stop all lanes"),
                ("R", "Toggle master recording"),
            ])

            shortcutSection("NAVIGATION", shortcuts: [
                ("Tab", "Switch between SETUP and PERFORM views"),
                ("Cmd + ,", "Open Settings"),
                ("[", "Focus previous lane"),
                ("]", "Focus next lane"),
            ])

            shortcutSection("FOCUS LANE", shortcuts: [
                ("M", "Mute / unmute focus lane"),
                ("S", "Solo / unsolo focus lane"),
                ("F", "Toggle spectral freeze"),
            ])

            shortcutSection("SCENES", shortcuts: [
                ("1 -- 8", "Load scene to A-side"),
                ("Shift + 1 -- 8", "Load scene to B-side"),
                ("Left / Right", "Nudge crossfader A / B"),
            ])

            shortcutSection("SEQUENCER", shortcuts: [
                (".", "Manual step advance (TAP)"),
                (",", "Decrease chain length"),
                ("Shift + .", "Increase chain length"),
                ("Up / Down", "BPM +/- 10 (TIME mode)"),
            ])
        }
    }

    private func shortcutSection(_ title: String, shortcuts: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: DS.spacingSM) {
            Text(title)
                .font(DS.font(DS.fontCaption, weight: .bold))
                .foregroundColor(DS.success.opacity(0.7))
            ForEach(shortcuts, id: \.0) { key, desc in
                HStack(spacing: DS.spacingMD) {
                    Text(key)
                        .font(DS.font(DS.fontCaption, weight: .bold))
                        .foregroundColor(DS.textPrimary)
                        .frame(width: 120, alignment: .leading)
                        .padding(.vertical, 2)
                        .padding(.horizontal, DS.spacingSM)
                        .background(Color.white.opacity(0.05))
                        .cornerRadius(DS.radiusSM)
                    Text(desc)
                        .font(DS.font(DS.fontCaption))
                        .foregroundColor(DS.textSecondary)
                }
            }
        }
    }

    // MARK: - MIDI Panel

    private var midiPanel: some View {
        VStack(alignment: .leading, spacing: DS.spacingLG) {
            VStack(alignment: .leading, spacing: DS.spacingSM) {
                Text("MIDI INPUT STATUS")
                    .font(DS.font(DS.fontCaption, weight: .bold))
                    .foregroundColor(DS.success.opacity(0.7))
                Text("Latent Resonator listens on all connected MIDI sources. CC messages are routed to the focus lane. Connect any class-compliant USB or network MIDI controller.")
                    .font(DS.font(DS.fontCaption))
                    .foregroundColor(DS.textTertiary)
            }

            LRDivider()

            VStack(alignment: .leading, spacing: DS.spacingSM) {
                HStack {
                    Text("CC MAP -- FOCUS LANE ROUTING")
                        .font(DS.font(DS.fontCaption, weight: .bold))
                        .foregroundColor(DS.success.opacity(0.7))
                    Spacer()
                    Button("RESET MAP") {
                        engine.midiInput.resetCCMap()
                        midiLearnTarget = nil
                    }
                    .font(DS.font(DS.fontCaption2, weight: .bold))
                    .foregroundColor(DS.textTertiary)
                    .buttonStyle(.plain)
                }
                Text("All CC values are scaled linearly to the parameter range. Toggle parameters: CC < 64 = OFF, CC >= 64 = ON. Tap LEARN to assign a CC.")
                    .font(DS.font(DS.fontCaption))
                    .foregroundColor(DS.textTertiary)
            }

            midiCCTable
        }
        .onAppear {
            engine.midiInput.onLearnComplete = { midiLearnTarget = nil }
        }
    }

    private var midiCCTable: some View {
        VStack(spacing: 1) {
            midiCCHeaderRow
            ForEach(ControlParameter.allCases, id: \.rawValue) { param in
                midiCCParamRow(param)
            }
        }
    }

    private var midiCCHeaderRow: some View {
        HStack(spacing: 0) {
            Text("CC")
                .font(DS.font(DS.fontCaption, weight: .bold))
                .foregroundColor(DS.textPrimary)
                .frame(width: 40, alignment: .leading)
            Text("PARAMETER")
                .font(DS.font(DS.fontCaption, weight: .bold))
                .foregroundColor(DS.textPrimary)
                .frame(width: 150, alignment: .leading)
            Text("RANGE")
                .font(DS.font(DS.fontCaption, weight: .bold))
                .foregroundColor(DS.textPrimary)
                .frame(width: 100, alignment: .leading)
            Spacer()
            Text("LEARN")
                .font(DS.font(DS.fontCaption, weight: .bold))
                .foregroundColor(DS.textPrimary)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, DS.spacingSM)
        .background(Color.white.opacity(0.05))
    }

    private func midiCCParamRow(_ param: ControlParameter) -> some View {
        let ccForParam = engine.midiInput.ccMap.first(where: { $0.value == param })?.key
        let isLearning = midiLearnTarget == param
        return HStack(spacing: 0) {
            Text(ccForParam.map { "\($0)" } ?? "--")
                .font(DS.font(DS.fontCaption, weight: .medium))
                .foregroundColor(DS.success.opacity(0.8))
                .frame(width: 40, alignment: .leading)
            Text(param.rawValue.uppercased())
                .font(DS.font(DS.fontCaption, weight: .medium))
                .foregroundColor(DS.textSecondary)
                .frame(width: 150, alignment: .leading)
            Text(param.isToggle ? "OFF / ON" : formatRange(param.floatRange))
                .font(DS.font(DS.fontCaption))
                .foregroundColor(DS.textTertiary)
                .frame(width: 100, alignment: .leading)
            Spacer()
            Button(isLearning ? "..." : "LEARN") {
                if isLearning {
                    engine.midiInput.cancelLearn()
                    midiLearnTarget = nil
                } else {
                    midiLearnTarget = param
                    engine.midiInput.startLearn(for: param)
                }
            }
            .font(DS.font(DS.fontCaption2, weight: .bold))
            .foregroundColor(isLearning ? DS.warning : DS.info.opacity(0.6))
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, DS.spacingSM)
    }

    private func formatRange(_ range: (Float, Float)?) -> String {
        guard let (lo, hi) = range else { return "--" }
        if lo == 0 && hi == 1 { return "0.0 -- 1.0" }
        return String(format: "%.1f -- %.1f", lo, hi)
    }

    // MARK: - Helpers

    private var resolvedPathDescription: String {
        if customModelPath.isEmpty {
            return "Using default: \(defaultPath)"
        }
        let fm = FileManager.default
        if fm.fileExists(atPath: customModelPath) {
            return "Custom path (exists)"
        }
        return "Custom path (directory not found -- will fall back to default)"
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "\(version) (\(build))"
    }

    private func browseForModelPath() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select the directory containing ACE-Step model weights"
        panel.prompt = "Select"

        if panel.runModal() == .OK, let url = panel.url {
            customModelPath = url.path
        }
    }
}
