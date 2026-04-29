import SwiftUI
import AppKit

// MARK: - Root View (Canvas vs Performance)
//
// One window. Native Max/Envion-style canvas is the home view: every
// node renders its own panel, cables draw between port chips, and a
// LOCK/UNLOCK toggle gates editing without changing what you see.
// PERFORM mode keeps the Motherbase scene/sequencer board accessible
// as a secondary surface — eventually it will fold into the canvas as
// floating panels.
//
// The graph is the source of truth. The sound flows through nodes.

private typealias DS = LRConstants.DS

enum AppMode: String {
    case canvas
    case perform
}

struct RootView: View {

    @ObservedObject var engine: NeuralEngine
    @State private var currentMode: AppMode = .canvas
    @State private var canvasLockMode: PatchLockMode = .unlocked
    @State private var showModeTransitionAlert: Bool = false
    @AppStorage("LatentResonator.hasSeenOnboarding") private var hasSeenOnboarding = false
    @State private var showOnboarding = false

    var body: some View {
        VStack(spacing: 0) {
            modeToggleBar
            switch currentMode {
            case .canvas:
                PatchCanvasView(engine: engine, lockMode: $canvasLockMode)
            case .perform:
                PerformanceMotherbaseView(engine: engine)
            }
        }
        .sheet(isPresented: $showOnboarding) {
            onboardingSheet
        }
            .alert("ENTERING PERFORM MODE", isPresented: $showModeTransitionAlert) {
            Button("CONTINUE", role: .destructive) {
                engine.stopProcessing()
                currentMode = .perform
            }
            Button("CANCEL", role: .cancel) {}
        } message: {
            Text(
                "Entering live performance mode. PATCH graph continues running -- "
                + "scenes and crossfader control the performance."
            )
        }
        .background(KeyEventHandler(handler: handleKeyEvent))
        .onChange(of: currentMode) { _, newMode in
            if newMode == .perform {
                // v2.0: Scene sync is automatic via NodeGraph observation
                // Scenes capture current graph state when switching to perform mode

                // Restart bridge with ultra profile for low-latency inference
                if engine.bridgeProcess.state == .running {
                    DispatchQueue.global(qos: .userInitiated).async {
                        engine.bridgeProcess.terminateServer()
                        Thread.sleep(forTimeInterval: 0.5)
                        _ = engine.bridgeProcess.switchProfile(to: .ultra)
                        engine.bridgeProcess.launchServer()
                    }
                }
            }
        }
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
                onboardingBullet("PATCH mode: build sounds with the node graph (default)")
                onboardingBullet("PERFORM mode: live scenes, crossfader, step sequencer")
                onboardingBullet("Right-click PATCH canvas to add nodes")
                onboardingBullet("Press SPACE to start/stop the neural feedback loop")
                onboardingBullet("TAB cycles between PATCH ↔ PERFORM")
                onboardingBullet("Cmd+, for full shortcut list")
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
        .background(
            LinearGradient(
                colors: [DS.titanioTop, DS.titanioBottom],
                startPoint: .top,
                endPoint: .bottom
            )
        )
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

    // MARK: - Patch View with Terminal

    @State private var showTerminal = true
    
    private var patchViewWithTerminal: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                // Header explaining PATCH mode
                patchModeHeader
                    .frame(height: 40)
                LRDivider()
                
                // Node graph editor WebView
                PatchEditorView(nodeGraph: engine.nodeGraph, aceBridge: engine.aceBridge)
                    .frame(height: showTerminal ? geometry.size.height - 240 : geometry.size.height - 40)
                
                if showTerminal {
                    LRDivider()
                    
                    // Terminal console
                    TerminalConsoleView(bridgeProcess: engine.bridgeProcess)
                        .frame(height: 200)
                }
            }
        }
    }
    
    private var patchModeHeader: some View {
        HStack(spacing: DS.spacingMD) {
            HStack(spacing: DS.spacingSM) {
                Text("PATCH MODE")
                    .font(DS.font(DS.fontCaption, weight: .bold))
                    .foregroundColor(.purple)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.purple.opacity(0.15))
                    .cornerRadius(2)
                
                Text("Visual Signal Routing")
                    .font(DS.font(DS.fontBody, weight: .semibold))
                    .foregroundColor(DS.textSecondary)
            }
            
            Spacer()
            
            HStack(spacing: DS.spacingSM) {
                Text("\(engine.nodeGraph.nodes.count) nodes")
                    .font(DS.font(DS.fontCaption))
                    .foregroundColor(DS.textTertiary)
                Text("•")
                    .foregroundColor(DS.textTertiary)
                Text("\(engine.nodeGraph.edges.count) connections")
                    .font(DS.font(DS.fontCaption))
                    .foregroundColor(DS.textTertiary)
            }
            
            Spacer()
            
            HStack(spacing: DS.spacingSM) {
                Text("Right-click canvas to add nodes")
                    .font(DS.font(DS.fontCaption))
                    .foregroundColor(DS.neonTurquesa)
                Text("→ Then go to PERFORM to play")
                    .font(DS.font(DS.fontCaption))
                    .foregroundColor(DS.textTertiary)
            }
        }
        .padding(.horizontal, DS.spacingXL)
        .background(DS.surfaceSubtle)
    }

    // MARK: - Mode Toggle Bar

    private var modeToggleBar: some View {
        HStack(spacing: 0) {
            modeTab(label: "CANVAS", isActive: currentMode == .canvas, activeColor: DS.neonTurquesa) {
                if currentMode == .perform && engine.isProcessing {
                    engine.processingStartedInPerformMode = true
                }
                currentMode = .canvas
            }
            .help("Patch canvas -- build and play. Toggle UNLOCK / LOCK in the top-right to switch between editing and live performance (Tab).")

            modeTab(label: "PERFORM", isActive: currentMode == .perform, activeColor: DS.neonAmbar) {
                requestPerformMode()
            }
            .help("Motherbase view -- scenes, crossfader, step sequencer (Tab)")
            
            Spacer()
            
            // START/STOP AUDIO BUTTON - visible control
            Button(action: {
                engine.toggleProcessing(initiatedFromPerformMode: currentMode == .perform)
            }) {
                HStack(spacing: 4) {
                    Image(systemName: engine.isProcessing ? "stop.fill" : "play.fill")
                    Text(engine.isProcessing ? "STOP" : "START")
                        .font(.system(size: 12, weight: .bold))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(engine.isProcessing ? Color.red : Color.green)
                .foregroundColor(.white)
                .cornerRadius(4)
            }
            .buttonStyle(PlainButtonStyle())
            .padding(.trailing, 8)
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
        let hasShift = flags.contains(.shift)
        let noMod = flags.isEmpty
        let key = event.charactersIgnoringModifiers ?? ""

        // Tab -- Cycle through modes: CANVAS ↔ PERFORM
        if noMod && event.keyCode == 48 {
            switch currentMode {
            case .canvas:
                requestPerformMode()
            case .perform:
                if engine.isProcessing { engine.processingStartedInPerformMode = true }
                currentMode = .canvas
            }
            return true
        }

        // Space -- Transport toggle (Start/Stop)
        if noMod && event.keyCode == 49 {
            // Write to log file directly
            let logPath = ("~/Library/Application Support/LatentResonator/debug.log" as NSString).expandingTildeInPath
            let timestamp = ISO8601DateFormatter().string(from: Date())
            let logMsg = "[\(timestamp)] [RootView:handleKeyEvent] SPACEBAR DETECTED - calling toggleProcessing\n"
            if let handle = FileHandle(forWritingAtPath: logPath) {
                handle.seekToEndOfFile()
                handle.write(logMsg.data(using: .utf8)!)
                handle.closeFile()
            } else {
                try? logMsg.write(toFile: logPath, atomically: false, encoding: .utf8)
            }
            
            // FIX: Always toggle processing when spacebar is pressed
            engine.toggleProcessing(initiatedFromPerformMode: currentMode == .perform)
            return true
        }

        // Escape -- Panic (force stop)
        if noMod && event.keyCode == 53 {
            if engine.isProcessing { engine.stopProcessing() }
            return true
        }

        // R -- Master Recording toggle
        if noMod && key == "r" {
            engine.toggleMasterRecording()
            return true
        }

        // M -- Mute focus macro
        if noMod && key == "m" {
            if let macro = engine.focusMacro {
                let current = macro.getParam("isMuted", default: false)
                macro.setParam("isMuted", value: !current)
                engine.updateMacroMixerState()
            }
            return true
        }

        // S -- Solo focus macro
        if noMod && key == "s" {
            if let macro = engine.focusMacro {
                let current = macro.getParam("isSoloed", default: false)
                macro.setParam("isSoloed", value: !current)
                engine.updateMacroMixerState()
            }
            return true
        }

        // F -- Spectral Freeze toggle
        if noMod && key == "f" {
            if let macro = engine.focusMacro {
                let current = macro.getParam("spectralFreezeActive", default: false)
                macro.setParam("spectralFreezeActive", value: !current)
            }
            return true
        }

        // [ and ] -- Navigate focus macro (previous / next)
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
        if hasShift, let digit = Int(key), digit >= 1 && digit <= 8 {
            let idx = digit - 1
            if idx < engine.sceneBank.scenes.count {
                engine.crossfaderSceneBIndex = idx
                engine.crossfaderPosition = 1
            }
            return true
        }

        // . (period) -- Manual step advance (focus sequencer only)
        if noMod && key == "." {
            engine.focusSequencerNode?.advanceManually()
            return true
        }

        // , (comma) -- Chain length - (focus sequencer)
        if noMod && key == "," {
            guard let sequencer = engine.focusSequencerNode else { return true }
            sequencer.chainLength = max(LRConstants.chainLengthRange.lowerBound, sequencer.chainLength - 1)
            return true
        }

        // Up / Down -- BPM +/- 10 (when in time mode, focus sequencer)
        if noMod && event.keyCode == 126 {
            guard let sequencer = engine.focusSequencerNode else { return true }
            if sequencer.advanceMode == .time {
                sequencer.stepTimeBPM = min(sequencer.stepTimeBPM + 10, LRConstants.stepTimeBPMRange.upperBound)
                engine.syncStepTimer()
            }
            return true
        }
        if noMod && event.keyCode == 125 {
            guard let sequencer = engine.focusSequencerNode else { return true }
            if sequencer.advanceMode == .time {
                sequencer.stepTimeBPM = max(sequencer.stepTimeBPM - 10, LRConstants.stepTimeBPMRange.lowerBound)
                engine.syncStepTimer()
            }
            return true
        }

        // Left / Right -- Crossfader nudge
        if noMod && event.keyCode == 123 {
            engine.crossfaderPosition = max(0, engine.crossfaderPosition - 0.05)
            engine.applyCrossfader()
            return true
        }
        if noMod && event.keyCode == 124 {
            engine.crossfaderPosition = min(1, engine.crossfaderPosition + 0.05)
            engine.applyCrossfader()
            return true
        }

        // Shift+. -- Chain length + (focus sequencer)
        if hasShift && key == "." {
            guard let sequencer = engine.focusSequencerNode else { return true }
            sequencer.chainLength = min(LRConstants.chainLengthRange.upperBound, sequencer.chainLength + 1)
            return true
        }

        return false
    }

    private func requestPerformMode() {
        if currentMode == .perform { return }
        if engine.isProcessing && !engine.processingStartedInPerformMode {
            showModeTransitionAlert = true
        } else {
            currentMode = .perform
        }
    }

    private func navigateFocusLane(direction: Int) {
        // v2.0: Navigate through MacroNodes instead of lanes
        let macros = engine.macroNodes
        guard !macros.isEmpty else { return }
        let currentIdx = macros.firstIndex(where: { $0.id == engine.focusMacroId }) ?? 0
        let nextIdx = (currentIdx + direction + macros.count) % macros.count
        engine.focusMacroId = macros[nextIdx].id
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

struct LRSettingsView: View {

    @ObservedObject var engine: NeuralEngine

    @AppStorage(LRConstants.ModelConfig.userDefaultsKey)
    private var customModelPath: String = ""

    @AppStorage(LRConstants.RecordingConfig.userDefaultsKey)
    private var customRecordingDirectory: String = ""

    private let defaultModelPath = LRConstants.ModelConfig.defaultDirectory.path
    private let defaultRecordingPath = LRConstants.RecordingConfig.defaultDirectory.path

    enum SettingsTab: String, CaseIterable { case config, shortcuts, midi, osc }
    @State private var selectedTab: SettingsTab = .config
    @State private var midiLearnTarget: ControlParameter?

    private var localIPAddress: String {
        var address = "unknown"
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return address }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let sa = ptr.pointee.ifa_addr.pointee
            guard sa.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: ptr.pointee.ifa_name)
            guard name == "en0" || name == "en1" else { continue }
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(ptr.pointee.ifa_addr, socklen_t(sa.sa_len),
                        &hostname, socklen_t(hostname.count),
                        nil, 0, NI_NUMERICHOST)
            address = String(cString: hostname)
            break
        }
        return address
    }

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
                    case .osc:       oscPanel
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
            }
            .padding(.horizontal, 20)
            .padding(.vertical, DS.spacingMD)
        }
        .frame(width: 640, height: 560)
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
                    TextField("Default: \(defaultModelPath)", text: $customModelPath)
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

            VStack(alignment: .leading, spacing: DS.spacingMD) {
                Text("Recording Output Directory")
                    .font(DS.font(DS.fontBody, weight: .semibold))
                    .foregroundColor(DS.textSecondary)

                HStack(spacing: DS.spacingMD) {
                    TextField("Default: \(defaultRecordingPath)", text: $customRecordingDirectory)
                        .font(DS.font(11))
                        .textFieldStyle(.roundedBorder)

                    Button("Browse...") { browseForRecordingPath() }
                        .font(DS.font(DS.fontBody))

                    Button("Reset") { customRecordingDirectory = "" }
                        .font(DS.font(DS.fontBody))
                        .disabled(customRecordingDirectory.isEmpty)
                }

                Text(resolvedRecordingPathDescription)
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

            HStack {
                Text("Inference Device")
                    .font(DS.font(DS.fontBody, weight: .semibold))
                    .foregroundColor(DS.textSecondary)
                Spacer()
                HStack(spacing: DS.spacingSM) {
                    Circle()
                        .fill(inferenceDeviceColor)
                        .frame(width: DS.dotMD, height: DS.dotMD)
                    Text(inferenceDeviceLabel)
                        .font(DS.font(11))
                        .foregroundColor(inferenceDeviceColor)
                }
            }

        }
    }

    private var inferenceDeviceLabel: String {
        switch engine.aceBridge.remoteDevice.lowercased() {
        case "mps": return "MPS (GPU)"
        case "cuda": return "CUDA (GPU)"
        case "cpu": return "CPU"
        default: return engine.aceBridge.status == .disconnected || engine.aceBridge.status == .error
            ? "—" : engine.aceBridge.remoteDevice
        }
    }

    private var inferenceDeviceColor: Color {
        switch engine.aceBridge.remoteDevice.lowercased() {
        case "mps", "cuda": return DS.success
        case "cpu": return DS.warning
        default: return DS.textTertiary
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
                ("Escape", "Panic -- force stop all macros"),
                ("R", "Toggle master recording"),
            ])

            shortcutSection("NAVIGATION", shortcuts: [
                ("Tab", "Cycle modes: PATCH ↔ PERFORM"),
                ("Cmd + ,", "Open Settings (macOS menu)"),
                ("[", "Focus previous macro"),
                ("]", "Focus next macro"),
            ])

            shortcutSection("FOCUS MACRO", shortcuts: [
                ("M", "Mute / unmute focus macro"),
                ("S", "Solo / unsolo focus macro"),
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
                HStack(spacing: DS.spacingLG) {
                    Text(
                        "Latent Resonator listens on all connected MIDI sources. CC messages are routed to the "
                        + "focus macro. Connect any class-compliant USB, network, or Bluetooth MIDI controller."
                    )
                        .font(DS.font(DS.fontCaption))
                        .foregroundColor(DS.textTertiary)
                }

                HStack(spacing: DS.spacingMD) {
                    HStack(spacing: DS.spacingSM) {
                        Circle()
                            .fill(midiActivityLedColor)
                            .frame(width: DS.dotMD, height: DS.dotMD)
                        Text("MIDI IN")
                            .font(DS.font(DS.fontCaption, weight: .bold))
                            .foregroundColor(DS.textSecondary)
                    }
                    .help("Flashes green when a valid MIDI message is received — proves connection is alive even if mapping is wrong.")

                    Spacer()

                    Button("OPEN MIDI STUDIO") {
                        if let url = URL(string: "file:///System/Applications/Utilities/Audio%20MIDI%20Setup.app") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .font(DS.font(DS.fontCaption, weight: .bold))
                    .foregroundColor(DS.success)
                    .buttonStyle(.plain)
                    .help("Opens macOS Audio MIDI Setup. Go to Window > Show MIDI Studio > Bluetooth to pair devices.")
                }

                Text("For Bluetooth: 1. Click Open MIDI Studio. 2. Click Bluetooth Icon. 3. Connect Device.")
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
                Text(
                    "All CC values are scaled linearly to the parameter range. Toggle parameters: "
                    + "CC < 64 = OFF, CC >= 64 = ON. Tap LEARN to assign a CC."
                )
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

    private var midiActivityLedColor: Color {
        guard let last = engine.midiInput.lastActivityTime else { return DS.textTertiary }
        return Date().timeIntervalSince(last) < 0.3 ? DS.success : DS.textTertiary
    }

    private var oscMonitorLedColor: Color {
        if engine.oscInput.lastTrafficDescription.isEmpty { return DS.textTertiary }
        return engine.oscInput.lastTrafficIsValid ? DS.success : DS.danger
    }

    // MARK: - OSC Panel

    private var oscPanel: some View {
        VStack(alignment: .leading, spacing: DS.spacingLG) {
            VStack(alignment: .leading, spacing: DS.spacingSM) {
                Text("OSC INPUT (UDP + TCP)")
                    .font(DS.font(DS.fontCaption, weight: .bold))
                    .foregroundColor(DS.success.opacity(0.7))
                Text(
                    "Receive Open Sound Control messages over UDP or TCP. "
                    + "The service is advertised via Bonjour so compatible apps "
                    + "(TouchOSC, Pure Data, SuperCollider, or custom OSC clients) can discover it automatically. "
                    + "Messages must use OSC format: /lr/<parameter> <float_value>"
                )
                    .font(DS.font(DS.fontCaption))
                    .foregroundColor(DS.textTertiary)
            }

            LRDivider()

            HStack(spacing: DS.spacingMD) {
                Toggle("ENABLED", isOn: $engine.oscInput.isEnabled)
                    .toggleStyle(.switch)
                    .font(DS.font(DS.fontBody, weight: .semibold))
                    .foregroundColor(DS.textSecondary)
                    .onChange(of: engine.oscInput.isEnabled) { _, _ in
                        engine.oscInput.saveSettings()
                    }

                Spacer()

                Text("PORT")
                    .font(DS.font(DS.fontBody, weight: .semibold))
                    .foregroundColor(DS.textSecondary)

                TextField("9000", value: $engine.oscInput.port, format: .number)
                    .font(DS.font(11))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                    .onSubmit {
                        engine.oscInput.saveSettings()
                        if engine.oscInput.isEnabled {
                            engine.oscInput.start()
                        }
                    }
            }

            if engine.oscInput.isEnabled {
                VStack(alignment: .leading, spacing: DS.spacingSM) {
                    HStack(spacing: DS.spacingMD) {
                        Circle()
                            .fill(DS.success)
                            .frame(width: DS.dotMD, height: DS.dotMD)
                        Text("Listening on UDP+TCP port \(engine.oscInput.port)")
                            .font(DS.font(DS.fontCaption, weight: .medium))
                            .foregroundColor(DS.success.opacity(0.7))
                        Spacer()
                        if !engine.oscInput.lastReceivedAddress.isEmpty {
                            Text("Last: \(engine.oscInput.lastReceivedAddress)")
                                .font(DS.font(DS.fontCaption))
                                .foregroundColor(DS.textTertiary)
                        }
                    }

                    HStack(spacing: DS.spacingMD) {
                        Text("YOUR IP:")
                            .font(DS.font(DS.fontCaption, weight: .bold))
                            .foregroundColor(DS.textTertiary)
                        Text(localIPAddress)
                            .font(DS.font(DS.fontCaption, weight: .bold))
                            .foregroundColor(DS.success)
                            .textSelection(.enabled)
                        Text("-- use this address from your mobile OSC client")
                            .font(DS.font(DS.fontCaption))
                            .foregroundColor(DS.textTertiary)
                    }

                    Text(
                        "If your device cannot connect, check: System Settings > Network > Firewall and "
                        + "allow incoming connections for Latent Resonator."
                    )
                        .font(DS.font(DS.fontCaption))
                        .foregroundColor(DS.warning.opacity(0.6))
                }

                LRDivider()

                VStack(alignment: .leading, spacing: DS.spacingSM) {
                    Text("OSC MONITOR")
                        .font(DS.font(DS.fontCaption, weight: .bold))
                        .foregroundColor(DS.success.opacity(0.7))
                    HStack(spacing: DS.spacingMD) {
                        Circle()
                            .fill(oscMonitorLedColor)
                            .frame(width: DS.dotMD, height: DS.dotMD)
                        Text(oscMonitorLedColor == DS.success ? "Valid OSC" : "Invalid Protocol")
                            .font(DS.font(DS.fontCaption, weight: .medium))
                            .foregroundColor(oscMonitorLedColor.opacity(0.8))
                        Spacer()
                    }
                    if !engine.oscInput.lastTrafficDescription.isEmpty {
                        Text(engine.oscInput.lastTrafficDescription)
                            .font(DS.font(DS.fontCaption2))
                            .foregroundColor(DS.textSecondary)
                            .lineLimit(2)
                    }
                    Text("If LED is Red, your app is sending MIDI/Raw data, not OSC. Check app settings.")
                        .font(DS.font(DS.fontCaption))
                        .foregroundColor(DS.warning.opacity(0.6))
                }
            }

            LRDivider()

            VStack(alignment: .leading, spacing: DS.spacingSM) {
                Text("OSC ADDRESS MAP")
                    .font(DS.font(DS.fontCaption, weight: .bold))
                    .foregroundColor(DS.success.opacity(0.7))
                Text(
                    "All addresses use the /lr/ prefix with a single float argument. Values are clamped to the "
                    + "parameter range. Toggles: >= 0.5 = ON, < 0.5 = OFF."
                )
                    .font(DS.font(DS.fontCaption))
                    .foregroundColor(DS.textTertiary)
            }

            oscAddressTable
        }
    }

    private var oscAddressTable: some View {
        VStack(spacing: 1) {
            HStack(spacing: 0) {
                Text("ADDRESS")
                    .font(DS.font(DS.fontCaption, weight: .bold))
                    .foregroundColor(DS.textPrimary)
                    .frame(width: 200, alignment: .leading)
                Text("PARAMETER")
                    .font(DS.font(DS.fontCaption, weight: .bold))
                    .foregroundColor(DS.textPrimary)
                    .frame(width: 150, alignment: .leading)
                Text("RANGE")
                    .font(DS.font(DS.fontCaption, weight: .bold))
                    .foregroundColor(DS.textPrimary)
                Spacer()
            }
            .padding(.vertical, 2)
            .padding(.horizontal, DS.spacingSM)
            .background(Color.white.opacity(0.05))

            ForEach(ControlParameter.allCases, id: \.rawValue) { param in
                HStack(spacing: 0) {
                    Text("/lr/\(param.rawValue)")
                        .font(DS.font(DS.fontCaption, weight: .medium))
                        .foregroundColor(DS.success.opacity(0.8))
                        .frame(width: 200, alignment: .leading)
                    Text(param.rawValue)
                        .font(DS.font(DS.fontCaption, weight: .medium))
                        .foregroundColor(DS.textSecondary)
                        .frame(width: 150, alignment: .leading)
                    Text(param.isToggle ? "0 / 1" : formatRange(param.floatRange))
                        .font(DS.font(DS.fontCaption))
                        .foregroundColor(DS.textTertiary)
                    Spacer()
                }
                .padding(.vertical, 2)
                .padding(.horizontal, DS.spacingSM)
            }
        }
    }

    // MARK: - Helpers

    private var resolvedPathDescription: String {
        if customModelPath.isEmpty {
            return "Using default: \(defaultModelPath)"
        }
        let fm = FileManager.default
        if fm.fileExists(atPath: customModelPath) {
            return "Custom path (exists)"
        }
        return "Custom path (directory not found -- will fall back to default)"
    }

    private var resolvedRecordingPathDescription: String {
        if customRecordingDirectory.isEmpty {
            return "Recordings save to: \(defaultRecordingPath)"
        }
        let fm = FileManager.default
        if fm.fileExists(atPath: customRecordingDirectory) {
            return "Recordings save to: \(customRecordingDirectory)"
        }
        return "Custom path (directory not found -- will create on first record)"
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

    private func browseForRecordingPath() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select the folder where recordings will be saved"
        panel.prompt = "Select"

        if panel.runModal() == .OK, let url = panel.url {
            customRecordingDirectory = url.path
        }
    }
}

// MARK: - Bluetooth MIDI View (CoreAudioKit wrapper)
//
// Note: CABTMIDICentralViewController is not available in macOS AppKit (only Catalyst/iOS).
// We launch Audio MIDI Setup instead.
