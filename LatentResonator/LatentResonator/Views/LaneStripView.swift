import SwiftUI

// MARK: - Lane Strip View
//
// Compact channel strip for a single ResonatorLane.
// Displayed in the horizontal mixer layout of LatentResonatorView.
//
// Layout (vertical strip):
//   +------------------+
//   |  LANE NAME       |  <- colored header
//   |  [MUTE] [SOLO]   |
//   |  VOLUME ####     |  <- horizontal fader
//   |  RMS ████░░░░░░  |  <- horizontal meter
//   |  CYCLE: 42       |  <- iteration counter
//   |  [DETAIL >]      |  <- opens parameter popover
//   +------------------+
//
// Aesthetic: 60s electronic laboratory -- monospaced, CRT green,
// consistent with the existing LatentResonatorView design language.

private typealias DS = LRConstants.DS

struct LaneStripView: View {

    @ObservedObject var lane: ResonatorLane
    @ObservedObject var engine: NeuralEngine
    let onRemove: () -> Void

    @State private var showDetail: Bool = false

    // MARK: - Accent Color (from preset via lane property)

    private var accent: Color {
        LRConstants.DS.accentColor(for: lane.accentColorName)
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: DS.spacingMD) {
            headerSection
            LRDivider()

            muteSoloButtons
            volumeSection
            rmsMeter
            iterationCounter

            Text(lane.excitationMode.rawValue)
                .font(DS.font(DS.fontCaption2, weight: .bold))
                .foregroundColor(accent.opacity(0.5))

            macroKnobs
            parameterReadouts

            // Record button
            Button(action: { lane.toggleLaneRecording() }) {
                HStack(spacing: 3) {
                    Circle()
                        .fill(lane.isLaneRecording ? DS.danger : DS.textDisabled)
                        .frame(width: DS.dotMD, height: DS.dotMD)
                        .shadow(
                            color: lane.isLaneRecording ? DS.danger.opacity(0.8) : .clear,
                            radius: 3
                        )
                    Text("REC")
                        .font(DS.font(DS.fontCaption2, weight: .bold))
                        .foregroundColor(lane.isLaneRecording ? DS.danger : DS.textTertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, DS.togglePaddingV)
                .background(lane.isLaneRecording ? DS.danger.opacity(0.1) : Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: DS.radiusSM)
                        .stroke(
                            lane.isLaneRecording ? DS.danger.opacity(0.5) : DS.border,
                            lineWidth: 1
                        )
                )
            }
            .buttonStyle(.plain)
            .animation(DS.stateTransition, value: lane.isLaneRecording)

            Spacer(minLength: DS.spacingSM)

            // Detail button
            Button(action: { showDetail.toggle() }) {
                Text("DETAIL")
                    .font(DS.font(DS.fontCaption, weight: .bold))
                    .foregroundColor(accent.opacity(0.7))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, DS.spacingSM)
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.radiusSM)
                            .stroke(accent.opacity(0.3), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showDetail) {
                LaneDetailPopover(lane: lane, engine: engine, accent: accent)
            }

            // Remove button
            Button(action: onRemove) {
                Text("REMOVE")
                    .font(DS.font(DS.fontCaption2, weight: .bold))
                    .foregroundColor(DS.danger.opacity(0.5))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, DS.togglePaddingV)
            }
            .buttonStyle(.plain)
        }
        .padding(DS.spacingMD)
        .frame(width: LRConstants.laneStripWidth)
        .background(Color.white.opacity(0.02))
        .overlay(
            RoundedRectangle(cornerRadius: DS.radiusMD)
                .stroke(accent.opacity(lane.isSoloed ? 0.6 : 0.15), lineWidth: 1)
        )
        .animation(DS.stateTransition, value: lane.isSoloed)
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack {
            Text(lane.name)
                .font(DS.font(DS.fontBody, weight: .bold))
                .foregroundColor(accent)
            Spacer()
            Button(action: { engine.focusLaneId = lane.id }) {
                Circle()
                    .fill(engine.focusLaneId == lane.id ? accent : DS.textDisabled)
                    .frame(width: DS.dotLG, height: DS.dotLG)
            }
            .buttonStyle(.plain)
            .help("Focus (Performance XY drives this lane)")
            Text(lane.inferMethod.uppercased())
                .font(DS.font(DS.fontCaption2, weight: .medium))
                .foregroundColor(DS.textTertiary)
        }
    }

    // MARK: - Mute / Solo

    private var muteSoloButtons: some View {
        HStack(spacing: DS.spacingSM) {
            LRToggle(label: "M", isActive: lane.isMuted, activeColor: DS.danger, fullWidth: true) {
                lane.isMuted.toggle()
                engine.updateLaneMixerState()
            }
            LRToggle(label: "S", isActive: lane.isSoloed, activeColor: DS.warning, fullWidth: true) {
                lane.isSoloed.toggle()
                engine.updateLaneMixerState()
            }
        }
    }

    // MARK: - Volume

    private var volumeSection: some View {
        VStack(spacing: DS.spacingXS) {
            Text("VOL")
                .font(DS.font(DS.fontCaption2, weight: .bold))
                .foregroundColor(DS.textTertiary)

            Slider(value: $lane.volume, in: LRConstants.volumeRange)
                .accentColor(accent)
                .scrollableSlider(value: $lane.volume, range: LRConstants.volumeRange)
                .onChange(of: lane.volume) {
                    engine.updateLaneMixerState()
                }

            Text(String(format: "%.0f%%", lane.volume * 100))
                .font(DS.font(DS.fontCaption, weight: .medium))
                .foregroundColor(accent.opacity(0.6))
        }
    }

    // MARK: - RMS Meter (Horizontal bar below volume -- spatial correlation)

    private var rmsMeter: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(DS.textDisabled.opacity(0.5))
                RoundedRectangle(cornerRadius: 1)
                    .fill(
                        LinearGradient(
                            colors: [accent.opacity(0.5), accent, .red],
                            startPoint: .leading, endPoint: .trailing
                        )
                    )
                    .frame(
                        width: {
                            let rms = lane.currentRMS
                            guard rms.isFinite, rms >= 0 else { return CGFloat(0) }
                            return geo.size.width * CGFloat(min(rms * 10.0, 1.0))
                        }()
                    )
            }
            .frame(height: 4)
            .frame(maxWidth: .infinity)
        }
        .frame(height: 4)
    }

    // MARK: - Iteration Counter

    private var iterationCounter: some View {
        HStack(spacing: 3) {
            Circle()
                .fill(lane.isRunning ? accent : DS.textDisabled)
                .frame(width: DS.dotSM, height: DS.dotSM)
            Text("CYCLE: \(lane.iterationCount)")
                .font(DS.font(DS.fontCaption2, weight: .bold))
                .foregroundColor(
                    lane.iterationCount > 0
                        ? accent.opacity(0.7)
                        : DS.textDisabled
                )
            if lane.isInferring {
                Text("INFER")
                    .font(DS.font(DS.fontCaption2, weight: .bold))
                    .foregroundColor(DS.warning)
                    .opacity(lane.isInferring ? 1.0 : 0.0)
                    .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: lane.isInferring)
            }
            if lane.lfoDepth > 0 {
                Text("LFO")
                    .font(DS.font(DS.fontCaption2, weight: .bold))
                    .foregroundColor(DS.info)
            }
        }
        .animation(DS.stateTransition, value: lane.isRunning)
    }

    // MARK: - Macro Knobs

    private var macroKnobs: some View {
        VStack(spacing: DS.spacingSM) {
            HStack(spacing: DS.spacingXS) {
                RetroKnob(label: "TXT", value: $lane.texture,
                          range: LRConstants.macroRange, accentColor: .orange, size: 38)
                RetroKnob(label: "CHS", value: $lane.chaos,
                          range: LRConstants.macroRange, accentColor: .red, size: 38)
            }
            HStack(spacing: DS.spacingXS) {
                RetroKnob(label: "WRM", value: $lane.warmth,
                          range: LRConstants.macroRange, accentColor: .yellow, size: 38)
            }
        }
    }

    // MARK: - Parameter Readouts

    private var parameterReadouts: some View {
        VStack(spacing: DS.spacingXS) {
            miniReadout("CFG", value: lane.guidanceScale, format: "%.1f")
            miniReadout("SHF", value: lane.shift, format: "%.1f")
            miniReadout("ENT", value: lane.entropyLevel, format: "%.0f")
            miniReadout("FBK", value: lane.feedbackAmount, format: "%.2f")
        }
    }

    private func miniReadout(_ label: String, value: Float, format: String) -> some View {
        HStack {
            Text(label)
                .font(DS.font(DS.fontCaption2, weight: .bold))
                .foregroundColor(DS.textTertiary)
                .frame(width: 24, alignment: .leading)
            Text(String(format: format, value))
                .font(DS.font(DS.fontCaption2, weight: .medium))
                .foregroundColor(accent.opacity(0.5))
            Spacer()
        }
    }
}

// MARK: - Lane Detail Popover
//
// Full parameter editing view, opened from the DETAIL button.
// Provides access to ALL per-lane parameters including ACE-Step 1.5
// specifics (shift, infer_method, steps), effects chain, LFO, and prompt.
//
// Sections use DisclosureGroup for progressive disclosure.
// Default: OSCILLATOR and ACE-STEP expanded.

struct LaneDetailPopover: View {

    private enum DetailTab: String, CaseIterable {
        case core = "CORE"
        case advanced = "ADVANCED"
    }

    @ObservedObject var lane: ResonatorLane
    let engine: NeuralEngine
    let accent: Color

    @State private var detailTab: DetailTab = .core
    @State private var oscExpanded = true
    @State private var filterExpanded = false
    @State private var aceExpanded = true
    @State private var stochasticExpanded = false
    @State private var effectsExpanded = false
    @State private var lfoExpanded = false

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(spacing: DS.spacingLG) {
                Text("\(lane.name) -- PARAMETERS")
                    .font(DS.font(DS.fontTitle, weight: .bold))
                    .foregroundColor(accent)

                LRSegmentPicker(
                    items: DetailTab.allCases,
                    selected: detailTab,
                    color: accent,
                    labelForItem: { $0.rawValue },
                    onSelect: { detailTab = $0 }
                )

                LRDivider()

                promptSection

                LRDivider()

                if detailTab == .core {
                    DisclosureGroup(isExpanded: $oscExpanded) {
                        oscillatorContent
                    } label: {
                        LRSectionHeader(title: "OSCILLATOR", color: DS.info)
                    }
                    .accentColor(DS.info)

                    LRDivider()

                    DisclosureGroup(isExpanded: $aceExpanded) {
                        aceStepContent
                    } label: {
                        LRSectionHeader(title: "ACE-STEP 1.5", color: DS.info)
                    }
                    .accentColor(DS.info)

                    LRDivider()

                    DisclosureGroup(isExpanded: $stochasticExpanded) {
                        stochasticMassContent
                    } label: {
                        LRSectionHeader(title: "STOCHASTIC MASS", color: DS.warning)
                    }
                    .accentColor(DS.warning)
                }

                if detailTab == .advanced {
                    DisclosureGroup(isExpanded: $filterExpanded) {
                        filterContent
                    } label: {
                        LRSectionHeader(title: "ANALOG FILTER", color: DS.warning)
                    }
                    .accentColor(DS.warning)

                    LRDivider()

                    DisclosureGroup(isExpanded: $effectsExpanded) {
                        effectsContent
                    } label: {
                        LRSectionHeader(title: "EFFECTS CHAIN", color: .purple)
                    }
                    .accentColor(.purple)

                    LRDivider()

                    DisclosureGroup(isExpanded: $lfoExpanded) {
                        lfoContent
                    } label: {
                        LRSectionHeader(title: "LFO // STOCHASTIC DRIFT", color: .yellow)
                    }
                    .accentColor(.yellow)
                }
            }
            .padding(DS.spacingXL)
        }
        .frame(width: 420, height: 700)
        .background(Color(red: 0.05, green: 0.05, blue: 0.05))
    }

    // MARK: - Prompt Section

    private var promptSection: some View {
        VStack(spacing: DS.spacingSM) {
            HStack {
                LRSectionHeader(title: "SEMANTIC FILTER [P]", color: DS.warning.opacity(0.6))
                Spacer()
                Button(action: { lane.promptEvolutionEnabled.toggle() }) {
                    Text(lane.promptEvolutionEnabled ? "AUTO" : "MANUAL")
                        .font(DS.font(DS.fontCaption2, weight: .bold))
                        .foregroundColor(lane.promptEvolutionEnabled ? DS.warning.opacity(0.6) : DS.textTertiary)
                }
                .buttonStyle(.plain)
            }

            TextField("semantic prompt...", text: $lane.promptText)
                .textFieldStyle(.plain)
                .font(DS.font(DS.fontBody))
                .foregroundColor(DS.warning.opacity(0.8))
                .padding(DS.spacingMD)
                .background(Color.black)
                .overlay(RoundedRectangle(cornerRadius: DS.radiusSM).stroke(DS.warning.opacity(0.2)))
                .disabled(lane.promptEvolutionEnabled)
                .opacity(lane.promptEvolutionEnabled ? 0.4 : 1.0)
        }
    }

    // MARK: - Oscillator Content

    private var oscillatorContent: some View {
        VStack(spacing: DS.spacingMD) {
            LRSegmentPicker(
                items: ExcitationMode.allCases,
                selected: lane.excitationMode,
                color: DS.info,
                labelForItem: { String($0.rawValue.prefix(4)) },
                onSelect: { lane.excitationMode = $0 }
            )

            LRParamSlider(label: "FREQUENCY", value: $lane.sineFrequency,
                          range: LRConstants.sineFrequencyRange, format: "%.0f Hz", color: DS.info)
            LRParamSlider(label: "PULSE W", value: $lane.pulseWidth,
                          range: LRConstants.pulseWidthRange, format: "%.2f", color: DS.info)
        }
        .padding(.top, DS.spacingSM)
    }

    // MARK: - Filter Content

    private var filterContent: some View {
        VStack(spacing: DS.spacingMD) {
            LRSegmentPicker(
                items: FilterMode.allCases,
                selected: lane.filterMode,
                color: DS.warning,
                labelForItem: { $0.rawValue },
                onSelect: { lane.filterMode = $0 }
            )

            LRParamSlider(label: "CUTOFF", value: $lane.filterCutoff,
                          range: LRConstants.filterCutoffRange, format: "%.0f Hz", color: DS.warning)
            LRParamSlider(label: "RESONANCE", value: $lane.filterResonance,
                          range: LRConstants.filterResonanceRange, format: "%.2f", color: DS.warning)

            LRSectionHeader(title: "SATURATION", color: DS.danger)

            LRSegmentPicker(
                items: SaturationMode.allCases,
                selected: lane.saturationMode,
                color: DS.danger,
                labelForItem: { $0.rawValue },
                onSelect: { lane.saturationMode = $0 }
            )
        }
        .padding(.top, DS.spacingSM)
    }

    // MARK: - ACE-Step Content

    private var aceStepContent: some View {
        VStack(spacing: DS.spacingMD) {
            LRParamSlider(label: "GUIDANCE (CFG)", value: $lane.guidanceScale,
                          range: LRConstants.cfgScaleRange, format: "%.1f", color: accent)
            LRParamSlider(label: "SHIFT", value: $lane.shift,
                          range: LRConstants.aceShiftRange, format: "%.1f", color: accent)
            LRParamSlider(label: "INPUT STRENGTH", value: $lane.inputStrength,
                          range: LRConstants.inputStrengthRange, format: "%.2f", color: accent)

            HStack {
                Text("STEPS")
                    .font(DS.font(DS.fontCaption2, weight: .bold))
                    .foregroundColor(DS.textTertiary)
                    .frame(width: 76, alignment: .leading)
                Slider(value: Binding(
                    get: { Float(lane.inferenceSteps) },
                    set: { lane.inferenceSteps = Int($0) }
                ), in: Float(LRConstants.aceStepsRange.lowerBound)...Float(LRConstants.aceStepsRange.upperBound))
                    .accentColor(accent)
                    .scrollableSlider(
                        value: Binding(get: { Float(lane.inferenceSteps) }, set: { lane.inferenceSteps = Int($0) }),
                        range: Float(LRConstants.aceStepsRange.lowerBound)...Float(LRConstants.aceStepsRange.upperBound)
                    )
                Text("\(lane.inferenceSteps)")
                    .font(DS.font(DS.fontCaption, weight: .medium))
                    .foregroundColor(accent.opacity(0.7))
                    .frame(width: 36, alignment: .trailing)
            }

            HStack {
                Text("METHOD")
                    .font(DS.font(DS.fontCaption2, weight: .bold))
                    .foregroundColor(DS.textTertiary)
                Spacer()
                LRToggle(
                    label: lane.inferMethod.uppercased(),
                    isActive: lane.inferMethod == "sde",
                    activeColor: DS.warning
                ) {
                    lane.inferMethod = lane.inferMethod == "ode" ? "sde" : "ode"
                }
            }
        }
        .padding(.top, DS.spacingSM)
    }

    // MARK: - Stochastic Mass Content

    private var stochasticMassContent: some View {
        VStack(spacing: DS.spacingMD) {
            LRParamSlider(label: "ENTROPY", value: $lane.entropyLevel,
                          range: LRConstants.entropyRange, format: "%.0f", color: DS.warning)
            LRParamSlider(label: "GRANULARITY", value: $lane.granularity,
                          range: LRConstants.granularityRange, format: "%.0f", color: DS.warning)
            LRParamSlider(label: "FEEDBACK", value: $lane.feedbackAmount,
                          range: LRConstants.feedbackRange, format: "%.2f", color: DS.warning)
        }
        .padding(.top, DS.spacingSM)
    }

    // MARK: - Effects Content

    private var effectsContent: some View {
        VStack(spacing: DS.spacingMD) {
            LRParamSlider(label: "DELAY TIME", value: $lane.delayTime,
                          range: LRConstants.delayTimeRange, format: "%.2fs", color: .purple)
            LRParamSlider(label: "DELAY FDBK", value: $lane.delayFeedback,
                          range: LRConstants.delayFeedbackRange, format: "%.2f", color: .purple)
            LRParamSlider(label: "DELAY MIX", value: $lane.delayMix,
                          range: LRConstants.delayMixRange, format: "%.2f", color: .purple)
            LRParamSlider(label: "BIT CRUSH", value: $lane.bitCrushDepth,
                          range: LRConstants.bitCrushRange, format: "%.0f", color: .purple)
            LRParamSlider(label: "RES NOTE", value: $lane.resonatorNote,
                          range: LRConstants.resonatorNoteRange, format: "%.0f", color: .purple)
            LRParamSlider(label: "RES DECAY", value: $lane.resonatorDecay,
                          range: LRConstants.resonatorDecayRange, format: "%.2f", color: .purple)

            LRToggle(
                label: lane.spectralFreezeActive ? "FROZEN" : "THAWED",
                isActive: lane.spectralFreezeActive,
                activeColor: DS.info,
                fullWidth: true
            ) {
                lane.spectralFreezeActive.toggle()
            }
        }
        .padding(.top, DS.spacingSM)
    }

    // MARK: - LFO Content

    private var lfoContent: some View {
        VStack(spacing: DS.spacingMD) {
            LRSegmentPicker(
                items: LFOTarget.allCases,
                selected: lane.lfoTarget,
                color: .yellow,
                labelForItem: { String($0.rawValue.prefix(4)) },
                onSelect: { lane.lfoTarget = $0 }
            )

            LRParamSlider(label: "RATE", value: $lane.lfoRate,
                          range: LRConstants.lfoRateRange, format: "%.2f Hz", color: .yellow)
            LRParamSlider(label: "DEPTH", value: $lane.lfoDepth,
                          range: LRConstants.lfoDepthRange, format: "%.0f%%",
                          multiplier: 100, color: .yellow)
        }
        .padding(.top, DS.spacingSM)
    }
}
