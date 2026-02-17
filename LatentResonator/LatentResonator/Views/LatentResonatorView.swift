import SwiftUI

// MARK: - Latent Resonator View (Multi-Lane Mixer)
//
// Main interface for the Latent Resonator instrument.
// Aesthetic: 60s electronic laboratory -- oscilloscopes,
// precision dials, monospaced type, CRT phosphor green.
//
// Layout (mixer-style):
//   +--------------------------------------------------+
//   |  HEADER BAR                                      |
//   |  BRIDGE STATUS                                   |
//   +--------------------------------------------------+
//   |  MASTER VECTORSCOPE                              |
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
            DS.surfacePrimary.ignoresSafeArea()

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

                Spacer(minLength: DS.spacingSM)
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
                                color: engine.isMasterRecording ? DS.danger.opacity(0.8) : .clear,
                                radius: 3
                            )
                        Text("REC")
                            .font(DS.font(DS.fontCaption2, weight: .bold))
                            .foregroundColor(engine.isMasterRecording ? DS.danger : DS.textTertiary)
                    }
                    .padding(.horizontal, DS.togglePaddingH)
                    .padding(.vertical, DS.togglePaddingV)
                    .background(engine.isMasterRecording ? DS.danger.opacity(0.1) : Color.clear)
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

                Text("\(engine.lanes.count) LANE\(engine.lanes.count == 1 ? "" : "S")")
                    .font(DS.font(DS.fontCaption, weight: .bold))
                    .foregroundColor(DS.info.opacity(0.4))

                Text(engine.isProcessing ? "ACTIVE" : "STANDBY")
                    .font(DS.font(DS.fontCaption, weight: .bold))
                    .foregroundColor(engine.isProcessing ? DS.danger : DS.textTertiary)

                Circle()
                    .fill(engine.isProcessing ? DS.danger : DS.textDisabled)
                    .frame(width: DS.dotLG, height: DS.dotLG)
                    .shadow(
                        color: engine.isProcessing ? DS.danger.opacity(0.8) : .clear,
                        radius: 4
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
        .background(Color.white.opacity(0.015))
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
            extras.append((engine.aceBridge.remoteModelType.uppercased(), DS.success.opacity(0.5)))
        }
        if engine.aceBridge.status == .connected || engine.aceBridge.status == .modelLoaded {
            if engine.aceBridge.lastLatencyMs > 0 {
                extras.append((String(format: "%.0fms", engine.aceBridge.lastLatencyMs), DS.success.opacity(0.5)))
            }
            extras.append((engine.aceBridge.remoteDevice.uppercased(), DS.info.opacity(0.4)))
        }
        return extras
    }

    private var processStatusColor: Color {
        switch engine.bridgeProcess.state {
        case .idle:       return DS.textDisabled
        case .settingUp:  return DS.warning.opacity(0.7)
        case .installing: return DS.warning.opacity(0.8)
        case .launching:  return DS.warning.opacity(0.7)
        case .running:    return DS.success.opacity(0.7)
        case .stopping:   return DS.warning.opacity(0.5)
        case .error:      return DS.danger.opacity(0.7)
        }
    }

    private var bridgeStatusColor: Color {
        switch engine.aceBridge.status {
        case .disconnected: return DS.textDisabled
        case .connecting:   return DS.warning.opacity(0.7)
        case .connected:    return DS.success.opacity(0.6)
        case .modelLoaded:  return DS.success
        case .error:        return DS.danger.opacity(0.7)
        }
    }

    // MARK: - XY Drift Pad Section (Macro Control)

    private var xyDriftPadSection: some View {
        VStack(spacing: DS.spacingSM) {
            LRSectionHeader(
                title: "DRIFT FIELD",
                color: DS.success.opacity(0.5),
                trailing: "X: TEXTURE // Y: CHAOS",
                trailingColor: DS.success.opacity(0.3)
            )
            .padding(.horizontal, DS.spacingXL)
            .padding(.top, DS.spacingMD)

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
                    onDragEnded: {
                        lane.suppressMacroApplication = false
                        lane.applyMacroTexture()
                        lane.applyMacroChaos()
                    }
                )
                .padding(.horizontal, DS.spacingXL)
                .padding(.bottom, DS.spacingMD)
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
        .padding(.vertical, DS.spacingMD)
    }

    // MARK: - Add Lane Button

    private var addLaneButton: some View {
        VStack(spacing: DS.spacingMD) {
            Text("ADD LANE")
                .font(DS.font(DS.fontCaption, weight: .bold))
                .foregroundColor(DS.success.opacity(0.5))

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
                }
            }
        }
        .padding(DS.spacingMD)
        .frame(width: LRConstants.laneStripWidth)
        .background(Color.white.opacity(0.01))
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
                        style: .primary
                    ) {
                        engine.toggleProcessing()
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
                    style: .destructive
                ) {
                    engine.toggleProcessing()
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
                .progressViewStyle(CircularProgressViewStyle(tint: .orange))
            Text(bridgeStatusMessage)
                .font(DS.font(DS.fontTitle, weight: .medium))
                .foregroundColor(DS.warning.opacity(0.9))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DS.spacingLG)
        .background(Color.black.opacity(0.6))
        .overlay(Rectangle().stroke(DS.warning.opacity(0.5), lineWidth: 1))
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
                        ? DS.success.opacity(0.5)
                        : DS.textDisabled
                )

            if engine.aceBridge.remoteInferenceCount > 0 {
                Text("// BRIDGE: \(engine.aceBridge.remoteInferenceCount)")
                    .font(DS.font(DS.fontCaption2, weight: .bold))
                    .foregroundColor(DS.info.opacity(0.4))
            }

            Spacer()

            Text("48kHz / STEREO / v1.0.0")
                .font(DS.font(DS.fontCaption2))
                .foregroundColor(DS.textDisabled)
        }
        .padding(.horizontal, DS.spacingXL)
        .padding(.bottom, DS.spacingMD)
    }
}
