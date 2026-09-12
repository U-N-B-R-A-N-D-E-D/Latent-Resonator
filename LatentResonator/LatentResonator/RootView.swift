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
    /// Reveals the full bridge console (raw server log + profile switch).
    /// Mounted as a popover off `neuralStatusStrip` (see `modeToggleBar`),
    /// reachable in both STAGES and PERFORM modes.
    @State private var showBridgeConsole = false
    @State private var showTopologyReservoir = false
    /// Transient status message surfaced by the canvas/perform shortcuts.
    @State private var statusMessage: String? = nil
    /// Focused node on the canvas; shared with PatchCanvasView so keyboard
    /// shortcuts (Delete, Backspace) can remove it without a mouse gesture.
    @State private var canvasFocusNodeId: UUID? = nil

    var body: some View {
        VStack(spacing: 0) {
            modeToggleBar
            switch currentMode {
            case .canvas:
                PatchCanvasView(
                    engine: engine,
                    lockMode: $canvasLockMode,
                    showTopologyReservoir: $showTopologyReservoir,
                    focusNodeId: $canvasFocusNodeId
                )
            case .perform:
                PerformanceMotherbaseView(
                    engine: engine,
                    showTopologyReservoir: $showTopologyReservoir
                )
            }
        }
        .sheet(isPresented: $showTopologyReservoir) {
            TopologyReservoirSheet(engine: engine, isPresented: $showTopologyReservoir, focusNodeId: $canvasFocusNodeId)
        }
        .sheet(isPresented: $showOnboarding) {
            onboardingSheet
        }
            .alert(modeTransitionAlertTitle, isPresented: $showModeTransitionAlert) {
            Button("CONTINUE", role: .destructive) {
                engine.stopProcessing()
                currentMode = .perform
            }
            Button("CANCEL", role: .cancel) {}
        } message: {
            Text(modeTransitionAlertMessage)
        }
        .background(KeyEventHandler(handler: handleKeyEvent))
        .onChange(of: currentMode) { _, newMode in
            if newMode == .perform {
                // v2.0: Capture current graph state into the A/B scene slots if
                // they are still empty, so the performer has an immediate recall
                // surface without an explicit save gesture.
                engine.syncSetupToScenesOnEnterPerform()
                statusMessage = "Scene captured"

                // Restart bridge with ultra profile for low-latency inference.
                // Skip if already on ultra -- otherwise every CANVAS<->PERFORM
                // bounce kills and relaunches the bridge for no reason, which
                // can cut off an /infer request that's actually in flight.
                // terminateServer() additionally waits (bounded) for any
                // in-flight request to finish before it stops the process.
                if engine.bridgeProcess.state == .running,
                   engine.bridgeProcess.currentProfile != .ultra {
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
        .onChange(of: hasSeenOnboarding) { _, seen in
            // Re-trigger path: the Settings window's "Show onboarding again"
            // button flips the shared `@AppStorage` flag to false. Without
            // this observer the sheet would only reappear on next launch.
            if !seen { showOnboarding = true }
        }
    }

    // MARK: - Onboarding Sheet
    //
    // Envion §3.6 — restriction philosophy. One declarative sentence about the
    // instrument's soul, no didactic wizards or quick-start promises. The
    // reservoir (§3.2) replaces the need for tutorials. Essential keybindings
    // stay because they are undiscoverable otherwise.

    private var onboardingSheet: some View {
        VStack(spacing: DS.spacingLG) {
            Spacer()

            Text("LATENT RESONATOR")
                .font(DS.font(DS.fontHeadline, weight: .bold))
                .foregroundColor(DS.phosphor)
                .tracking(3)

            LRDivider()
                .padding(.horizontal, 40)

            Text("A recursive instrument.\nEach patch is a loop listening to itself.\nListen before you adjust.")
                .font(DS.font(DS.fontBody, weight: .medium))
                .foregroundColor(DS.textPrimary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .padding(.horizontal, 40)

            Spacer()

            Text("SPACE start/stop · TAB stages ↔ perform · K seed · 1-8 scenes · ←/→ crossfade · DEL remove node")
                .font(DS.font(DS.fontCaption2, weight: .regular))
                .foregroundColor(DS.textTertiary)
                .tracking(1)

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

    // MARK: - Mode Toggle Bar

    private var modeToggleBar: some View {
        HStack(spacing: 0) {
            modeTab(label: "STAGES", isActive: currentMode == .canvas, activeColor: DS.neonTurquesa) {
                if currentMode == .perform && engine.isProcessing {
                    engine.processingStartedInPerformMode = true
                }
                currentMode = .canvas
            }
            .help("Signal stages — seed → resonator → output. Toggle UNLOCK / LOCK to edit topology vs play live (Tab).")

            modeTab(label: "PERFORM", isActive: currentMode == .perform, activeColor: DS.neonAmbar) {
                requestPerformMode()
            }
            .help("Motherbase view -- scenes, crossfader, step sequencer (Tab)")
            .overlay(alignment: .topTrailing) {
                // Non-blocking warning: switching modes while ACE-Step is
                // inferring restarts the bridge and may cut the cycle off.
                if engine.aceBridge.isInferInFlight {
                    Text("⏳")
                        .font(.system(size: 9))
                        .offset(x: -4, y: 4)
                        .help("ACE-Step is inferring -- switching modes may interrupt it")
                }
            }

            neuralStatusStrip
                .padding(.horizontal, DS.spacingSM)

            if engine.isProcessing, let reason = engine.lastPipelineStatus.silenceReason {
                silenceBadge(reason: reason)
            }

            Button(action: { showTopologyReservoir = true }) {
                HStack(spacing: 4) {
                    Image(systemName: "square.stack.3d.up")
                        .font(.system(size: 10, weight: .bold))
                    Text("RESERVOIR")
                        .font(DS.font(DS.fontCaption2, weight: .bold))
                }
                .foregroundColor(DS.neonTurquesa)
                .padding(.horizontal, DS.spacingSM)
                .padding(.vertical, 4)
                .background(DS.neonTurquesa.opacity(0.1))
                .cornerRadius(DS.radiusSM)
            }
            .buttonStyle(.plain)
            .help("Load factory topologies from Resources/Topologies")

            if let message = statusMessage {
                Text(message.uppercased())
                    .font(DS.font(DS.fontCaption2, weight: .bold))
                    .foregroundColor(DS.neonAmbar)
                    .transition(.opacity)
                    .task(id: message) {
                        try? await Task.sleep(nanoseconds: 2_500_000_000)
                        statusMessage = nil
                    }
            }

            Spacer()

            // Settings — discoverable entry point (also reachable via Cmd+,).
            // Without this gear the macOS Settings scene is effectively hidden
            // from anyone who doesn't know the system shortcut.
            Button(action: {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }) {
                Image(systemName: "gearshape")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.textSecondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help("Settings — MIDI/OSC, model path, recording (⌘,)")
            .padding(.trailing, DS.spacingSM)

            // START/STOP AUDIO BUTTON — only in STAGES. PERFORM has its own
            // contextual transport (`triggerButton`: ABORT / INITIATE /
            // INITIATING / bridge status) so showing both at once is
            // ambiguous. SPACE works in either mode regardless.
            if currentMode == .canvas {
                // SEED button — manifesto ("listen before you adjust"): START
                // no longer auto-injects the Koenig seed. The performer arms
                // it manually via this button or the K key. Highlighted while
                // armed so the performer can see the loop is now seeded.
                Button(action: {
                    _ = engine.triggerKoenigSeed()
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: engine.anySeedArmed ? "bolt.fill" : "bolt")
                        Text("SEED")
                            .font(DS.font(DS.fontCaption, weight: .bold))
                    }
                    .padding(.horizontal, DS.spacingSM)
                    .padding(.vertical, DS.spacingXS)
                    .background(engine.anySeedArmed ? DS.neonAmbar : DS.panelHollow)
                    .foregroundColor(engine.anySeedArmed ? .black : DS.textSecondary)
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.radiusSM)
                            .stroke(DS.neonAmbar, lineWidth: 1)
                    )
                    .cornerRadius(DS.radiusSM)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 4)
                .help("Arm/disarm Koenig seed (K). START does not auto-inject — listen before you adjust.")

                Button(action: {
                    engine.toggleProcessing(initiatedFromPerformMode: false)
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: engine.isProcessing ? "stop.fill" : "play.fill")
                        Text(engine.isProcessing ? "STOP" : "START")
                            .font(DS.font(DS.fontCaption, weight: .bold))
                    }
                    .padding(.horizontal, DS.spacingMD)
                    .padding(.vertical, DS.spacingXS)
                    .background(engine.isProcessing ? DS.danger : DS.success)
                    .foregroundColor(.black)
                    .cornerRadius(DS.radiusSM)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 8)
            }
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

    // MARK: - Neural Status Strip
    //
    // Always-visible in both CANVAS and PERFORM (lives in the shared
    // `modeToggleBar`, above the mode switch). Answers the two questions
    // the console previously answered alone: is the bridge up, and is
    // ACE-Step actually doing anything right now. Tap to open the full
    // log (`TerminalConsoleView` -- already built, was never mounted).

    private var primaryFeedbackLoop: FeedbackLoopNode? {
        engine.feedbackLoopNodes.first
    }

    private enum BridgeReadiness {
        case offline, loading, passthrough, ready, error

        var label: String {
            switch self {
            case .offline:     return "OFFLINE"
            case .loading:     return "LOADING"
            case .passthrough: return "NO MODEL"
            case .ready:       return "READY"
            case .error:       return "ERROR"
            }
        }
        var color: Color {
            switch self {
            case .offline:     return DS.textTertiary
            case .loading:     return DS.warning
            case .passthrough: return DS.warning
            case .ready:       return DS.success
            case .error:       return DS.danger
            }
        }
    }

    /// Combines `BridgeProcessManager.state` (process lifecycle) and
    /// `ACEStepBridge.status` (health/model) into one legible state --
    /// previously the user had to reconcile two separate, differently-
    /// shaped enums with no single readout.
    private var bridgeReadiness: BridgeReadiness {
        if engine.bridgeProcess.state == .error || engine.aceBridge.status == .error {
            return .error
        }
        if engine.aceBridge.status == .modelLoaded {
            return .ready
        }
        if engine.aceBridge.status == .connected {
            return .passthrough
        }
        switch engine.bridgeProcess.state {
        case .idle:
            return .offline
        case .settingUp, .installing, .launching, .running, .stopping:
            // .running here means the process is alive but the first health
            // check hasn't confirmed connected/modelLoaded yet -- covered by
            // the two early returns above once it does. `.error` is handled
            // by the guard at the top of this computed property.
            return .loading
        case .error:
            return .error
        }
    }

    private var neuralStatusStrip: some View {
        Button(action: { showBridgeConsole = true }) {
            HStack(spacing: DS.spacingSM) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(bridgeReadiness.color)
                        .frame(width: DS.dotSM, height: DS.dotSM)
                    Text("ACE: \(bridgeReadiness.label)")
                        .font(DS.font(DS.fontCaption2, weight: .bold))
                        .foregroundColor(bridgeReadiness.color)
                }

                Rectangle()
                    .fill(DS.border)
                    .frame(width: 1, height: 10)

                inferStatusText
            }
            .padding(.horizontal, DS.spacingSM)
            .padding(.vertical, 4)
            .background(DS.panelHollow)
            .cornerRadius(DS.radiusSM)
        }
        .buttonStyle(.plain)
        .help(neuralStatusHelp)
        .popover(isPresented: $showBridgeConsole) {
            TerminalConsoleView(bridgeProcess: engine.bridgeProcess)
                .frame(width: 460)
        }
    }

    /// A.8: Red pill shown only while processing AND `verifyAudioPipeline()`
    /// found no reason to expect audible output -- e.g. every source's
    /// amplitude is at zero. `startProcessing()` already attempts one
    /// auto-restore before this can appear, so seeing this means either the
    /// user muted a source live (intentional) or restore genuinely couldn't
    /// fix it (no master output, empty plan, etc. -- see `reason`).
    private func silenceBadge(reason: String) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(DS.danger)
                .frame(width: DS.dotSM, height: DS.dotSM)
            Text("SILENT · \(reason)")
                .font(DS.font(DS.fontCaption2, weight: .bold))
                .foregroundColor(DS.danger)
        }
        .padding(.horizontal, DS.spacingSM)
        .padding(.vertical, 4)
        .background(DS.panelHollow)
        .cornerRadius(DS.radiusSM)
        .help("Pipeline is running but not audible (\(reason)). Auto-recovery already ran once at START -- if a source is intentionally muted, this is expected.")
    }

    /// Tooltip for `neuralStatusStrip`. Surfaces the MPS-crash-fallback
    /// reason when relevant so the pill isn't just a color+label with no
    /// explanation -- otherwise "why did it say ERROR / why is it on CPU"
    /// has no answer short of opening the full log popover.
    private var neuralStatusHelp: String {
        if engine.bridgeProcess.mpsCrashLatched {
            let reason = engine.bridgeProcess.lastError ?? "MPS crashed"
            return "\(reason). Click for the full bridge log and performance-profile switch."
        }
        return "Click for the full bridge log and performance-profile switch."
    }

    /// "idle" / "RUNNING 3s" / "✓ landed · iter 4 (2s ago)" / "✗ FAIL: reason (1s ago)".
    /// `TimelineView` re-evaluates every second purely to keep the elapsed /
    /// relative-time text ticking -- it does not poll for new data, the
    /// underlying `@Published` state still drives real updates instantly.
    @ViewBuilder
    private var inferStatusText: some View {
        TimelineView(.periodic(from: .now, by: 1.0)) { context in
            let now = context.date
            if let startedAt = primaryFeedbackLoop?.inferenceStartedAt {
                if engine.isProcessing {
                    Text("⏳ RUNNING \(Int(now.timeIntervalSince(startedAt)))s · cycle ~30s by design")
                        .font(DS.font(DS.fontCaption2, weight: .bold))
                        .foregroundColor(DS.neonAmbar)
                        .lineLimit(1)
                } else {
                    // STOP was pressed mid-cycle. `stopProcessing()` deliberately
                    // leaves the in-flight bridge round-trip running (see its doc
                    // comment -- killing it would waste the inference and the
                    // bridge process is never touched by STOP), so this is NOT a
                    // hang. Say so plainly instead of a bare "RUNNING" that reads
                    // as if the engine were still live.
                    Text("⏸ STOPPED · finishing \(Int(now.timeIntervalSince(startedAt)))s")
                        .font(DS.font(DS.fontCaption2, weight: .bold))
                        .foregroundColor(DS.textTertiary)
                }
            } else {
                switch primaryFeedbackLoop?.lastOutcome ?? .idle {
                case .idle:
                    Text("INFER: idle")
                        .font(DS.font(DS.fontCaption2, weight: .medium))
                        .foregroundColor(DS.textTertiary)
                case .success(let iteration, let at):
                    Text("✓ landed · iter \(iteration) (\(Int(now.timeIntervalSince(at)))s ago)")
                        .font(DS.font(DS.fontCaption2, weight: .bold))
                        .foregroundColor(DS.success)
                case .failure(let reason, let at):
                    Text("✗ FAIL (\(Int(now.timeIntervalSince(at)))s ago): \(reason)")
                        .font(DS.font(DS.fontCaption2, weight: .bold))
                        .foregroundColor(DS.danger)
                        .lineLimit(1)
                }
            }
        }
    }

    // MARK: - Mode Transition Alert Copy

    private var modeTransitionAlertTitle: String {
        engine.aceBridge.isInferInFlight ? "ACE-STEP IS INFERRING" : "ENTERING PERFORM MODE"
    }

    private var modeTransitionAlertMessage: String {
        if engine.aceBridge.isInferInFlight {
            return "An inference cycle is running right now. Entering PERFORM mode restarts the "
                + "bridge for low-latency mode -- it will wait briefly for the current cycle to "
                + "finish, but may cut it off if it runs long. CONTINUE anyway?"
        }
        return "Entering live performance mode. The PATCH graph will stop now -- "
            + "use the INITIATE button in PERFORM to restart audio for the performance."
    }

    // MARK: - Keyboard Shortcut Handler
    //
    // Human-centric hotkey map: all major actions reachable without mouse.
    // Returns true if the event was consumed (prevents further propagation).

    private func handleKeyEvent(_ event: NSEvent) -> Bool {
        // Do not swallow key events while a text field / TextEditor has focus.
        // SPACE (type a space), TAB (focus traversal), ESC (sheet dismiss),
        // and character keys must reach the field editor — otherwise the
        // Reservoir "topology name" field, the OSC port field, and the ACE
        // prompt field are all unusable. This guard lets AppKit route the
        // event to the field editor instead of the hotkey system.
        if NSApp.keyWindow?.firstResponder is NSTextView {
            return false
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let hasShift = flags.contains(.shift)
        let hasCommand = flags.contains(.command)
        let noMod = flags.isEmpty
        let key = event.charactersIgnoringModifiers ?? ""

        // Tab -- Cycle through modes: STAGES ↔ PERFORM
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

        // K -- Arm/disarm Koenig seed (manifesto: "listen before you adjust").
        // START no longer auto-injects the seed; the performer arms it manually.
        // No-op if no KoenigSeedNode / .koenigSeed oscillator exists in the graph.
        if noMod && key == "k" {
            _ = engine.triggerKoenigSeed()
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
                let current = macro.getParam("freezeActive", default: false)
                macro.setParam("freezeActive", value: !current)
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

        // Cmd+Z / Cmd+Shift+Z -- Canvas undo / redo.
        if hasCommand && !hasShift && key == "z" {
            NodeGraphStore.history.undo()
            return true
        }
        if hasCommand && hasShift && key == "z" {
            NodeGraphStore.history.redo()
            return true
        }

        // Cmd+0 -- Zoom to fit the whole patch in the canvas viewport.
        if hasCommand && key == "0" {
            NodeGraphStore.selection.zoomToFitTrigger = UUID()
            return true
        }

        // Cmd+Shift+M -- Toggle the canvas minimap overlay.
        if hasCommand && hasShift && key == "m" {
            NodeGraphStore.selection.showMinimap.toggle()
            statusMessage = NodeGraphStore.selection.showMinimap ? "Minimap ON" : "Minimap OFF"
            return true
        }

        // Cmd+A -- Select all nodes.
        if hasCommand && key == "a" {
            NodeGraphStore.selection.selectedNodeIds = Set(engine.nodeGraph.nodes.keys)
            return true
        }

        // Cmd+C -- Copy selected subgraph to the shared clipboard.
        if hasCommand && key == "c" {
            let selected = NodeGraphStore.selection.selectedNodeIds
            NodeGraphStore.clipboard = engine.nodeGraph.subgraph(for: selected)
            statusMessage = "Copied \(selected.count) node(s)"
            return true
        }

        // Cmd+V -- Paste the clipboard as a new subgraph.
        if hasCommand && key == "v" {
            guard let clipboard = NodeGraphStore.clipboard else { return true }
            let command = PasteSubgraphCommand(subgraph: clipboard, offset: CGPoint(x: 40, y: 40))
            NodeGraphStore.history.execute(command)
            NodeGraphStore.selection.selectedNodeIds = Set(command.pastedNodeIds)
            statusMessage = "Pasted \(command.pastedNodeIds.count) node(s)"
            return true
        }

        // Cmd+D -- Duplicate the current selection.
        if hasCommand && key == "d" {
            let selected = NodeGraphStore.selection.selectedNodeIds
            guard !selected.isEmpty else { return true }
            let subgraph = engine.nodeGraph.subgraph(for: selected)
            let command = PasteSubgraphCommand(subgraph: subgraph, offset: CGPoint(x: 20, y: 20))
            NodeGraphStore.history.execute(command)
            NodeGraphStore.selection.selectedNodeIds = Set(command.pastedNodeIds)
            statusMessage = "Duplicated \(command.pastedNodeIds.count) node(s)"
            return true
        }

        // G -- Toggle snap-to-grid.
        if noMod && key == "g" {
            NodeGraphStore.selection.snapToGrid.toggle()
            statusMessage = NodeGraphStore.selection.snapToGrid ? "Snap to grid ON" : "Snap to grid OFF"
            return true
        }

        // Delete / Forward Delete -- remove the selected canvas nodes (or the
        // focused node if nothing is selected). The master output is always protected.
        if noMod && (event.keyCode == 51 || event.keyCode == 117) {
            let selected = NodeGraphStore.selection.selectedNodeIds
            let idsToRemove = selected.isEmpty ? (canvasFocusNodeId.map { [$0] } ?? []) : Array(selected)
            let deletable = idsToRemove.filter { engine.nodeGraph.nodes[$0]?.nodeType != "master_output" }
            guard !deletable.isEmpty else { return true }
            let commands = deletable.map { RemoveNodeCommand(nodeId: $0, graph: engine.nodeGraph) }
            NodeGraphStore.history.execute(CompoundCommand(commands: commands))
            NodeGraphStore.selection.selectedNodeIds.subtract(deletable)
            if let focus = canvasFocusNodeId, deletable.contains(focus) { canvasFocusNodeId = nil }
            statusMessage = "\(deletable.count) node(s) removed"
            return true
        }

        return false
    }

    private func requestPerformMode() {
        if currentMode == .perform { return }
        // isInferInFlight is checked independently of isProcessing: a Task
        // spawned by FeedbackLoopNode.render() can still be awaiting
        // bridge.infer(...) for several seconds after a STOP -- isProcessing
        // flips false immediately, but the HTTP round-trip doesn't cancel.
        let riskOfInterruptingInference = engine.isProcessing || engine.aceBridge.isInferInFlight
        if riskOfInterruptingInference && !engine.processingStartedInPerformMode {
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

// MARK: - Topology Reservoir Sheet (Envion §3.2)
//
// Lists bundled `Resources/Topologies/*.json` plus the user's saved session.
// One-tap load with destructive confirmation — no new architecture.

struct TopologyReservoirSheet: View {

    @ObservedObject var engine: NeuralEngine
    @Binding var isPresented: Bool
    @Binding var focusNodeId: UUID?

    @State private var pendingLoad: PendingLoad?
    @State private var loadError: String?
    @State private var tagFilter: String = ""
    @State private var saveName: String = ""
    @State private var showSaveField = false

    struct PendingLoad: Identifiable {
        let id = UUID()
        let title: String
        let source: NeuralEngine.TopologyLoadSource
    }

    private var hasSavedSession: Bool {
        NodeGraphStore.hasSavedSession
    }

    private var bundledEntries: [TopologyTemplates.CatalogEntry] {
        filtered(TopologyTemplates.catalog())
    }

    private var userEntries: [TopologyTemplates.CatalogEntry] {
        filtered(NodeGraphStore.userTopologyCatalog())
    }

    private func filtered(_ entries: [TopologyTemplates.CatalogEntry]) -> [TopologyTemplates.CatalogEntry] {
        let q = tagFilter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return entries }
        return entries.filter { entry in
            entry.displayName.lowercased().contains(q)
                || entry.description.lowercased().contains(q)
                || entry.tags.contains(where: { $0.lowercased().contains(q) })
                || entry.fileName.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("TOPOLOGY RESERVOIR")
                    .font(DS.font(DS.fontTitle, weight: .bold))
                    .foregroundColor(DS.textPrimary)
                Spacer()
                Button("CLOSE") { isPresented = false }
                    .font(DS.font(DS.fontCaption, weight: .bold))
                    .foregroundColor(DS.textTertiary)
                    .buttonStyle(.plain)
            }
            .padding(.horizontal, DS.spacingLG)
            .padding(.top, DS.spacingLG)
            .padding(.bottom, DS.spacingMD)

            Text("Factory patches from Resources/Topologies plus your saved patches in Application Support.")
                .font(DS.font(DS.fontCaption))
                .foregroundColor(DS.textTertiary)
                .padding(.horizontal, DS.spacingLG)
                .padding(.bottom, DS.spacingSM)

            HStack(spacing: DS.spacingSM) {
                TextField("Filter by name or tag", text: $tagFilter)
                    .textFieldStyle(.roundedBorder)
                    .font(DS.font(DS.fontCaption))
                Button(showSaveField ? "CANCEL" : "SAVE PATCH") {
                    showSaveField.toggle()
                    if !showSaveField { saveName = "" }
                }
                .font(DS.font(DS.fontCaption, weight: .bold))
                .foregroundColor(DS.neonTurquesa)
                .buttonStyle(.plain)
            }
            .padding(.horizontal, DS.spacingLG)
            .padding(.bottom, DS.spacingSM)

            if showSaveField {
                HStack(spacing: DS.spacingSM) {
                    TextField("Topology name", text: $saveName)
                        .textFieldStyle(.roundedBorder)
                        .font(DS.font(DS.fontCaption))
                    Button("SAVE") { saveCurrentTopology() }
                        .font(DS.font(DS.fontCaption, weight: .bold))
                        .foregroundColor(DS.neonAmbar)
                        .buttonStyle(.plain)
                        .disabled(saveName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.horizontal, DS.spacingLG)
                .padding(.bottom, DS.spacingSM)
            }

            if let loadError {
                Text(loadError)
                    .font(DS.font(DS.fontCaption2, weight: .bold))
                    .foregroundColor(DS.danger)
                    .padding(.horizontal, DS.spacingLG)
                    .padding(.bottom, DS.spacingSM)
            }

            LRDivider()

            ScrollView {
                VStack(spacing: DS.spacingSM) {
                    if hasSavedSession {
                        reservoirRow(
                            title: "Saved Session",
                            subtitle: "Last graph from Application Support",
                            tags: ["session"],
                            accent: DS.neonAmbar
                        ) {
                            pendingLoad = PendingLoad(
                                title: "Saved Session",
                                source: .savedSession
                            )
                        }
                    }

                    if !userEntries.isEmpty {
                        Text("USER SAVED")
                            .font(DS.font(DS.fontCaption2, weight: .bold))
                            .foregroundColor(DS.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, DS.spacingSM)
                        ForEach(userEntries) { entry in
                            reservoirRow(
                                title: entry.displayName,
                                subtitle: entry.description,
                                tags: entry.tags,
                                accent: DS.neonAmbar
                            ) {
                                pendingLoad = PendingLoad(
                                    title: entry.displayName,
                                    source: .userSaved(fileName: entry.fileName)
                                )
                            }
                        }
                    }

                    Text("FACTORY")
                        .font(DS.font(DS.fontCaption2, weight: .bold))
                        .foregroundColor(DS.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, DS.spacingSM)

                    ForEach(bundledEntries) { entry in
                        reservoirRow(
                            title: entry.displayName,
                            subtitle: entry.description,
                            tags: entry.tags,
                            accent: DS.neonTurquesa
                        ) {
                            pendingLoad = PendingLoad(
                                title: entry.displayName,
                                source: .bundled(fileName: entry.fileName)
                            )
                        }
                    }

                    if bundledEntries.isEmpty && userEntries.isEmpty && !hasSavedSession {
                        Text("No topologies match filter.")
                            .font(DS.font(DS.fontCaption))
                            .foregroundColor(DS.textDisabled)
                            .padding(DS.spacingLG)
                    }
                }
                .padding(DS.spacingLG)
            }
        }
        .frame(width: 480, height: 480)
        .background(DS.surfaceOverlay)
        .alert(
            "Replace current patch?",
            isPresented: Binding(
                get: { pendingLoad != nil },
                set: { if !$0 { pendingLoad = nil } }
            ),
            presenting: pendingLoad
        ) { pending in
            Button("Load", role: .destructive) {
                guard let pending = pending else { return }
                do {
                    try engine.loadTopology(from: pending.source)
                    // A topology load is a fresh document: clear editing history,
                    // selection, and focus so the performer starts with a clean slate.
                    NodeGraphStore.history.clear()
                    NodeGraphStore.selection.selectedNodeIds.removeAll()
                    focusNodeId = nil
                    loadError = nil
                    pendingLoad = nil
                    isPresented = false
                } catch {
                    loadError = error.localizedDescription
                    pendingLoad = nil
                }
            }
            Button("Cancel", role: .cancel) {
                pendingLoad = nil
            }
        } message: { pending in
            Text("Loading \"\(pending?.title ?? "")\" replaces the current graph and exposed controls.")
        }
    }

    private func saveCurrentTopology() {
        let trimmed = saveName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            _ = try NodeGraphStore.saveUserTopology(engine.nodeGraph, name: trimmed)
            loadError = nil
            showSaveField = false
            saveName = ""
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func reservoirRow(
        title: String,
        subtitle: String,
        tags: [String],
        accent: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: DS.spacingMD) {
                Rectangle()
                    .fill(accent)
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: DS.spacingXS) {
                    Text(title.uppercased())
                        .font(DS.font(DS.fontCaption, weight: .bold))
                        .foregroundColor(DS.textPrimary)
                    Text(subtitle)
                        .font(DS.font(DS.fontCaption2))
                        .foregroundColor(DS.textTertiary)
                        .lineLimit(2)
                    if !tags.isEmpty {
                        Text(tags.joined(separator: " · "))
                            .font(DS.font(DS.fontCaption2))
                            .foregroundColor(DS.textDisabled)
                    }
                }
                Spacer()
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 14))
                    .foregroundColor(accent.opacity(0.8))
            }
            .padding(DS.spacingMD)
            .background(DS.panelHollow)
            .overlay(
                RoundedRectangle(cornerRadius: DS.radiusSM)
                    .stroke(DS.border, lineWidth: 1)
            )
            .cornerRadius(DS.radiusSM)
        }
        .buttonStyle(.plain)
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

    /// Shared with `RootView` via the same UserDefaults key. Flipping this
    /// to `false` from the Settings window re-triggers the onboarding sheet
    /// in `RootView` through its `.onChange(of: hasSeenOnboarding)`.
    @AppStorage("LatentResonator.hasSeenOnboarding") private var hasSeenOnboarding = false

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

            LRDivider()

            // Re-trigger the onboarding sheet. The flag is persisted in
            // `@AppStorage`, so the only way back after the first launch was
            // clearing UserDefaults by hand — unacceptable for a recursive
            // instrument where the manifesto ("listen before you adjust") is
            // the only orientation a new performer gets. Flipping this
            // shared `@AppStorage` key makes `RootView`'s `.onChange` show
            // the sheet immediately, even from this separate window.
            HStack {
                Text("Onboarding")
                    .font(DS.font(DS.fontBody, weight: .semibold))
                    .foregroundColor(DS.textSecondary)
                Spacer()
                Button("Show onboarding again") {
                    hasSeenOnboarding = false
                }
                .font(DS.font(DS.fontBody))
            }

        }
    }

    private var inferenceDeviceLabel: String {
        switch engine.aceBridge.remoteDevice.lowercased() {
        case "mps": return "MPS (GPU)"
        case "cuda": return "CUDA (GPU)"
        case "cpu":
            // mpsCrashLatched persists for the rest of the session once an
            // MPS bridge has aborted (see BridgeProcessManager) -- surface
            // *why* we're on CPU, not just that we are.
            return engine.bridgeProcess.mpsCrashLatched ? "CPU (MPS FALLBACK)" : "CPU"
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
                ("K", "Arm / disarm Koenig seed"),
            ])

            shortcutSection("NAVIGATION", shortcuts: [
                ("Tab", "Cycle modes: STAGES ↔ PERFORM"),
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

// MARK: - Corpus Machinae materiality cost math (P3.11)

/// Pure cost container for per-inference ecological footprint estimates.
struct MaterialityCost {
    let liGrams: Double
    let waterMl: Double
    let co2Grams: Double
}

extension RootView {
    /// Pure function: estimates lithium, water, and CO2 footprint from
    /// inference duration using the canonical ratios from the EPILOGUE.
    static func materiality(forInferenceMs ms: Double) -> MaterialityCost {
        let kWh = (300.0 * ms / 1000.0) / 3_600_000.0
        return MaterialityCost(
            liGrams: kWh * 0.000714,
            waterMl: kWh * 3.0 * 1000.0,
            co2Grams: kWh * 0.452 * 1000.0
        )
    }
}

// MARK: - Bluetooth MIDI View (CoreAudioKit wrapper)
//
// Note: CABTMIDICentralViewController is not available in macOS AppKit (only Catalyst/iOS).
// We launch Audio MIDI Setup instead.
