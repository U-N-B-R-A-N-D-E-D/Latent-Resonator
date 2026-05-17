import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Performance Motherbase View
//
// Fixed-layout performance surface: scenes, crossfader, step grid, macro controls.
// No scroll; same controls in same place for muscle memory (Elektron-style).
// v2.0: Migrated to MacroNode-based architecture.
// Whitepaper §4.2.2, §7.

private typealias DS = LRConstants.DS

struct PerformanceMotherbaseView: View {

    @ObservedObject var engine: NeuralEngine

    @State private var clipboardStep: PerformanceStep? = nil
    @State private var showTemplateBrowser = false

    /// B.1.4 — paramId of the macro parameter the user selected for the X axis
    /// of the XY pad. Falls back to the first exposed control of the focus
    /// macro when empty.
    @State private var selectedXParamKey: String = ""
    /// B.1.4 — paramId of the macro parameter the user selected for the Y axis.
    @State private var selectedYParamKey: String = ""

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [DS.titanioTop, DS.titanioBottom],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                LRDivider()

                // B.1.1 — Macro tab row: switch focus across macros, with
                // inline mute/solo toggles.
                macroTabRow
                    .background(DS.surfaceElevated.opacity(0.4))
                LRDivider()

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                        // Scene Crossfader Section
                        sceneCrossfaderSection
                            .background(DS.surfaceElevated.opacity(0.5))
                        LRDivider()

                        // Macro Control Section (v2.0 - replaces lane-based controls)
                        macroControlSection
                            .background(DS.surfaceElevated.opacity(0.3))
                        LRDivider()

                        // Auto-Generated Controls Section (from exposedControls)
                        autoControlsSection
                            .background(DS.surfaceElevated.opacity(0.25))
                        LRDivider()

                        // Step Grid Section
                        stepGridSection
                            .background(DS.surfaceElevated.opacity(0.2))
                        LRDivider()

                        // Active Macros List
                        activeMacrosSection
                    }
                }
                .frame(maxHeight: .infinity)

                triggerButton
                statusBar
            }
        }
        .onChange(of: engine.focusMacroId) { _, _ in
            engine.selectedStepIndices = []
        }
        .onChange(of: engine.crossfaderPosition) { _, _ in
            // Apply crossfader when position changes
            engine.applyCrossfader()
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack(spacing: DS.spacingMD) {
            Text("MOTHERBASE")
                .font(DS.font(DS.fontTitle, weight: .bold))
                .foregroundColor(DS.neonTurquesa.opacity(0.85))

            Circle()
                .fill(engine.aceBridge.status == .modelLoaded ? DS.success :
                      (engine.aceBridge.status == .connected ? DS.warning : DS.textTertiary))
                .frame(width: DS.dotMD, height: DS.dotMD)

            Text(engine.aceBridge.status.rawValue)
                .font(DS.font(DS.fontCaption, weight: .bold))
                .foregroundColor(DS.textSecondary)

            if engine.aceBridge.lastLatencyMs > 0 {
                Text(String(format: "%.0fms", engine.aceBridge.lastLatencyMs))
                    .font(DS.font(DS.fontCaption))
                    .foregroundColor(DS.neonTurquesa.opacity(0.6))
            }

            Spacer()

            if engine.isProcessing {
                LRToggle(
                    label: "PANIC",
                    isActive: true,
                    activeColor: DS.danger,
                    helpText: "Emergency stop -- immediately halt all audio processing (Esc)"
                ) {
                    engine.stopProcessing()
                }
            }

            // New Composition button
            Button(action: { showTemplateBrowser = true }) {
                HStack(spacing: DS.spacingXS) {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 10))
                    Text("NEW")
                        .font(DS.font(DS.fontCaption, weight: .bold))
                }
                .foregroundColor(DS.neonTurquesa)
                .padding(.horizontal, DS.spacingSM)
                .padding(.vertical, DS.togglePaddingV)
                .background(DS.neonTurquesa.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: DS.radiusSM)
                        .stroke(DS.neonTurquesa.opacity(0.4), lineWidth: 1)
                )
                .cornerRadius(DS.radiusSM)
            }
            .buttonStyle(.plain)
            .help("Create new composition from template")

            LRToggle(
                label: engine.isMasterRecording ? "REC ●" : "REC",
                isActive: engine.isMasterRecording,
                activeColor: DS.danger,
                helpText: "Master record -- capture output to WAV (R)"
            ) {
                engine.toggleMasterRecording()
            }
        }
        .padding(.horizontal, DS.spacingXL)
        .padding(.vertical, DS.spacingSM)
        // Template Browser - add manually in Xcode after adding TemplateBrowserView.swift to project
        // .sheet(isPresented: $showTemplateBrowser) {
        //     TemplateBrowserView(engine: engine, isPresented: $showTemplateBrowser)
        // }
    }

    // MARK: - Scene Crossfader Section

    private var sceneCrossfaderSection: some View {
        VStack(spacing: DS.spacingSM) {
            HStack {
                LRSectionHeader(title: "SCENE MORPH", color: DS.neonTurquesa.opacity(0.6))
                Spacer()
                Text("A→B")
                    .font(DS.font(DS.fontCaption, weight: .bold))
                    .foregroundColor(DS.textTertiary)
            }

            // Scene A/B Selectors
            HStack(spacing: DS.spacingMD) {
                sceneSelector(label: "A", index: $engine.crossfaderSceneAIndex)
                crossfaderSlider
                sceneSelector(label: "B", index: $engine.crossfaderSceneBIndex)
            }

            // Scene Grid
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: DS.spacingSM) {
                ForEach(0..<min(8, engine.sceneBank.scenes.count), id: \.self) { idx in
                    sceneButton(index: idx)
                }
            }
        }
        .padding(.horizontal, DS.spacingXL)
        .padding(.vertical, DS.spacingSM)
    }

    private var crossfaderSlider: some View {
        VStack(spacing: DS.spacingXS) {
            HStack {
                Text("MIX")
                    .font(DS.font(DS.fontCaption2, weight: .bold))
                    .foregroundColor(DS.textTertiary)
                Spacer()
                Text(String(format: "%.0f%%", engine.crossfaderPosition * 100))
                    .font(DS.font(DS.fontCaption, weight: .medium))
                    .foregroundColor(DS.neonTurquesa)
            }

            Slider(
                value: Binding(
                    get: { Double(engine.crossfaderPosition) },
                    set: { engine.crossfaderPosition = Float($0) }
                ),
                in: 0...1
            )
            .accentColor(DS.neonTurquesa)
            .scrollableSlider(
                value: Binding(
                    get: { Double(engine.crossfaderPosition) },
                    set: { engine.crossfaderPosition = Float($0) }
                ),
                range: 0...1
            )
        }
        .frame(maxWidth: .infinity)
    }

    private func sceneSelector(label: String, index: Binding<Int>) -> some View {
        VStack(spacing: DS.spacingXS) {
            Text(label)
                .font(DS.font(DS.fontCaption, weight: .bold))
                .foregroundColor(label == "A" ? DS.neonTurquesa : DS.neonAmbar)

            Picker("Scene \(label)", selection: index) {
                ForEach(0..<engine.sceneBank.scenes.count, id: \.self) { idx in
                    Text("\(idx + 1): \(engine.sceneBank.scenes[idx].name)")
                        .font(DS.font(DS.fontCaption))
                        .tag(idx)
                }
            }
            .pickerStyle(MenuPickerStyle())
            .labelsHidden()
            .frame(width: 140)
        }
    }

    private func sceneButton(index: Int) -> some View {
        let scene = engine.sceneBank.scenes[index]
        let isCurrentA = index == engine.crossfaderSceneAIndex
        let isCurrentB = index == engine.crossfaderSceneBIndex

        return Button(action: {
            engine.sceneManager.applyScene(at: index, to: engine.nodeGraph)
        }) {
            HStack(spacing: DS.spacingXS) {
                if isCurrentA {
                    Text("A")
                        .font(DS.font(DS.fontCaption2, weight: .bold))
                        .foregroundColor(.black)
                        .padding(.horizontal, 4)
                        .background(DS.neonTurquesa)
                        .cornerRadius(2)
                }
                if isCurrentB {
                    Text("B")
                        .font(DS.font(DS.fontCaption2, weight: .bold))
                        .foregroundColor(.black)
                        .padding(.horizontal, 4)
                        .background(DS.neonAmbar)
                        .cornerRadius(2)
                }

                Text(scene.name)
                    .font(DS.font(DS.fontCaption, weight: .bold))
                    .foregroundColor(isCurrentA || isCurrentB ? .white : DS.textSecondary)
                    .lineLimit(1)

                Spacer()

                // Save button
                Button(action: {
                    engine.sceneManager.captureScene(at: index, from: engine.nodeGraph)
                }) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 10))
                        .foregroundColor(DS.textTertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, DS.spacingSM)
            .padding(.vertical, DS.spacingXS)
            .background(
                isCurrentA ? DS.neonTurquesa.opacity(0.3) :
                isCurrentB ? DS.neonAmbar.opacity(0.3) :
                DS.surfaceSubtle
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.radiusSM)
                    .stroke(
                        isCurrentA ? DS.neonTurquesa :
                        isCurrentB ? DS.neonAmbar :
                        DS.border,
                        lineWidth: isCurrentA || isCurrentB ? 2 : 1
                    )
            )
            .cornerRadius(DS.radiusSM)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Macro Tab Row (B.1.1)

    /// Horizontal scrollable row of macro "tabs". Each tab shows the macro
    /// name and inline `M` / `S` toggles (mute / solo). Selecting a tab
    /// writes the macro's id into `engine.focusMacroId`.
    ///
    /// This is the v2 replacement for the old lane-tab strip in
    /// `PerformanceMotherbaseView.swift.backup_v1` — iterates
    /// `engine.macroNodes` instead of `engine.lanes`.
    private var macroTabRow: some View {
        HStack(spacing: DS.spacingSM) {
            if engine.macroNodes.isEmpty {
                Text("NO MACROS — add a Macro node in PATCH mode")
                    .font(DS.font(DS.fontCaption2, weight: .bold))
                    .foregroundColor(DS.textDisabled)
                    .padding(.vertical, DS.spacingSM)
                Spacer()
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: DS.spacingSM) {
                        ForEach(engine.macroNodes, id: \.id) { macro in
                            macroTab(macro)
                        }
                    }
                    .padding(.vertical, DS.spacingXS)
                }
            }
        }
        .padding(.horizontal, DS.spacingXL)
        .padding(.vertical, DS.spacingXS)
    }

    /// A single macro tab: name + mute/solo toggles. Tapping the name
    /// sets `engine.focusMacroId`. Mute/solo toggles flip the macro's
    /// `isMuted` / `isSoloed` parameters and notify the mixer.
    @ViewBuilder
    private func macroTab(_ macro: MacroNode) -> some View {
        let isFocused = engine.focusMacro?.id == macro.id
        let isMuted = (macro.parameters["isMuted"] as? Bool) ?? false
        let isSoloed = (macro.parameters["isSoloed"] as? Bool) ?? false

        HStack(spacing: DS.spacingXS) {
            Button(action: { engine.focusMacroId = macro.id }) {
                HStack(spacing: DS.spacingXS) {
                    Circle()
                        .fill(isFocused ? DS.neonTurquesa : DS.textTertiary)
                        .frame(width: DS.dotSM, height: DS.dotSM)

                    Text(macro.name.uppercased())
                        .font(DS.font(DS.fontCaption, weight: .bold))
                        .foregroundColor(isFocused ? .white : DS.textSecondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, DS.spacingSM)
                .padding(.vertical, DS.togglePaddingV)
            }
            .buttonStyle(.plain)
            .help("Focus macro '\(macro.name)'")

            LRToggle(
                label: "M",
                isActive: isMuted,
                activeColor: DS.danger,
                helpText: "Mute macro '\(macro.name)'"
            ) {
                macro.setParam("isMuted", value: !isMuted)
                engine.updateMacroMixerState()
            }

            LRToggle(
                label: "S",
                isActive: isSoloed,
                activeColor: DS.neonAmbar,
                helpText: "Solo macro '\(macro.name)'"
            ) {
                macro.setParam("isSoloed", value: !isSoloed)
                engine.updateMacroMixerState()
            }
        }
        .padding(.horizontal, DS.spacingXS)
        .background(isFocused ? DS.neonTurquesa.opacity(0.18) : DS.surfaceSubtle)
        .overlay(
            RoundedRectangle(cornerRadius: DS.radiusSM)
                .stroke(isFocused ? DS.neonTurquesa : DS.border,
                        lineWidth: isFocused ? 2 : 1)
        )
        .cornerRadius(DS.radiusSM)
    }

    // MARK: - Macro Control Section (B.1.4)

    /// Macro drift / XY pad section. Hosts the WebView-backed
    /// `AudioVisualizerXYPad` driven by user-selectable axis parameters
    /// from `engine.nodeGraph.exposedControls` (filtered to the focus
    /// macro).
    private var macroControlSection: some View {
        VStack(spacing: DS.spacingSM) {
            HStack {
                LRSectionHeader(
                    title: "MACRO DRIFT",
                    trailing: "\(engine.macroNodes.count) ACTIVE",
                    trailingColor: DS.neonTurquesa.opacity(0.6)
                )
                Spacer()
            }

            xyAxisParamPickers

            if let focusMacro = engine.focusMacro {
                AudioVisualizerXYPad(
                    x: xyBindingX(macro: focusMacro),
                    y: xyBindingY(macro: focusMacro),
                    xRange: xyRangeX(macro: focusMacro),
                    yRange: xyRangeY(macro: focusMacro),
                    xLabel: xyLabelX(macro: focusMacro),
                    yLabel: xyLabelY(macro: focusMacro),
                    waveformSource: { (focusMacro.parameters["waveformSnapshot"] as? [Float]) ?? [] },
                    spectralSource: { (focusMacro.parameters["spectralBins"] as? [Float]) ?? [] }
                )
                .frame(height: LRConstants.xyPadHeight)
            } else {
                emptyMacroPlaceholder
            }
        }
        .padding(.horizontal, DS.spacingXL)
        .padding(.vertical, DS.spacingSM)
        .onAppear { ensureAxisDefaults() }
        .onChange(of: engine.focusMacroId) { _, _ in
            // Reset axis defaults when the focus macro changes — otherwise
            // the user gets stuck on a paramId that does not exist on the
            // new macro.
            selectedXParamKey = ""
            selectedYParamKey = ""
            ensureAxisDefaults()
        }
    }

    private var emptyMacroPlaceholder: some View {
        RoundedRectangle(cornerRadius: DS.radiusSM)
            .fill(DS.panelHollow)
            .frame(height: LRConstants.xyPadHeight)
            .overlay(
                VStack(spacing: DS.spacingSM) {
                    Text("NO MACRO FOCUSED")
                        .font(DS.font(DS.fontBody, weight: .bold))
                        .foregroundColor(DS.textTertiary)
                    Text("Add a Macro node in PATCH mode to expose parameters")
                        .font(DS.font(DS.fontCaption))
                        .foregroundColor(DS.textDisabled)
                }
            )
    }

    /// Per-axis parameter pickers (B.1.4). When the focus macro has any
    /// exposed controls, this row lets the user pick which parameter goes
    /// on X and which on Y. The XY pad below reads the current selection
    /// via `xyBindingX(macro:)` / `xyBindingY(macro:)`.
    private var xyAxisParamPickers: some View {
        let controls = currentMacroExposedControls
        return HStack(spacing: DS.spacingMD) {
            if controls.isEmpty {
                Text("No exposed controls — expose parameters in PATCH mode.")
                    .font(DS.font(DS.fontCaption2))
                    .foregroundColor(DS.textDisabled)
                Spacer()
            } else {
                axisPicker(label: "X", selection: $selectedXParamKey, controls: controls, color: DS.neonTurquesa)
                axisPicker(label: "Y", selection: $selectedYParamKey, controls: controls, color: DS.neonAmbar)
                Spacer()
            }
        }
    }

    /// Build a small picker for one axis. `selection` is the paramId string
    /// currently chosen for that axis.
    private func axisPicker(label: String, selection: Binding<String>, controls: [ExposedControl], color: Color) -> some View {
        HStack(spacing: DS.spacingXS) {
            Text("\(label):")
                .font(DS.font(DS.fontCaption2, weight: .bold))
                .foregroundColor(color)
            Picker(selection: selection, label: EmptyView()) {
                ForEach(controls, id: \.paramId) { control in
                    Text(control.label).tag(control.paramId)
                }
            }
            .pickerStyle(MenuPickerStyle())
            .labelsHidden()
            .frame(width: 160)
            .help("Choose macro parameter for the \(label) axis")
        }
    }

    /// All exposed controls of the focus macro, in the order they were
    /// registered. Empty when no macro is in focus.
    private var currentMacroExposedControls: [ExposedControl] {
        guard let macroId = engine.focusMacro?.id else { return [] }
        return engine.nodeGraph.exposedControls.filter { $0.nodeId == macroId }
    }

    /// Seed the axis selections with the first / second exposed control if
    /// the user has not yet made an explicit choice. Called from `onAppear`
    /// and when the focus macro changes.
    private func ensureAxisDefaults() {
        let controls = currentMacroExposedControls
        guard !controls.isEmpty else { return }
        if selectedXParamKey.isEmpty || !controls.contains(where: { $0.paramId == selectedXParamKey }) {
            selectedXParamKey = controls.first?.paramId ?? ""
        }
        if selectedYParamKey.isEmpty || !controls.contains(where: { $0.paramId == selectedYParamKey }) {
            // Prefer a parameter different from X when at least two exist.
            let yCandidate = controls.first(where: { $0.paramId != selectedXParamKey }) ?? controls.first
            selectedYParamKey = yCandidate?.paramId ?? ""
        }
    }

    // MARK: - XY Pad Bindings (B.1.4 — dynamic, paramId-driven)

    private func xyBindingX(macro: MacroNode) -> Binding<Float> {
        let key = selectedXParamKey
        let fallback = currentMacroExposedControls.first(where: { $0.paramId == key })?.defaultValue ?? 0.0
        return Binding(
            get: { macro.getParam(key, default: fallback) },
            set: { macro.setParam(key, value: $0) }
        )
    }

    private func xyBindingY(macro: MacroNode) -> Binding<Float> {
        let key = selectedYParamKey
        let fallback = currentMacroExposedControls.first(where: { $0.paramId == key })?.defaultValue ?? 0.0
        return Binding(
            get: { macro.getParam(key, default: fallback) },
            set: { macro.setParam(key, value: $0) }
        )
    }

    private func xyRangeX(macro: MacroNode) -> ClosedRange<Float> {
        currentMacroExposedControls.first(where: { $0.paramId == selectedXParamKey })?.range ?? 0...1
    }

    private func xyRangeY(macro: MacroNode) -> ClosedRange<Float> {
        currentMacroExposedControls.first(where: { $0.paramId == selectedYParamKey })?.range ?? 0...1
    }

    private func xyLabelX(macro: MacroNode) -> String {
        currentMacroExposedControls.first(where: { $0.paramId == selectedXParamKey })?.label ?? "X"
    }

    private func xyLabelY(macro: MacroNode) -> String {
        currentMacroExposedControls.first(where: { $0.paramId == selectedYParamKey })?.label ?? "Y"
    }

    // MARK: - Step Grid Section

    private var stepGridSection: some View {
        VStack(spacing: DS.spacingSM) {
            HStack {
                LRSectionHeader(title: "STEP SEQUENCER", color: DS.neonTurquesa.opacity(0.6))
                Spacer()
                stepAdvanceControls
            }

            stepGridPads

            if engine.selectedStepIndices.count > 1 {
                batchSelectionBar
            } else if let stepIdx = engine.pLockEditingStepIndex {
                stepEditBar(stepIndex: stepIdx)
            } else {
                Text("TAP a step to edit · SHIFT+TAP to multi-select")
                    .font(DS.font(DS.fontCaption2))
                    .foregroundColor(DS.textTertiary.opacity(0.5))
                    .padding(.top, DS.spacingXS)
            }
        }
        .padding(.horizontal, DS.spacingXL)
        .padding(.vertical, DS.spacingSM)
    }

    private var stepAdvanceControls: some View {
        HStack(spacing: DS.spacingXS) {
            if let stepGrid = engine.focusStepGrid {
                LRSegmentPicker(
                    items: StepGrid.StepAdvanceMode.allCases,
                    selected: stepGrid.advanceMode,
                    color: DS.neonTurquesa,
                    labelForItem: { $0.rawValue.uppercased() },
                    onSelect: { mode in
                        // Update through the sequencer node
                        if let sequencer = engine.focusSequencerNode {
                            sequencer.stepGrid.advanceMode = mode
                            engine.syncStepTimer()
                        }
                    }
                )
                .help("How steps advance: MANUAL = tap, TIME = BPM, ITERATION = cycles")

                if stepGrid.advanceMode == .manual {
                    LRToggle(
                        label: "TAP",
                        isActive: true,
                        activeColor: DS.neonAmbar,
                        helpText: "Advance to next step"
                    ) {
                        if let macro = engine.focusMacro {
                            engine.advanceLaneManually(lane: macro)
                        }
                    }
                }

                // C.1 — Advance-rate / BPM / chain-length controls bound
                // directly to the focus SequencerNode parameters.
                sequencerRateControls(stepGrid: stepGrid)
            }
        }
    }

    /// C.1 — Numeric controls for the SequencerNode's `chainLength`,
    /// `stepTimeBPM` and `stepAdvanceDivisor`. The controls always reflect
    /// the focus macro's sequencer; mutations go through the node so the
    /// engine timer resyncs immediately.
    @ViewBuilder
    private func sequencerRateControls(stepGrid: StepGrid) -> some View {
        HStack(spacing: DS.spacingSM) {
            stepperReadout(
                label: "LEN",
                value: stepGrid.chainLength,
                range: 1...StepGrid.maxSteps,
                color: DS.neonTurquesa,
                help: "Active step count (1...\(StepGrid.maxSteps)). Pattern loops over this many steps."
            ) { newValue in
                guard let sequencer = engine.focusSequencerNode else { return }
                sequencer.stepGrid.chainLength = newValue
                sequencer.parameters["chainLength"] = newValue
            }

            if stepGrid.advanceMode == .time {
                stepperReadout(
                    label: "BPM",
                    value: stepGrid.stepTimeBPM,
                    range: LRConstants.stepTimeBPMRange.lowerBound...LRConstants.stepTimeBPMRange.upperBound,
                    color: DS.neonAmbar,
                    help: "Beats per minute for TIME advance mode."
                ) { newValue in
                    guard let sequencer = engine.focusSequencerNode else { return }
                    sequencer.stepGrid.stepTimeBPM = newValue
                    sequencer.parameters["stepTimeBPM"] = newValue
                    engine.syncStepTimer()
                }
            }

            if stepGrid.advanceMode == .iteration {
                stepperReadout(
                    label: "÷",
                    value: stepGrid.stepAdvanceDivisor,
                    range: 1...32,
                    color: DS.neonAmbar,
                    help: "Advance one step every N feedback iterations."
                ) { newValue in
                    guard let sequencer = engine.focusSequencerNode else { return }
                    sequencer.stepGrid.stepAdvanceDivisor = max(1, newValue)
                    sequencer.parameters["stepAdvanceDivisor"] = max(1, newValue)
                }
            }
        }
    }

    /// Compact `-/+` stepper readout used by `sequencerRateControls`.
    @ViewBuilder
    private func stepperReadout(
        label: String,
        value: Int,
        range: ClosedRange<Int>,
        color: Color,
        help: String,
        onChange: @escaping (Int) -> Void
    ) -> some View {
        HStack(spacing: 2) {
            Text(label)
                .font(DS.font(DS.fontCaption2, weight: .bold))
                .foregroundColor(color.opacity(0.8))

            Button(action: {
                let next = max(range.lowerBound, value - 1)
                if next != value { onChange(next) }
            }) {
                Text("−")
                    .font(DS.font(DS.fontCaption, weight: .bold))
                    .foregroundColor(color)
                    .frame(width: 16, height: 16)
                    .background(color.opacity(0.12))
                    .cornerRadius(2)
            }
            .buttonStyle(.plain)

            Text("\(value)")
                .font(DS.font(DS.fontCaption, weight: .bold))
                .foregroundColor(.white)
                .frame(minWidth: 28)

            Button(action: {
                let next = min(range.upperBound, value + 1)
                if next != value { onChange(next) }
            }) {
                Text("+")
                    .font(DS.font(DS.fontCaption, weight: .bold))
                    .foregroundColor(color)
                    .frame(width: 16, height: 16)
                    .background(color.opacity(0.12))
                    .cornerRadius(2)
            }
            .buttonStyle(.plain)
        }
        .help(help)
    }

    @State private var pressedStepIndex: Int? = nil

    private var stepGridPads: some View {
        let columns = Array(
            repeating: GridItem(.fixed(LRConstants.performanceStepPadSize), spacing: DS.spacingSM),
            count: LRConstants.performanceStepGridColumns
        )

        let stepCount = engine.focusStepGrid?.steps.count ?? 16
        let chainLength = engine.focusStepGrid?.chainLength ?? 16

        return LazyVGrid(columns: columns, spacing: DS.spacingSM) {
            ForEach(0..<stepCount, id: \.self) { index in
                instantStepPad(index: index, chainLength: chainLength)
            }
        }
        // REMOVED: .drawingGroup(opaque: false) -- causes massive input lag
    }

    /// Instant-response step pad using DragGesture (Button has 0.25s delay)
    @ViewBuilder
    private func instantStepPad(index: Int, chainLength: Int) -> some View {
        let step = engine.focusStepGrid?.step(at: index)
        let currentStep = engine.focusStepGrid?.currentStepIndex ?? 0
        let isCurrent = index == currentStep
        let isSelected = engine.selectedStepIndices.contains(index)
        let isPressed = pressedStepIndex == index
        let color = stepColor(for: step?.trigType ?? .note)
        let isActive = index < chainLength

        ZStack {
            // Background with immediate press feedback
            RoundedRectangle(cornerRadius: DS.radiusSM)
                .fill(isPressed ? color.opacity(0.7) :
                      (isCurrent ? color.opacity(0.5) :
                       (isSelected ? color.opacity(0.25) : color.opacity(0.1))))

            Text("\(index + 1)")
                .font(DS.font(DS.fontCaption, weight: .bold))
                .foregroundColor(isCurrent || isPressed ? .white : DS.textSecondary)

            // Lock indicator
            if step?.hasLock == true {
                RoundedRectangle(cornerRadius: 1)
                    .fill(DS.neonAmbar)
                    .frame(width: 2, height: 8)
                    .offset(x: 14, y: 12)
            }

            // Inactive overlay
            if !isActive {
                RoundedRectangle(cornerRadius: DS.radiusSM)
                    .fill(DS.panelHollow.opacity(0.7))
            }
        }
        .frame(width: LRConstants.performanceStepPadSize, height: LRConstants.performanceStepPadSize)
        .overlay(
            RoundedRectangle(cornerRadius: DS.radiusSM)
                .stroke(isPressed ? .white :
                        (isCurrent ? color : (isSelected ? DS.warning : DS.border)),
                        lineWidth: isPressed ? 2 : 1)
        )
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if pressedStepIndex != index && isActive {
                        // Instant animation for immediate feedback
                        withAnimation(.linear(duration: 0.001)) {
                            pressedStepIndex = index
                        }
                    }
                }
                .onEnded { _ in
                    if isActive {
                        pressedStepIndex = nil
                        #if os(macOS)
                        let shift = NSEvent.modifierFlags.contains(.shift)
                        #else
                        let shift = false
                        #endif
                        // C.1 — plain (non-shift) tap toggles the step's
                        // active flag (.skip <-> .note) directly on the
                        // SequencerNode, in addition to focusing it for
                        // p-lock editing. Shift+tap keeps the multi-select
                        // behaviour for batch editing.
                        if !shift {
                            engine.toggleStepActive(at: index)
                        }
                        engine.handleStepTap(index: index, shiftPressed: shift, chainLength: chainLength)
                    }
                }
        )
        .opacity(isActive ? 1.0 : 0.4)
        .help("Step \(index + 1). Tap to edit, SHIFT+tap to multi-select")
        .contextMenu {
            if isActive {
                ForEach(TrigType.allCases, id: \.self) { trig in
                    Button(action: { engine.setStepTrigType(at: index, trig) }) {
                        HStack {
                            Text(trigLabel(trig))
                            if step?.trigType == trig {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
        }
    }

    private func stepColor(for trig: TrigType) -> Color {
        switch trig {
        case .note:    return DS.trigNote
        case .lock:    return DS.trigLock
        case .oneShot: return DS.trigOneShot
        case .skip:    return DS.trigSkip
        }
    }

    private func trigLabel(_ trig: TrigType) -> String {
        switch trig {
        case .note:    return "NOTE (N)"
        case .lock:    return "LOCK (L)"
        case .oneShot: return "ONE-SHOT (1x)"
        case .skip:    return "SKIP (-)"
        }
    }

    private var batchSelectionBar: some View {
        let count = engine.selectedStepIndices.count
        return VStack(spacing: DS.spacingSM) {
            HStack(spacing: DS.spacingMD) {
                Text("\(count) STEPS SELECTED")
                    .font(DS.font(DS.fontCaption2, weight: .bold))
                    .foregroundColor(DS.info)

                Text("TRIG:")
                    .font(DS.font(DS.fontCaption2, weight: .bold))
                    .foregroundColor(DS.textTertiary)

                ForEach(TrigType.allCases, id: \.self) { trig in
                    Button(action: { engine.applyTrigTypeToSelected(trig) }) {
                        Text(trigLabel(trig))
                            .font(DS.font(DS.fontCaption2, weight: .bold))
                            .foregroundColor(DS.info)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(DS.surfaceElevated)
                            .cornerRadius(DS.radiusSM)
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                Button(action: { engine.clearSelectedSteps() }) {
                    Text("CLEAR ALL")
                        .font(DS.font(DS.fontCaption2, weight: .bold))
                        .foregroundColor(DS.danger)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(DS.danger.opacity(0.2))
                        .cornerRadius(DS.radiusSM)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(DS.spacingSM)
        .background(DS.info.opacity(0.08))
        .overlay(RoundedRectangle(cornerRadius: DS.radiusSM).stroke(DS.info.opacity(0.3), lineWidth: 1))
        .padding(.top, DS.spacingSM)
    }

    private func stepEditBar(stepIndex: Int) -> some View {
        let step = engine.focusStepGrid?.step(at: stepIndex)
        return VStack(spacing: DS.spacingSM) {
            HStack(spacing: DS.spacingMD) {
                Text("STEP \(stepIndex + 1) P-LOCK")
                    .font(DS.font(DS.fontCaption2, weight: .bold))
                    .foregroundColor(DS.warning)

                // Trig type picker
                HStack(spacing: 2) {
                    ForEach(TrigType.allCases, id: \.self) { trig in
                        Button(action: { engine.setStepTrigType(at: stepIndex, trig) }) {
                            Text(String(trigLabel(trig).prefix(1)))
                                .font(DS.font(DS.fontCaption2, weight: .bold))
                                .foregroundColor(step?.trigType == trig ? .black : stepColor(for: trig))
                                .frame(width: 20, height: 18)
                                .background(step?.trigType == trig ? stepColor(for: trig) : Color.clear)
                                .overlay(RoundedRectangle(cornerRadius: 2).stroke(stepColor(for: trig).opacity(0.4), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }

                // Probability control
                if step?.trigType != .skip {
                    HStack(spacing: 3) {
                        Text("PROB:")
                            .font(DS.font(DS.fontCaption2, weight: .bold))
                            .foregroundColor(DS.textTertiary)
                        Slider(
                            value: Binding(
                                get: { Double(step?.probability ?? 1.0) },
                                set: { engine.setStepProbability(at: stepIndex, probability: Float($0)) }
                            ),
                            in: 0...1
                        )
                        .accentColor(DS.warning)
                        .frame(width: 60)
                    }
                }

                Spacer()

                LRToggle(
                    label: "CLEAR",
                    isActive: false,
                    activeColor: DS.danger,
                    helpText: "Reset this step"
                ) {
                    engine.clearStep(at: stepIndex)
                }
            }
        }
        .padding(DS.spacingSM)
        .background(DS.warning.opacity(0.05))
        .overlay(RoundedRectangle(cornerRadius: DS.radiusSM).stroke(DS.warning.opacity(0.2), lineWidth: 1))
        .padding(.top, DS.spacingSM)
    }

    // MARK: - Auto-Generated Controls Section

    /// Auto-generated controls from the focus macro's exposedControls.
    /// Uses PerformLayoutEngine to compute adaptive layout.
    private var autoControlsSection: some View {
        let controls = engine.nodeGraph.exposedControls.filter { control in
            control.nodeId == engine.focusMacro?.id
        }
        let layout = PerformLayoutEngine.compute(for: controls)

        return VStack(spacing: DS.spacingSM) {
            HStack {
                LRSectionHeader(
                    title: "CONTROLS",
                    trailing: "\(controls.count) EXPOSED",
                    trailingColor: DS.neonTurquesa.opacity(0.6)
                )
                Spacer()
            }

            if controls.isEmpty {
                emptyControlsPlaceholder
            } else {
                VStack(spacing: DS.spacingSM) {
                    ForEach(layout.rows) { row in
                        HStack(spacing: DS.spacingSM) {
                            ForEach(row.items) { item in
                                layoutItemView(item, knobSize: layout.knobSize)
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, DS.spacingXL)
        .padding(.vertical, DS.spacingSM)
    }

    private var emptyControlsPlaceholder: some View {
        RoundedRectangle(cornerRadius: DS.radiusSM)
            .fill(DS.panelHollow)
            .frame(height: 80)
            .overlay(
                VStack(spacing: DS.spacingXS) {
                    Text("NO EXPOSED CONTROLS")
                        .font(DS.font(DS.fontCaption, weight: .bold))
                        .foregroundColor(DS.textTertiary)
                    Text("Expose parameters in PATCH mode to see them here")
                        .font(DS.font(DS.fontCaption2))
                        .foregroundColor(DS.textDisabled)
                }
            )
    }

    @ViewBuilder
    private func layoutItemView(_ item: LayoutItem, knobSize: CGFloat) -> some View {
        if item.controlType == .xyPad, let xControl = item.xControl, let yControl = item.yControl {
            // XY Pad control
            VStack(spacing: 2) {
                Text("\(xControl.label) / \(yControl.label)")
                    .font(DS.font(DS.fontCaption2))
                    .foregroundColor(DS.textTertiary)
                LatentXYPad(
                    x: controlBinding(for: xControl),
                    y: controlBinding(for: yControl),
                    xRange: xControl.range,
                    yRange: yControl.range,
                    xLabel: xControl.label.prefix(3).uppercased(),
                    yLabel: yControl.label.prefix(3).uppercased()
                )
                .frame(width: knobSize * 2, height: knobSize)
            }
        } else {
            // Knob control
            VStack(spacing: 2) {
                RetroKnob(
                    label: item.control.label,
                    value: controlBinding(for: item.control),
                    range: item.control.range
                )
                .frame(width: knobSize, height: knobSize)

                Text(item.control.label)
                    .font(DS.font(DS.fontCaption2))
                    .foregroundColor(DS.textTertiary)
                    .lineLimit(1)
            }
        }
    }

    private func controlBinding(for control: ExposedControl) -> Binding<Float> {
        Binding(
            get: {
                // First try to get from node directly (works with or without macros)
                if let nodeValue = engine.nodeGraph.getParameter(nodeId: control.nodeId, key: control.paramId) as? Float {
                    return nodeValue
                }
                // Fallback to macro if exists
                if let macro = engine.focusMacro {
                    return macro.getParam(control.paramId, default: control.defaultValue)
                }
                return control.defaultValue
            },
            set: { newValue in
                // Update node graph parameter directly (always works)
                engine.nodeGraph.setParameter(
                    nodeId: control.nodeId,
                    key: control.paramId,
                    value: newValue
                )

                // Also update macro if one is focused (for macro-based graphs)
                engine.focusMacro?.setParam(control.paramId, value: newValue)
            }
        )
    }

    // MARK: - Active Macros Section

    private var activeMacrosSection: some View {
        VStack(spacing: DS.spacingSM) {
            HStack {
                LRSectionHeader(
                    title: "ACTIVE MACROS",
                    trailing: "\(engine.macroNodes.count) total",
                    trailingColor: DS.textTertiary
                )
                Spacer()
            }

            if engine.macroNodes.isEmpty {
                Text("No active macros. Create Macro nodes in PATCH mode.")
                    .font(DS.font(DS.fontCaption))
                    .foregroundColor(DS.textDisabled)
                    .padding()
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: DS.spacingSM) {
                    ForEach(engine.macroNodes, id: \.id) { macroNode in
                        macroNodeCard(macroNode)
                    }
                }
            }
        }
        .padding(.horizontal, DS.spacingXL)
        .padding(.vertical, DS.spacingSM)
    }

    private func macroNodeCard(_ macroNode: MacroNode) -> some View {
        let isFocused = engine.focusMacro?.id == macroNode.id
        let nodeCount = macroNode.internalGraph.nodes.count

        return Button(action: {
            engine.focusMacroId = macroNode.id
        }) {
            VStack(alignment: .leading, spacing: DS.spacingXS) {
                HStack {
                    Circle()
                        .fill(isFocused ? DS.neonTurquesa : DS.textTertiary)
                        .frame(width: 6, height: 6)

                    Text(macroNode.name)
                        .font(DS.font(DS.fontCaption, weight: .bold))
                        .foregroundColor(isFocused ? .white : DS.textSecondary)
                        .lineLimit(1)

                    Spacer()

                    Text("\(nodeCount)")
                        .font(DS.font(DS.fontCaption2))
                        .foregroundColor(DS.textTertiary)
                }

                if nodeCount > 0 {
                    Text("\(nodeCount) nodes")
                        .font(DS.font(DS.fontCaption2))
                        .foregroundColor(DS.textDisabled)
                }
            }
            .padding(DS.spacingSM)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isFocused ? DS.neonTurquesa.opacity(0.2) : DS.surfaceSubtle)
            .overlay(
                RoundedRectangle(cornerRadius: DS.radiusSM)
                    .stroke(isFocused ? DS.neonTurquesa : DS.border, lineWidth: isFocused ? 2 : 1)
            )
            .cornerRadius(DS.radiusSM)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Trigger Button

    private var triggerButton: some View {
        Group {
            if engine.isProcessing {
                if engine.canAbort {
                    LRActionButton(
                        label: "ABORT",
                        icon: "stop.fill",
                        color: DS.danger,
                        style: .primary
                    ) {
                        engine.toggleProcessing(initiatedFromPerformMode: true)
                    }
                } else {
                    HStack(spacing: 10) {
                        ProgressView()
                            .scaleEffect(0.7)
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        Text("INITIATING")
                            .font(DS.font(DS.fontHeadline, weight: .bold))
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
                    label: "INITIATE",
                    icon: "waveform.path",
                    color: DS.danger,
                    style: .destructive
                ) {
                    engine.toggleProcessing(initiatedFromPerformMode: true)
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
                .font(DS.font(DS.fontCaption, weight: .medium))
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

    // MARK: - Status Bar (B.1.2)

    /// Bottom status strip showing: bridge process state, current BPM (from
    /// the focus sequencer when present), the focus macro's name, and
    /// whether audio processing is on. Updates live via SwiftUI observation
    /// of `@Published` properties on `engine`.
    private var statusBar: some View {
        HStack(spacing: DS.spacingMD) {
            // Bridge process state (with colored dot)
            Circle()
                .fill(bridgeStatusColor)
                .frame(width: DS.dotSM, height: DS.dotSM)
            Text("BRIDGE: \(bridgeStatusMessage)")
                .font(DS.font(DS.fontCaption2, weight: .bold))
                .foregroundColor(DS.textTertiary)

            // BPM, read from the focus sequencer (if any) — otherwise the
            // global default. Acts as a live readout, not a control.
            Text("BPM: \(currentBPM)")
                .font(DS.font(DS.fontCaption2, weight: .bold))
                .foregroundColor(DS.neonTurquesa.opacity(0.7))

            // Focus macro name (or — if none)
            Text("MACRO: \(engine.focusMacro?.name.uppercased() ?? "—")")
                .font(DS.font(DS.fontCaption2, weight: .bold))
                .foregroundColor(DS.textSecondary)
                .lineLimit(1)

            Spacer()

            // Processing state
            HStack(spacing: DS.spacingXS) {
                Circle()
                    .fill(engine.isProcessing ? DS.success : DS.textTertiary)
                    .frame(width: DS.dotSM, height: DS.dotSM)
                Text(engine.isProcessing ? "DSP: ON" : "DSP: OFF")
                    .font(DS.font(DS.fontCaption2, weight: .bold))
                    .foregroundColor(engine.isProcessing ? DS.success : DS.textTertiary)
            }

            Text("CYCLES: \(engine.globalCycleCount)")
                .font(DS.font(DS.fontCaption2))
                .foregroundColor(DS.textTertiary.opacity(0.6))

            let currentStep = (engine.focusStepGrid?.currentStepIndex ?? 0) + 1
            let totalSteps = engine.focusStepGrid?.chainLength ?? 16
            Text("STEP: \(currentStep)/\(totalSteps)")
                .font(DS.font(DS.fontCaption2))
                .foregroundColor(DS.textTertiary.opacity(0.6))
        }
        .padding(.horizontal, DS.spacingXL)
        .padding(.bottom, DS.spacingMD)
    }

    /// Color for the bridge status dot, derived from `engine.bridgeProcess.state`.
    private var bridgeStatusColor: Color {
        switch engine.bridgeProcess.state {
        case .running:    return DS.success
        case .launching, .installing, .settingUp, .stopping: return DS.warning
        case .error:      return DS.danger
        case .idle:       return DS.textTertiary
        }
    }

    /// Current BPM as read from the focus sequencer's `stepTimeBPM`, or the
    /// global default when no sequencer is in focus.
    private var currentBPM: Int {
        engine.focusSequencerNode?.stepTimeBPM ?? LRConstants.stepTimeBPMDefault
    }
}