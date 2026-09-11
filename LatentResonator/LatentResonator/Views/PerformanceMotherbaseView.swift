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
    @Binding var showTopologyReservoir: Bool

    @State private var clipboardStep: PerformanceStep? = nil
    @State private var showSequencer = false
    @State private var showScenes = false
    @State private var showMacroBindings = false
    @State private var selectedEnvelopeId: UUID? = nil
    /// Musician P0.1 — per-control ARM state for the step p-lock strip.
    /// Keys are `ExposedControl.id`; presence == armed.
    @State private var armedPLockControls: Set<UUID> = []
    /// Transient feedback after an explicit scene capture + persistence write.
    @State private var sceneSavedFeedback: String? = nil
    /// Current page of the paginated exposed-controls region (Wave C C3).
    @State private var exposedControlsPage: Int = 0
    /// Live XY coordinates for the dedicated Gesture Recorder region (Wave C C4).
    @State private var gestureX: Float = 0.5
    @State private var gestureY: Float = 0.5

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [DS.titanioTop, DS.titanioBottom],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                performHeader
                LRDivider()

                // Fixed, dense PERFORM surface (Wave C C3): no whole-surface ScrollView.
                // Overflow in the exposed-controls region is handled by pagination.
                VStack(spacing: DS.spacingMD) {
                    exposedControlsRegion

                    if hasGestureRecorderNodes {
                        gestureRecorderRegion
                    }

                    if !metaParameterNodes.isEmpty {
                        envelopeEditorSection
                    } else {
                        inactiveSectionNotice(
                            title: "ENVELOPES",
                            color: DS.stageNeural.opacity(0.7),
                            message: "No Meta Parameter nodes in this patch.",
                            hint: "Add a Meta Parameter node (right-click canvas → CONTROL) to sculpt time-varying curves."
                        )
                    }

                    if !engine.macroNodes.isEmpty {
                        macroMixerSection
                    } else {
                        inactiveSectionNotice(
                            title: "MACRO MIXER",
                            color: DS.neonAmbar.opacity(0.7),
                            message: "No Macro nodes in this patch.",
                            hint: "Load a macro topology from the Reservoir, or add a Macro node (right-click canvas → MACRO) to mix lanes."
                        )
                    }

                    performSectionToggle(
                        title: "SEQUENCER",
                        isExpanded: $showSequencer,
                        hint: "Step grid · P-locks · advance modes"
                    )
                    if showSequencer {
                        stepGridSection
                    }

                    performSectionToggle(
                        title: "SCENES",
                        isExpanded: $showScenes,
                        hint: "Scene morph · crossfader · scene bank"
                    )
                    if showScenes {
                        sceneCrossfaderSection
                    }
                }
                .padding(.bottom, DS.spacingSM)
                .frame(maxHeight: .infinity)

                triggerButton
                statusBar
            }
        }
        .onChange(of: engine.focusMacroId) { _, _ in
            engine.selectedStepIndices = []
            exposedControlsPage = 0
        }
        .onChange(of: engine.crossfaderPosition) { _, _ in
            engine.applyCrossfader()
        }
        .sheet(isPresented: $showMacroBindings) {
            MacroBindingsPanel(engine: engine)
        }
    }

    // MARK: - Header

    private var performHeader: some View {
        HStack(spacing: DS.spacingMD) {
            Text("PERFORM")
                .font(DS.font(DS.fontTitle, weight: .bold))
                .foregroundColor(DS.textPrimary)

            Text(engine.nodeGraph.nodes.count > 0
                 ? "\(scopedExposedControls.count) CTRL · \(pagedLayouts.count) PAGE\(pagedLayouts.count == 1 ? "" : "S")"
                 : "NO PATCH")
                .font(DS.font(DS.fontCaption2, weight: .bold))
                .foregroundColor(DS.textTertiary)

            Spacer()

            if engine.isProcessing {
                LRToggle(
                    label: "PANIC",
                    isActive: true,
                    activeColor: DS.danger,
                    helpText: "Emergency stop — immediately halt all audio processing (Esc)"
                ) {
                    engine.stopProcessing()
                }
            }

            Button(action: { showTopologyReservoir = true }) {
                HStack(spacing: DS.spacingXS) {
                    Image(systemName: "square.stack.3d.up")
                        .font(.system(size: 10))
                    Text("RESERVOIR")
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
            .help("Load or save topology from RESERVOIR")

            Button(action: { showMacroBindings = true }) {
                Text("MACROS")
                    .font(DS.font(DS.fontCaption, weight: .bold))
                    .foregroundColor(DS.neonAmbar)
                    .padding(.horizontal, DS.spacingSM)
                    .padding(.vertical, DS.togglePaddingV)
                    .background(DS.neonAmbar.opacity(0.12))
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.radiusSM)
                            .stroke(DS.neonAmbar.opacity(0.4), lineWidth: 1)
                    )
                    .cornerRadius(DS.radiusSM)
            }
            .buttonStyle(.plain)
            .help("Map exposed controls to multiple parameters")

            LRToggle(
                label: engine.isMasterRecording ? "REC ●" : "REC",
                isActive: engine.isMasterRecording,
                activeColor: DS.danger,
                helpText: "Master record — capture output to WAV (R)"
            ) {
                engine.toggleMasterRecording()
            }
        }
        .padding(.horizontal, DS.spacingXL)
        .padding(.vertical, DS.spacingSM)
    }

    /// Collapsed-by-default section affordance — keeps Elektron theater out of the way.
    private func performSectionToggle(title: String, isExpanded: Binding<Bool>, hint: String) -> some View {
        Button(action: { isExpanded.wrappedValue.toggle() }) {
            HStack(spacing: DS.spacingSM) {
                Image(systemName: isExpanded.wrappedValue ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(DS.textTertiary)
                    .frame(width: 12)
                Text(title)
                    .font(DS.font(DS.fontCaption, weight: .bold))
                    .foregroundColor(DS.textSecondary)
                Text(hint)
                    .font(DS.font(DS.fontCaption2))
                    .foregroundColor(DS.textDisabled)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, DS.spacingXL)
            .padding(.vertical, DS.spacingXS)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Stage Controls (Envion §3.1 + §3.5)

    private var scopedExposedControls: [ExposedControl] {
        if let macro = engine.focusMacro {
            return engine.nodeGraph.exposedControls.filter { control in
                control.nodeId == macro.id || macro.internalGraph.nodes.keys.contains(control.nodeId)
            }
        }
        return engine.nodeGraph.exposedControls
    }

    private var metaParameterNodes: [MetaParameterNode] {
        engine.nodeGraph.nodes.values.compactMap { $0 as? MetaParameterNode }
    }

    private var pagedLayouts: [PerformLayout] {
        PerformLayoutEngine.computePages(for: scopedExposedControls)
    }

    private var hasGestureRecorderNodes: Bool {
        engine.nodeGraph.nodes.values.contains { $0 as? GestureRecorderNode != nil }
    }

    // MARK: - Fixed Exposed-Controls Region (Wave C C3)

    /// Paginated, fixed-region control surface. No ScrollView — overflow is
    /// handled by page buttons, keeping the instrument as one dense panel.
    private var exposedControlsRegion: some View {
        VStack(spacing: DS.spacingSM) {
            if pagedLayouts.isEmpty {
                emptyControlsPlaceholder
                    .padding(.horizontal, DS.spacingXL)
            } else {
                let layouts = pagedLayouts
                let page = max(0, min(exposedControlsPage, layouts.count - 1))
                let activeLayout = layouts.isEmpty ? nil : layouts[page]

                if layouts.count > 1 {
                    HStack(spacing: DS.spacingSM) {
                        Text("PAGE")
                            .font(DS.font(DS.fontCaption2, weight: .bold))
                            .foregroundColor(DS.textTertiary)
                        ForEach(0..<layouts.count, id: \.self) { idx in
                            Button {
                                exposedControlsPage = idx
                            } label: {
                                Text("\(idx + 1)")
                                    .font(DS.font(DS.fontCaption2, weight: .bold))
                                    .foregroundColor(idx == page ? .black : DS.textTertiary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(idx == page ? DS.neonAmbar : DS.surfaceSubtle)
                                    .cornerRadius(2)
                            }
                            .buttonStyle(.plain)
                        }
                        Spacer()
                        Text("\(scopedExposedControls.count) CTRL")
                            .font(DS.font(DS.fontCaption2, weight: .bold))
                            .foregroundColor(DS.textTertiary)
                    }
                    .padding(.horizontal, DS.spacingXL)
                }

                if let activeLayout = activeLayout {
                    VStack(spacing: DS.spacingSM) {
                        ForEach(activeLayout.rows) { row in
                            HStack(spacing: DS.spacingSM) {
                                ForEach(row.items) { item in
                                    layoutItemView(item, knobSize: activeLayout.knobSize)
                                }
                                Spacer(minLength: 0)
                            }
                        }
                    }
                    .padding(.horizontal, DS.spacingXL)
                    .padding(.vertical, DS.spacingXS)
                    .background(DS.surfaceElevated.opacity(0.2))
                    .cornerRadius(DS.radiusSM)
                }
            }
        }
    }

    // MARK: - Gesture Recorder XY Region (Wave C C4)

    /// Dedicated compact XY pad that feeds any recording GestureRecorderNode.
    /// Collapses to zero size when no gesture recorder exists in the graph.
    private var gestureRecorderRegion: some View {
        VStack(spacing: DS.spacingSM) {
            HStack(spacing: DS.spacingSM) {
                Rectangle()
                    .fill(DS.neonTurquesa)
                    .frame(width: 3, height: 14)
                Text("GESTURE")
                    .font(DS.font(DS.fontCaption, weight: .bold))
                    .foregroundColor(DS.neonTurquesa)
                Spacer()
            }
            .padding(.horizontal, DS.spacingXL)

            let xBinding = Binding<Float>(
                get: { gestureX },
                set: { gestureX = $0 }
            )
            let yBinding = Binding<Float>(
                get: { gestureY },
                set: { gestureY = $0 }
            )

            LatentXYPad(
                x: xBinding,
                y: yBinding,
                xRange: 0.0...1.0,
                yRange: 0.0...1.0,
                xLabel: "X",
                yLabel: "Y",
                onCommit: {
                    feedRecordingGestureNodes(x: gestureX, y: gestureY, pressure: 1.0)
                },
                onDragEnded: {
                    feedRecordingGestureNodes(x: gestureX, y: gestureY, pressure: 0.0)
                }
            )
            .frame(height: PerformMetrics.gesturePadHeight)
            .padding(.horizontal, DS.spacingXL)
        }
        .padding(.vertical, DS.spacingXS)
        .background(DS.surfaceElevated.opacity(0.2))
        .cornerRadius(DS.radiusSM)
    }

    /// Breakpoint envelope editor for MetaParameter nodes (§3.4 — D3).
    private var envelopeEditorSection: some View {
        VStack(alignment: .leading, spacing: DS.spacingSM) {
            HStack {
                LRSectionHeader(title: "ENVELOPES", color: DS.stageNeural.opacity(0.7))
                Spacer()
                Text("\(metaParameterNodes.count) active")
                    .font(DS.font(DS.fontCaption2, weight: .bold))
                    .foregroundColor(DS.textTertiary)
            }
            .padding(.horizontal, DS.spacingXL)

            ForEach(metaParameterNodes, id: \.id) { node in
                envelopeEditorRow(node: node)
            }
        }
        .padding(.vertical, DS.spacingXS)
        .background(DS.surfaceElevated.opacity(0.15))
    }

    private func envelopeEditorRow(node: MetaParameterNode) -> some View {
        let isOpen = selectedEnvelopeId == node.id
        return VStack(alignment: .leading, spacing: DS.spacingXS) {
            Button(action: {
                selectedEnvelopeId = isOpen ? nil : node.id
            }) {
                HStack(spacing: DS.spacingMD) {
                    Text(node.name.uppercased())
                        .font(DS.font(DS.fontCaption2, weight: .bold))
                        .foregroundColor(DS.textSecondary)
                        .frame(width: 100, alignment: .leading)
                    Text(String(format: "%.1fs", node.duration))
                        .font(DS.font(DS.fontCaption2, weight: .medium))
                        .foregroundColor(DS.neonTurquesa.opacity(0.8))
                    Text(node.loopMode ? "LOOP" : "ONE-SHOT")
                        .font(DS.font(DS.fontCaption2, weight: .bold))
                        .foregroundColor(DS.textTertiary)
                    Text("\(node.breakpoints.count) BP")
                        .font(DS.font(DS.fontCaption2))
                        .foregroundColor(DS.textDisabled)
                    Spacer()
                    Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(DS.textTertiary)
                }
                .padding(.horizontal, DS.spacingXL)
                .padding(.vertical, DS.spacingXS)
            }
            .buttonStyle(.plain)

            if isOpen {
                VStack(alignment: .leading, spacing: DS.spacingSM) {
                    // P5 Slice 1 + Slice 2 — envelope visualization + drag-to-edit.
                    // The curve is the interface: live breakpoint shape
                    // (honoring each segment's CurveType) + a vertical
                    // playhead driven by the node's live `phase`. Slice 2
                    // layers drag-to-edit on top: drag a vertex to move it,
                    // drag the curve body to insert a new breakpoint,
                    // double-click a vertex to delete it. Edits route through
                    // the MetaParameterNode public mutation API and trigger
                    // `objectWillChange.send()` on the node graph — the same
                    // pattern the slider row below uses. The view polls
                    // `node.phase` at 60Hz inside its own TimelineView, so
                    // re-renders stay confined to the leaf (no whole-body
                    // 60Hz invalidation — Engineer P1 #3 / Programmer P2 #4).
                    EnvelopeCurveView(
                        breakpoints: node.breakpoints,
                        node: node,
                        duration: node.duration,
                        loopMode: node.loopMode,
                        onEdit: { edit in
                            switch edit {
                            case .move(let id, let t, let v):
                                node.updateBreakpoint(id: id, time: t, value: v)
                            case .insert(let t, let v):
                                _ = node.addBreakpoint(time: t, value: v)
                            case .delete(let id):
                                node.removeBreakpoint(id: id)
                            }
                            engine.nodeGraph.objectWillChange.send()
                        }
                    )
                    .padding(.horizontal, DS.spacingXL)

                    HStack(spacing: DS.spacingMD) {
                        Toggle("Loop", isOn: Binding(
                            get: { node.loopMode },
                            set: { node.loopMode = $0; engine.nodeGraph.objectWillChange.send() }
                        ))
                        .toggleStyle(.switch)
                        .font(DS.font(DS.fontCaption2))
                        LRParamSlider(
                            label: "DUR",
                            value: Binding(
                                get: { node.duration },
                                set: { node.duration = $0; engine.nodeGraph.objectWillChange.send() }
                            ),
                            range: 0.1...16.0,
                            format: "%.1fs"
                        )
                        Button("TRIG") { node.trigger() }
                            .font(DS.font(DS.fontCaption2, weight: .bold))
                            .foregroundColor(DS.neonTurquesa)
                            .buttonStyle(.plain)
                    }
                    .padding(.horizontal, DS.spacingXL)

                    ForEach(node.breakpoints, id: \.id) { bp in
                        HStack(spacing: DS.spacingSM) {
                            Text(String(format: "t=%.2f", bp.time))
                                .font(DS.font(DS.fontCaption2))
                                .foregroundColor(DS.textTertiary)
                                .frame(width: 52, alignment: .leading)
                            Slider(
                                value: Binding(
                                    get: { bp.value },
                                    set: { newVal in
                                        node.updateBreakpoint(id: bp.id, value: newVal)
                                        engine.nodeGraph.objectWillChange.send()
                                    }
                                ),
                                in: 0...1
                            )
                            // Musician P1.3 — per-breakpoint CurveType picker
                            // (LIN/EXP/LOG/SCRV/STEP). Bound to `bp.curve` via
                            // the public `updateBreakpoint(id:curve:)` API
                            // (ControlNodes.swift:458). 5-segment strip,
                            // reuses LRSegmentPicker styling.
                            LRSegmentPicker(
                                items: CurveType.allCases,
                                selected: bp.curve,
                                color: DS.neonTurquesa,
                                labelForItem: { curveType in
                                    switch curveType {
                                    case .linear:      return "LIN"
                                    case .exponential: return "EXP"
                                    case .logarithmic: return "LOG"
                                    case .sCurve:      return "SCRV"
                                    case .step:        return "STEP"
                                    }
                                },
                                onSelect: { newCurve in
                                    node.updateBreakpoint(id: bp.id, curve: newCurve)
                                    engine.nodeGraph.objectWillChange.send()
                                }
                            )
                            .frame(width: 168)
                            Button("✕") {
                                node.removeBreakpoint(id: bp.id)
                                engine.nodeGraph.objectWillChange.send()
                            }
                            .font(DS.font(DS.fontCaption2, weight: .bold))
                            .foregroundColor(DS.danger)
                            .buttonStyle(.plain)
                            .disabled(node.breakpoints.count <= 2)
                        }
                        .padding(.horizontal, DS.spacingXL)
                    }

                    Button("+ BREAKPOINT") {
                        let t = Float(node.breakpoints.count) / Float(max(node.breakpoints.count, 1))
                        _ = node.addBreakpoint(time: min(t, 1.0), value: 0.5)
                        engine.nodeGraph.objectWillChange.send()
                    }
                    .font(DS.font(DS.fontCaption2, weight: .bold))
                    .foregroundColor(DS.neonAmbar)
                    .buttonStyle(.plain)
                    .padding(.horizontal, DS.spacingXL)
                }
                .padding(.bottom, DS.spacingSM)
            }
        }
    }

    /// Macro mute/solo when a macro topology is loaded (flat graphs have none).
    private var macroMixerSection: some View {
        VStack(alignment: .leading, spacing: DS.spacingSM) {
            LRSectionHeader(title: "MACRO MIXER", color: DS.neonAmbar.opacity(0.7))
                .padding(.horizontal, DS.spacingXL)

            ForEach(engine.macroNodes, id: \.id) { macro in
                HStack(spacing: DS.spacingMD) {
                    Text(macro.name.uppercased())
                        .font(DS.font(DS.fontCaption2, weight: .bold))
                        .foregroundColor(DS.textSecondary)
                        .frame(width: 120, alignment: .leading)

                    LRToggle(
                        label: "M",
                        isActive: macro.getParam("isMuted", default: false),
                        activeColor: DS.danger,
                        helpText: "Mute macro"
                    ) {
                        let next = !macro.getParam("isMuted", default: false)
                        macro.setParam("isMuted", value: next)
                        engine.updateMacroMixerState()
                    }

                    LRToggle(
                        label: "S",
                        isActive: macro.getParam("isSoloed", default: false),
                        activeColor: DS.neonTurquesa,
                        helpText: "Solo macro"
                    ) {
                        let next = !macro.getParam("isSoloed", default: false)
                        macro.setParam("isSoloed", value: next)
                        engine.updateMacroMixerState()
                    }

                    // P4 — stereo VU meter. Polls `macro.telemetrySnapshot`
                    // (audio-thread-derived peak/RMS, never blocks the UI)
                    // at 30 Hz via an internal TimelineView. The bars are
                    // the meter: no labels, no grid. Sits beside M/S so the
                    // performer sees level next to the mute/solo state.
                    // Musician P1.4: `isProcessing` gates the bars — when
                    // audio is stopped the bars zero + dim so the meter
                    // reads "silent" instead of freezing at its last live
                    // value (false "signal").
                    MacroVUMeter(macro: macro, isProcessing: engine.isProcessing)

                    Spacer()
                }
                .padding(.horizontal, DS.spacingXL)
                .padding(.vertical, DS.spacingXS)
            }
        }
        .padding(.vertical, DS.spacingXS)
        .background(DS.surfaceElevated.opacity(0.12))
    }

    // MARK: - Scene Crossfader Section

    private var sceneCrossfaderSection: some View {
        VStack(spacing: DS.spacingSM) {
            HStack {
                LRSectionHeader(title: "SCENE MORPH", color: DS.neonTurquesa.opacity(0.6))
                Spacer()
                if let feedback = sceneSavedFeedback {
                    Text(feedback.uppercased())
                        .font(DS.font(DS.fontCaption2, weight: .bold))
                        .foregroundColor(DS.success)
                        .task(id: feedback) {
                            try? await Task.sleep(nanoseconds: 2_000_000_000)
                            sceneSavedFeedback = nil
                        }
                }
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

            crossfadeDurationRow
        }
        .padding(.horizontal, DS.spacingXL)
        .padding(.vertical, DS.spacingSM)
    }

    private var crossfadeDurationRow: some View {
        HStack(spacing: DS.spacingMD) {
            Text("XFADE DUR")
                .font(DS.font(DS.fontCaption2, weight: .bold))
                .foregroundColor(DS.textTertiary)
            Slider(
                value: Binding(
                    get: { engine.sceneBank.crossfadeDuration },
                    set: { val in
                        var bank = engine.sceneBank
                        bank.crossfadeDuration = val
                        engine.sceneBank = bank
                    }
                ),
                in: 0.1...10.0
            )
            .accentColor(DS.neonTurquesa.opacity(0.7))
            Text(String(format: "%.1fs", engine.sceneBank.crossfadeDuration))
                .font(DS.font(DS.fontCaption2, weight: .medium))
                .foregroundColor(DS.textSecondary)
                .frame(width: 36, alignment: .trailing)
        }
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

        return HStack(spacing: DS.spacingXS) {
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

            // Save button: separated from the row tap so tapping the arrow no
            // longer ambiguously loads the scene first.
            Button(action: {
                engine.sceneManager.captureScene(at: index, from: engine.nodeGraph)
                engine.savePerformanceState()
                sceneSavedFeedback = "Scenes saved"
            }) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 10))
                    .foregroundColor(DS.textTertiary)
            }
            .buttonStyle(.plain)
            .help("Capture current state to scene \(index + 1)")
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
        .contentShape(Rectangle())
        .onTapGesture {
            engine.sceneManager.applyScene(at: index, to: engine.nodeGraph)
        }
        .help("Tap to load scene \(index + 1); tap the arrow to save")
    }

    // MARK: - Step Grid Section

    private var stepGridSection: some View {
        VStack(spacing: DS.spacingSM) {
            HStack {
                LRSectionHeader(title: "STEP SEQUENCER", color: DS.neonTurquesa.opacity(0.6))
                Spacer()
                stepAdvanceControls
            }

            if engine.focusMacro == nil {
                inactiveNotice(
                    message: "The step grid needs a focused Macro node.",
                    hint: "Add a Macro node (right-click canvas → MACRO) and focus it to drive the 16 pads, p-locks, and advance modes."
                )
            } else {
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
                    armedPLockControls.removeAll()
                }
            }

            // Musician P0.1 — p-lock strip: one mini-slider + ARM toggle per
            // mappable exposed control of the focus macro.
            pLockStrip(stepIndex: stepIndex)
        }
        .padding(DS.spacingSM)
        .background(DS.warning.opacity(0.05))
        .overlay(RoundedRectangle(cornerRadius: DS.radiusSM).stroke(DS.warning.opacity(0.2), lineWidth: 1))
        .padding(.top, DS.spacingSM)
    }

    /// Musician P0.1 — maps an `ExposedControl.paramId` to the corresponding
    /// `Float?` p-lock field on `PerformanceStep`. Exposed controls whose
    /// paramId is not in this map are silently skipped (no p-lock widget).
    /// The map covers the 11+ per-step locks carried by `PerformanceStep`
    /// (cfg, feedback, denoiseStrength, texture, chaos, warmth, filterCutoff,
    /// filterResonance, delayMix, bitCrushDepth) under all common paramId
    /// aliases emitted by `NodeGraph.autoGenerateExposedControls`.
    private static let pLockKeyPaths: [String: WritableKeyPath<PerformanceStep, Float?>] = [
        "cfg":              \PerformanceStep.cfg,
        "guidanceScale":    \PerformanceStep.cfg,
        "feedback":         \PerformanceStep.feedback,
        "denoiseStrength":  \PerformanceStep.denoiseStrength,
        "texture":          \PerformanceStep.texture,
        "chaos":            \PerformanceStep.chaos,
        "warmth":           \PerformanceStep.warmth,
        "filterCutoff":     \PerformanceStep.filterCutoff,
        "cutoff":           \PerformanceStep.filterCutoff,
        "frequency":        \PerformanceStep.filterCutoff,
        "filterResonance":  \PerformanceStep.filterResonance,
        "resonance":        \PerformanceStep.filterResonance,
        "delayMix":         \PerformanceStep.delayMix,
        "mix":              \PerformanceStep.delayMix,
        "bitCrushDepth":    \PerformanceStep.bitCrushDepth
    ]

    /// Generic p-lock strip — one mini-slider + ARM toggle per exposed control
    /// of the focus macro. Armed slider changes dispatch view-side to the
    /// generic `setStepLock(controlId:)` path (Wave C C2). Disarming clears
    /// the lock (writes `nil`).
    @ViewBuilder
    private func pLockStrip(stepIndex: Int) -> some View {
        let mappable = scopedExposedControls
        if !mappable.isEmpty {
            VStack(alignment: .leading, spacing: DS.spacingXS) {
                HStack(spacing: DS.spacingXS) {
                    Text("P-LOCKS")
                        .font(DS.font(DS.fontCaption2, weight: .bold))
                        .foregroundColor(DS.neonAmbar.opacity(0.8))
                        .tracking(DS.trackingLab)
                    Text("\(mappable.count) PARAMS")
                        .font(DS.font(DS.fontCaption2))
                        .foregroundColor(DS.textTertiary.opacity(0.6))
                    Spacer()
                }
                let columns = Array(
                    repeating: GridItem(.flexible(), spacing: DS.spacingSM),
                    count: 4
                )
                LazyVGrid(columns: columns, spacing: DS.spacingXS) {
                    ForEach(mappable) { control in
                        pLockCell(control: control, stepIndex: stepIndex)
                    }
                }
            }
            .padding(DS.spacingSM)
            .background(DS.surfaceElevated.opacity(0.15))
            .overlay(
                RoundedRectangle(cornerRadius: DS.radiusSM)
                    .stroke(DS.border.opacity(0.4), lineWidth: 1)
            )
        }
    }

    /// One generic p-lock cell: label + ARM toggle + mini slider. When armed,
    /// the slider reads the step's generic lock value (or the control default
    /// when the lock is nil) and writes through `engine.setStepLock(controlId:)`.
    /// Disarming clears the generic lock.
    @ViewBuilder
    private func pLockCell(control: ExposedControl, stepIndex: Int) -> some View {
        let isArmed = armedPLockControls.contains(control.id)
        let step = engine.focusStepGrid?.step(at: stepIndex)
        let lockedValue = step?.genericLocks[control.id]
        let range = control.range

        VStack(spacing: 3) {
            HStack(spacing: 4) {
                Text(String(control.label.prefix(4).uppercased()))
                    .font(DS.font(DS.fontCaption2, weight: .bold))
                    .foregroundColor(isArmed ? DS.neonAmbar : DS.textTertiary)
                    .lineLimit(1)
                Spacer()
                Button(action: {
                    if isArmed {
                        armedPLockControls.remove(control.id)
                        engine.setStepLock(at: stepIndex, controlId: control.id, value: nil)
                        engine.objectWillChange.send()
                    } else {
                        armedPLockControls.insert(control.id)
                    }
                }) {
                    Text(isArmed ? "ARM" : "—")
                        .font(DS.font(DS.fontCaption2, weight: .bold))
                        .foregroundColor(isArmed ? .black : DS.textTertiary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(isArmed ? DS.neonAmbar : DS.surfaceSubtle)
                        .overlay(
                            RoundedRectangle(cornerRadius: 2)
                                .stroke(DS.border.opacity(0.5), lineWidth: 1)
                        )
                        .cornerRadius(2)
                }
                .buttonStyle(.plain)
                .help(isArmed ? "Disarm and clear this p-lock" : "Arm to write this p-lock on next change")
            }

            Slider(
                value: Binding(
                    get: {
                        if isArmed { return Double(lockedValue ?? control.defaultValue) }
                        return Double(control.defaultValue)
                    },
                    set: { newVal in
                        guard isArmed else { return }
                        engine.setStepLock(at: stepIndex, controlId: control.id, value: Float(newVal))
                        engine.objectWillChange.send()
                    }
                ),
                in: Double(range.lowerBound)...Double(range.upperBound)
            )
            .accentColor(isArmed ? DS.neonAmbar : DS.textTertiary.opacity(0.4))
            .disabled(!isArmed)
        }
    }

    // MARK: - Control Widgets

    private var emptyControlsPlaceholder: some View {
        RoundedRectangle(cornerRadius: DS.radiusSM)
            .fill(DS.panelHollow)
            .frame(height: 80)
            .overlay(
                VStack(spacing: DS.spacingXS) {
                    Text("NO EXPOSED CONTROLS")
                        .font(DS.font(DS.fontCaption, weight: .bold))
                        .foregroundColor(DS.textTertiary)
                    Text("Right-click a parameter in STAGES and select 'Expose to Perform'.")
                        .font(DS.font(DS.fontCaption2))
                        .foregroundColor(DS.textDisabled)
                }
            )
    }

    @ViewBuilder
    private func layoutItemView(_ item: LayoutItem, knobSize: CGFloat) -> some View {
        if item.controlType == .xyPad, let xControl = item.xControl, let yControl = item.yControl {
            // XY Pad control
            let xBinding = controlBinding(for: xControl)
            let yBinding = controlBinding(for: yControl)
            VStack(spacing: 2) {
                Text("\(xControl.label) / \(yControl.label)")
                    .font(DS.font(DS.fontCaption2))
                    .foregroundColor(DS.textTertiary)
                LatentXYPad(
                    x: xBinding,
                    y: yBinding,
                    xRange: xControl.range,
                    yRange: yControl.range,
                    xLabel: xControl.label.prefix(3).uppercased(),
                    yLabel: yControl.label.prefix(3).uppercased(),
                    onCommit: {
                        feedRecordingGestureNodes(
                            x: xBinding.wrappedValue,
                            y: yBinding.wrappedValue,
                            pressure: 1.0
                        )
                    },
                    onDragEnded: {
                        feedRecordingGestureNodes(
                            x: xBinding.wrappedValue,
                            y: yBinding.wrappedValue,
                            pressure: 0.0
                        )
                    }
                )
                .frame(width: knobSize * 2, height: knobSize)
            }
        } else if item.controlType == .fader {
            // Horizontal fader for parameters inferred as faders.
            VStack(spacing: 2) {
                Text(item.control.label)
                    .font(DS.font(DS.fontCaption2))
                    .foregroundColor(DS.textTertiary)
                    .lineLimit(1)
                Slider(value: controlBinding(for: item.control), in: item.control.range)
                    .accentColor(DS.neonTurquesa)
                    .frame(width: knobSize * 2, height: knobSize)
            }
        } else if item.controlType == .toggle {
            // Toggle switch for boolean-style parameters.
            VStack(spacing: 2) {
                Toggle("", isOn: controlBoolBinding(for: item.control))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .frame(width: knobSize, height: knobSize)
                Text(item.control.label)
                    .font(DS.font(DS.fontCaption2))
                    .foregroundColor(DS.textTertiary)
                    .lineLimit(1)
            }
        } else if item.controlType == .dropdown {
            // Dropdown / menu for enum-style parameters.
            let options = dropdownOptions(for: item.control)
            VStack(spacing: 2) {
                if options.isEmpty {
                    Text(item.control.label)
                        .font(DS.font(DS.fontCaption2))
                        .foregroundColor(DS.textTertiary)
                        .lineLimit(1)
                    Text("—")
                        .font(DS.font(DS.fontCaption2, weight: .bold))
                        .foregroundColor(DS.textSecondary)
                } else {
                    Picker(item.control.label, selection: dropdownBinding(for: item.control)) {
                        ForEach(options, id: \.self) { option in
                            Text(option).tag(option)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: knobSize * 2, height: knobSize)
                    Text(item.control.label)
                        .font(DS.font(DS.fontCaption2))
                        .foregroundColor(DS.textTertiary)
                        .lineLimit(1)
                }
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

    private func controlBoolBinding(for control: ExposedControl) -> Binding<Bool> {
        Binding(
            get: {
                if let boolValue = engine.nodeGraph.getParameterValue(nodeId: control.nodeId, key: control.paramId) as? Bool {
                    return boolValue
                }
                if let floatValue = engine.nodeGraph.getParameter(nodeId: control.nodeId, key: control.paramId) {
                    return floatValue > 0.5
                }
                return control.defaultValue > 0.5
            },
            set: { newValue in
                if engine.nodeGraph.getParameterValue(nodeId: control.nodeId, key: control.paramId) is Bool {
                    engine.nodeGraph.setNodeParameter(nodeId: control.nodeId, paramId: control.paramId, value: newValue)
                } else {
                    engine.nodeGraph.setParameter(nodeId: control.nodeId, key: control.paramId, value: newValue ? Float(1) : Float(0))
                }
                engine.focusMacro?.setParam(control.paramId, value: newValue ? Float(1) : Float(0))
            }
        )
    }

    private func dropdownBinding(for control: ExposedControl) -> Binding<String> {
        Binding(
            get: {
                guard let value = engine.nodeGraph.getParameterValue(nodeId: control.nodeId, key: control.paramId) else { return "" }
                if let mode = value as? FilterMode { return mode.rawValue }
                if let mode = value as? SaturationMode { return mode.rawValue }
                return value as? String ?? ""
            },
            set: { newValue in
                guard let node = engine.nodeGraph.nodes[control.nodeId] else { return }
                switch (node.nodeType, control.paramId) {
                case ("ladder_filter", "mode"):
                    if let mode = FilterMode(rawValue: newValue) {
                        engine.nodeGraph.setNodeParameter(nodeId: control.nodeId, paramId: control.paramId, value: mode)
                    }
                case ("waveshaper", "mode"):
                    if let mode = SaturationMode(rawValue: newValue) {
                        engine.nodeGraph.setNodeParameter(nodeId: control.nodeId, paramId: control.paramId, value: mode)
                    }
                default:
                    engine.nodeGraph.setNodeParameter(nodeId: control.nodeId, paramId: control.paramId, value: newValue)
                }
            }
        )
    }

    private func dropdownOptions(for control: ExposedControl) -> [String] {
        guard let node = engine.nodeGraph.nodes[control.nodeId] else { return [] }
        switch (node.nodeType, control.paramId) {
        case ("ladder_filter", "mode"):
            return FilterMode.allCases.map { $0.rawValue }
        case ("waveshaper", "mode"):
            return SaturationMode.allCases.map { $0.rawValue }
        case ("oscillator", "waveform"):
            return ["sine", "saw", "square", "triangle"]
        default:
            return []
        }
    }

    private func controlBinding(for control: ExposedControl) -> Binding<Float> {
        Binding(
            get: {
                // First try to get from node directly (works with or without macros)
                if let nodeValue = engine.nodeGraph.getParameter(nodeId: control.nodeId, key: control.paramId) {
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

    // MARK: - Gesture Recorder XY Binding (G6)

    /// Feeds any currently-recording `GestureRecorderNode` with the XY pad's
    /// live coordinates. Called on the main thread at the XY pad's throttled
    /// commit rate (~33 Hz) and when the drag ends.
    private func feedRecordingGestureNodes(x: Float, y: Float, pressure: Float) {
        for node in engine.nodeGraph.nodes.values.compactMap({ $0 as? GestureRecorderNode }) {
            guard node.state == .recording else { continue }
            node.inputX = x
            node.inputY = y
            node.inputPressure = pressure
        }
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
        let canRetry = engine.bridgeProcess.state == .error || engine.bridgeProcess.state == .idle
        return HStack(spacing: 10) {
            ProgressView()
                .scaleEffect(0.8)
                .progressViewStyle(CircularProgressViewStyle(tint: DS.neonAmbar))

            Text(bridgeStatusMessage)
                .font(DS.font(DS.fontCaption, weight: .medium))
                .foregroundColor(DS.neonAmbar.opacity(0.9))

            Spacer(minLength: DS.spacingMD)

            if canRetry {
                Button(action: { engine.bridgeProcess.launchServer() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10, weight: .bold))
                        Text("RETRY")
                            .font(DS.font(DS.fontCaption2, weight: .bold))
                            .tracking(DS.trackingLab)
                    }
                    .foregroundColor(.black)
                    .padding(.horizontal, DS.spacingMD)
                    .padding(.vertical, DS.spacingXS)
                    .background(DS.neonAmbar)
                    .cornerRadius(DS.radiusSM)
                }
                .buttonStyle(.plain)
                .help("Relaunch the ACE-Step bridge server")
            }
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

            // Musician P1.2 — seed-armed indicator. One segment next to
            // MACRO; amber when any KoenigSeedNode / koenigSeed OscillatorNode
            // is armed, tertiary gray otherwise. Driven by `engine.anySeedArmed`.
            Text(engine.anySeedArmed ? "SEED: ARMED" : "SEED: —")
                .font(DS.font(DS.fontCaption2, weight: .bold))
                .foregroundColor(engine.anySeedArmed ? DS.neonAmbar : DS.textTertiary)
                .tracking(DS.trackingLab)

            Spacer()

            // Processing state -- 3-way: OFF (not started) / SILENT (started
            // but verifyAudioPipeline() found nothing audible, e.g. amp=0
            // survived the one-shot auto-restore) / ON.
            HStack(spacing: DS.spacingXS) {
                Circle()
                    .fill(processingStateColor)
                    .frame(width: DS.dotSM, height: DS.dotSM)
                Text(processingStateLabel)
                    .font(DS.font(DS.fontCaption2, weight: .bold))
                    .foregroundColor(processingStateColor)
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

    /// A.8: Label for the DSP processing-state dot -- see call site comment.
    private var processingStateLabel: String {
        guard engine.isProcessing else { return "DSP: OFF" }
        if let reason = engine.lastPipelineStatus.silenceReason { return "DSP: SILENT · \(reason)" }
        return "DSP: ON"
    }

    /// A.8: Color for the DSP processing-state dot -- matches `RootView`'s
    /// `silenceBadge` palette (danger red for silent, success green for
    /// audible, tertiary gray for not-yet-started).
    private var processingStateColor: Color {
        guard engine.isProcessing else { return DS.textTertiary }
        if engine.lastPipelineStatus.silenceReason != nil { return DS.danger }
        return DS.success
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

    // MARK: - Inactive section notices
    //
    // Envion-aligned honesty (§3.6): when a PERFORM subsystem has no backing
    // nodes in the current topology, we say so plainly instead of rendering
    // dead controls. Each notice names what is missing and how to get it,
    // so the performer is never left guessing why a section does not respond.

    private func inactiveSectionNotice(
        title: String,
        color: Color,
        message: String,
        hint: String
    ) -> some View {
        VStack(alignment: .leading, spacing: DS.spacingSM) {
            HStack {
                LRSectionHeader(title: title, color: color)
                Spacer()
                Text("INACTIVE")
                    .font(DS.font(DS.fontCaption2, weight: .bold))
                    .foregroundColor(DS.textTertiary)
                    .tracking(DS.trackingLab)
            }
            .padding(.horizontal, DS.spacingXL)

            inactiveNotice(message: message, hint: hint)
        }
        .padding(.vertical, DS.spacingXS)
        .background(DS.surfaceElevated.opacity(0.12))
    }

    private func inactiveNotice(message: String, hint: String) -> some View {
        VStack(alignment: .leading, spacing: DS.spacingXS) {
            Text(message)
                .font(DS.font(DS.fontCaption, weight: .medium))
                .foregroundColor(DS.textSecondary)
            Text(hint)
                .font(DS.font(DS.fontCaption2))
                .foregroundColor(DS.textTertiary.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DS.spacingXL)
        .padding(.vertical, DS.spacingSM)
    }
}

// MARK: - Layout Metrics (Wave C C3)

private enum PerformMetrics {
    static let gesturePadHeight: CGFloat = 120
}