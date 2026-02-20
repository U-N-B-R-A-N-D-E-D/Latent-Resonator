import SwiftUI

// MARK: - Latent Resonator View (Multi-Lane Mixer)
//
// Main interface for the Latent Resonator instrument.
// JP-future mecha module aesthetic: titanium surfaces, neon accents.
//
// Layout (mixer-style):
//   +--------------------------------------------------+
//   |  HEADER BAR                                      |
//   |  BRIDGE STATUS                                   |
//   +--------------------------------------------------+
//   |  XY DRIFT PAD (Vectorscope TBI)                  |
//   +--------------------------------------------------+
//   |  +--------+ +--------+ +--------+ +--------+   |
//   |  | DRUMS  | | BASS   | | SYNTH  | | NOISE  |   |
//   |  | strip  | | strip  | | strip  | | strip  |   |
//   |  |  ...   | |  ...   | |  ...   | |  ...   |   |
//   |  +--------+ +--------+ +--------+ +--------+   |
//   |  [+ ADD LANE]                                    |
//   +--------------------------------------------------+
//   |  [INITIATE LOOP] / [ABORT SEQUENCE]              |
//   |  STATUS BAR                                      |
//   +--------------------------------------------------+

private typealias DS = LRConstants.DS

struct LatentResonatorView: View {

    @ObservedObject var engine: NeuralEngine

    // MARK: - Body

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [DS.titanioTop, DS.titanioBottom],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                headerBar
                LRDivider()
                bridgeStatusBar
                LRDivider()

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                        xyDriftPadSection
                        LRDivider()
                        lanesMixerSection
                    }
                }
                .frame(maxHeight: .infinity)

                triggerButton
                statusBar
            }
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: DS.spacingXS) {
                Text("LATENT RESONATOR")
                    .font(DS.font(DS.fontHeadline, weight: .bold))
                    .foregroundColor(DS.textSecondary)
                Text("ACE-CORE // MULTI-LANE STOCHASTIC PROCESSOR")
                    .font(DS.font(DS.fontCaption))
                    .foregroundColor(DS.textTertiary)
            }

            Spacer()

            HStack(spacing: DS.spacingMD) {
                // Master record button
                Button(action: { engine.toggleMasterRecording() }) {
                    HStack(spacing: 3) {
                        Circle()
                            .fill(engine.isMasterRecording ? DS.danger : DS.textDisabled)
                            .frame(width: DS.dotMD, height: DS.dotMD)
                            .shadow(
                                color: engine.isMasterRecording ? DS.danger.opacity(0.6) : .clear,
                                radius: 2
                            )
                        Text("REC")
                            .font(DS.font(DS.fontCaption2, weight: .bold))
                            .foregroundColor(engine.isMasterRecording ? DS.danger : DS.textTertiary)
                    }
                    .padding(.horizontal, DS.togglePaddingH)
                    .padding(.vertical, DS.togglePaddingV)
                    .background(engine.isMasterRecording ? DS.danger.opacity(0.15) : DS.surfaceSubtle)
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.radiusSM)
                            .stroke(
                                engine.isMasterRecording ? DS.danger.opacity(0.5) : DS.border,
                                lineWidth: 1
                            )
                    )
                }
                .buttonStyle(.plain)
                .animation(DS.stateTransition, value: engine.isMasterRecording)
                .help("Master record -- capture the combined output of all lanes to a WAV file (R)")

                Text("\(engine.lanes.count) LANE\(engine.lanes.count == 1 ? "" : "S")")
                    .font(DS.font(DS.fontCaption, weight: .bold))
                    .foregroundColor(DS.neonTurquesa.opacity(0.5))

                Text(engine.isProcessing ? "ACTIVE" : "STANDBY")
                    .font(DS.font(DS.fontCaption, weight: .bold))
                    .foregroundColor(engine.isProcessing ? DS.danger : DS.textTertiary)

                Circle()
                    .fill(engine.isProcessing ? DS.danger : DS.textDisabled)
                    .frame(width: DS.dotLG, height: DS.dotLG)
                    .shadow(
                        color: engine.isProcessing ? DS.danger.opacity(0.6) : .clear,
                        radius: 2
                    )
                    .animation(DS.stateTransition, value: engine.isProcessing)
            }
        }
        .padding(.horizontal, DS.spacingXL)
        .padding(.vertical, DS.spacingMD)
    }

    // MARK: - ACE-Step Bridge Status (Consolidated Single-Row)

    private var bridgeStatusBar: some View {
        HStack(spacing: DS.spacingXL) {
            // Process status
            LRStatusRow(
                dotColor: processStatusColor,
                label: "PROCESS",
                value: engine.bridgeProcess.state.rawValue,
                valueColor: processStatusColor.opacity(0.9),
                extras: processExtras,
                errorText: engine.bridgeProcess.state == .error ? engine.bridgeProcess.lastError : nil
            )
            .frame(maxWidth: .infinity)

            // ACE-STEP bridge status
            LRStatusRow(
                dotColor: bridgeStatusColor,
                label: "ACE-STEP",
                value: engine.aceBridge.status.rawValue,
                valueColor: bridgeStatusColor.opacity(0.8),
                extras: bridgeExtras,
                errorText: engine.aceBridge.status == .error ? engine.aceBridge.lastError : nil
            )
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, DS.spacingXL)
        .padding(.vertical, DS.spacingMD)
        .background(DS.surfaceSubtle)
    }

    private var processExtras: [(String, Color)] {
        var extras: [(String, Color)] = []
        if engine.bridgeProcess.state == .settingUp
            || engine.bridgeProcess.state == .installing
            || engine.bridgeProcess.state == .launching {
            if let lastLog = engine.bridgeProcess.setupLog.last {
                extras.append((String(lastLog.prefix(30)), DS.textTertiary))
            }
        }
        return extras
    }

    private var bridgeExtras: [(String, Color)] {
        var extras: [(String, Color)] = []
        if engine.aceBridge.remoteModelType != "none" &&
           engine.aceBridge.remoteModelType != "unknown" {
            extras.append((engine.aceBridge.remoteModelType.uppercased(), DS.neonTurquesa.opacity(0.6)))
        }
        if engine.aceBridge.status == .connected || engine.aceBridge.status == .modelLoaded {
            if engine.aceBridge.lastLatencyMs > 0 {
                extras.append((String(format: "%.0fms", engine.aceBridge.lastLatencyMs), DS.neonTurquesa.opacity(0.6)))
            }
            extras.append((engine.aceBridge.remoteDevice.uppercased(), DS.neonTurquesa.opacity(0.5)))
        }
        return extras
    }

    private var processStatusColor: Color {
        switch engine.bridgeProcess.state {
        case .idle:       return DS.textDisabled
        case .settingUp:  return DS.neonAmbar.opacity(0.8)
        case .installing: return DS.neonAmbar.opacity(0.9)
        case .launching:  return DS.neonAmbar.opacity(0.8)
        case .running:    return DS.neonTurquesa.opacity(0.8)
        case .stopping:   return DS.neonAmbar.opacity(0.6)
        case .error:      return DS.danger.opacity(0.7)
        }
    }

    private var bridgeStatusColor: Color {
        switch engine.aceBridge.status {
        case .disconnected: return DS.textDisabled
        case .connecting:   return DS.neonAmbar.opacity(0.8)
        case .connected:    return DS.neonTurquesa.opacity(0.7)
        case .modelLoaded:  return DS.neonTurquesa
        case .error:        return DS.danger.opacity(0.7)
        }
    }

    // MARK: - XY Drift Pad Section (Macro Control)

    private var xyDriftPadSection: some View {
        VStack(spacing: DS.spacingSM) {
            LRSectionHeader(
                title: "DRIFT FIELD",
                color: DS.neonTurquesa.opacity(0.65),
                trailing: "X: TEXTURE // Y: CHAOS",
                trailingColor: DS.neonTurquesa.opacity(0.45)
            )
            .padding(.horizontal, DS.spacingXL)
            .padding(.top, DS.spacingSM)

            if let lane = engine.focusLane {
                LatentXYPad(
                    x: Binding(
                        get: { lane.texture },
                        set: { lane.texture = $0 }
                    ),
                    y: Binding(
                        get: { lane.chaos },
                        set: { lane.chaos = $0 }
                    ),
                    xRange: LRConstants.macroRange,
                    yRange: LRConstants.macroRange,
                    xLabel: "TEXTURE",
                    yLabel: "CHAOS",
                    onDragStarted: {
                        lane.suppressMacroApplication = true
                    },
                    onCommit: {
                        lane.applyMacroTexture()
                        lane.applyMacroChaos()
                    },
                    onDragEnded: {
                        lane.suppressMacroApplication = false
                        lane.applyMacroTexture()
                        lane.applyMacroChaos()
                    }
                )
                .padding(.horizontal, DS.spacingXL)
                .padding(.bottom, DS.spacingSM)
                .help("Drift field -- drag to control Texture (X) and Chaos (Y) macros for the focus lane")
            }
        }
    }

    // MARK: - Lanes Mixer Section

    private var lanesMixerSection: some View {
        VStack(spacing: DS.spacingMD) {
            LRSectionHeader(
                title: "CHANNEL MIXER",
                trailing: "\(engine.lanes.count)/\(LRConstants.maxLanes)"
            )
            .padding(.horizontal, DS.spacingXL)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DS.spacingMD) {
                    ForEach(engine.lanes) { lane in
                        LaneStripView(
                            lane: lane,
                            engine: engine,
                            onRemove: {
                                if engine.lanes.count > 1 {
                                    engine.removeLane(id: lane.id)
                                }
                            }
                        )
                    }

                    if engine.lanes.count < LRConstants.maxLanes {
                        addLaneButton
                    }
                }
                .padding(.horizontal, DS.spacingXL)
            }
        }
        .padding(.vertical, DS.spacingSM)
    }

    // MARK: - Add Lane Button

    private var addLaneButton: some View {
        VStack(spacing: DS.spacingMD) {
            Text("ADD LANE")
                .font(DS.font(DS.fontCaption, weight: .bold))
                .foregroundColor(DS.neonTurquesa.opacity(0.65))

            VStack(spacing: DS.spacingSM) {
                ForEach(LanePreset.allPresets) { preset in
                    Button(action: {
                        engine.addLane(preset: preset)
                    }) {
                        Text(preset.name)
                            .font(DS.font(DS.fontCaption, weight: .bold))
                            .foregroundColor(LRConstants.DS.accentColor(for: preset.accentColor).opacity(0.7))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, DS.togglePaddingH)
                            .overlay(
                                RoundedRectangle(cornerRadius: DS.radiusSM)
                                    .stroke(LRConstants.DS.accentColor(for: preset.accentColor).opacity(0.3), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .help("Add a new \(preset.name) lane with tuned default parameters")
                }
            }
        }
        .padding(DS.spacingMD)
        .frame(width: LRConstants.laneStripWidth)
        .background(DS.surfaceSubtle)
        .overlay(
            RoundedRectangle(cornerRadius: DS.radiusMD)
                .stroke(style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                .foregroundColor(DS.border)
        )
    }

    // MARK: - Trigger Button (or bridge loading status)

    private var triggerButton: some View {
        Group {
            if engine.isProcessing {
                if engine.canAbort {
                    LRActionButton(
                        label: "ABORT ALL LANES",
                        icon: "stop.fill",
                        color: DS.danger,
                        style: .primary,
                        helpText: "Stop all lanes and reset the feedback loop (Space / Esc)"
                    ) {
                        engine.toggleProcessing(initiatedFromPerformMode: false)
                    }
                } else {
                    HStack(spacing: 10) {
                        ProgressView().scaleEffect(0.7).progressViewStyle(CircularProgressViewStyle(tint: .white))
                        Text("INITIATING")
                            .font(DS.font(DS.fontHeadline, weight: .bold))
                            .tracking(2)
                            .foregroundColor(.black)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, DS.spacingLG)
                    .background(DS.danger.opacity(0.8))
                    .overlay(Rectangle().stroke(DS.danger, lineWidth: 2))
                    .allowsHitTesting(false)
                }
            } else if engine.bridgeProcess.state == .running {
                LRActionButton(
                    label: "INITIATE ALL LANES",
                    icon: "waveform.path",
                    color: DS.danger,
                    style: .destructive,
                    helpText: "Start the recursive neural feedback loop on all lanes (Space)"
                ) {
                    engine.toggleProcessing(initiatedFromPerformMode: false)
                }
            } else {
                bridgeStatusPanel
            }
        }
        .padding(.horizontal, DS.spacingXL)
        .padding(.bottom, DS.spacingSM)
    }

    private var bridgeStatusPanel: some View {
        HStack(spacing: 10) {
            ProgressView()
                .scaleEffect(0.8)
                .progressViewStyle(CircularProgressViewStyle(tint: DS.neonAmbar))
            Text(bridgeStatusMessage)
                .font(DS.font(DS.fontTitle, weight: .medium))
                .foregroundColor(DS.neonAmbar.opacity(0.9))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DS.spacingLG)
        .background(DS.overlayReadout)
        .overlay(Rectangle().stroke(DS.neonAmbar.opacity(0.5), lineWidth: 1))
    }

    private var bridgeStatusMessage: String {
        switch engine.bridgeProcess.state {
        case .idle:       return "BRIDGE IDLE"
        case .settingUp:  return "SETUP ENV"
        case .installing: return "INSTALL DEPS"
        case .launching:  return "LOADING MODEL"
        case .running:    return "READY"
        case .stopping:   return "STOPPING"
        case .error:      return engine.bridgeProcess.lastError ?? "BRIDGE ERR"
        }
    }

    // MARK: - Status Bar

    private var statusBar: some View {
        HStack(spacing: DS.spacingMD) {
            Text("[ U N B R A N D E D ]")
                .font(DS.font(DS.fontCaption2, weight: .bold))
                .foregroundColor(DS.textDisabled)

            Spacer()

            let totalCycles = engine.lanes.reduce(0) { $0 + $1.iterationCount }
            Text("TOTAL CYCLES: \(totalCycles)")
                .font(DS.font(DS.fontCaption2, weight: .bold))
                .foregroundColor(
                    totalCycles > 0
                        ? DS.neonTurquesa.opacity(0.6)
                        : DS.textDisabled
                )

            if engine.aceBridge.remoteInferenceCount > 0 {
                Text("// BRIDGE: \(engine.aceBridge.remoteInferenceCount)")
                    .font(DS.font(DS.fontCaption2, weight: .bold))
                    .foregroundColor(DS.neonTurquesa.opacity(0.5))
            }

            Spacer()

            Text("48kHz / STEREO / v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.2")")
                .font(DS.font(DS.fontCaption2))
                .foregroundColor(DS.textDisabled)
        }
        .padding(.horizontal, DS.spacingXL)
        .padding(.bottom, DS.spacingMD)
    }
}
