import SwiftUI

// MARK: - Performance Motherbase View
//
// Fixed-layout performance surface: scenes, crossfader, step grid, focus lane.
// No scroll; same controls in same place for muscle memory (Elektron-style).
// Whitepaper §4.2.2, §7.

private typealias DS = LRConstants.DS

struct PerformanceMotherbaseView: View {

    @ObservedObject var engine: NeuralEngine

    @State private var clipboardStep: PerformanceStep? = nil

    // MARK: XY Axis Mode

    enum XYAxisMode: String, CaseIterable {
        case txtChs = "TXT/CHS"
        case cfgFbk = "CFG/FBK"
        case cutRes = "CUT/RES"
    }

    @State private var xyAxisMode: XYAxisMode = .txtChs

    var body: some View {
        ZStack {
            DS.surfacePrimary.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                LRDivider()
                masterXYSection
                    .background(DS.surfaceElevated.opacity(0.5))
                LRDivider()
                crossfaderSection
                LRDivider()
                stepGridSection
                    .background(DS.surfaceElevated.opacity(0.3))
                LRDivider()
                laneTabsSection
                Spacer(minLength: DS.spacingSM)
                triggerButton
                statusBar
            }
        }
        .onChange(of: engine.stepGrid.chainLength) { _, newLen in
            if let idx = engine.pLockEditingStepIndex, idx >= newLen {
                engine.pLockEditingStepIndex = nil
            }
        }
        .onChange(of: engine.stepGrid.advanceMode) { _, _ in
            engine.syncStepTimer()
        }
    }

    // MARK: - Top Bar (+ PANIC button)

    private var topBar: some View {
        HStack(spacing: DS.spacingMD) {
            Text("MOTHERBASE")
                .font(DS.font(DS.fontTitle, weight: .bold))
                .foregroundColor(DS.success.opacity(0.7))

            Circle()
                .fill(engine.aceBridge.status == .modelLoaded ? DS.success : (engine.aceBridge.status == .connected ? DS.warning : DS.textTertiary))
                .frame(width: DS.dotMD, height: DS.dotMD)
            Text(engine.aceBridge.status.rawValue)
                .font(DS.font(DS.fontCaption, weight: .bold))
                .foregroundColor(DS.textSecondary)

            if engine.aceBridge.lastLatencyMs > 0 {
                Text(String(format: "%.0fms", engine.aceBridge.lastLatencyMs))
                    .font(DS.font(DS.fontCaption))
                    .foregroundColor(DS.success.opacity(0.5))
            }

            Spacer()

            if engine.isProcessing {
                LRToggle(label: "PANIC", isActive: true, activeColor: DS.danger) {
                    engine.stopProcessing()
                }
            }

            Button(action: { engine.toggleMasterRecording() }) {
                HStack(spacing: 3) {
                    Circle()
                        .fill(engine.isMasterRecording ? DS.danger : DS.textDisabled)
                        .frame(width: DS.dotMD, height: DS.dotMD)
                    Text("REC")
                        .font(DS.font(DS.fontCaption2, weight: .bold))
                        .foregroundColor(engine.isMasterRecording ? DS.danger : DS.textTertiary)
                }
                .padding(.horizontal, DS.spacingSM)
                .padding(.vertical, DS.spacingXS)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .animation(DS.stateTransition, value: engine.isMasterRecording)
        }
        .padding(.horizontal, DS.spacingXL)
        .padding(.vertical, DS.spacingMD)
    }

    // MARK: - Master XY (Focus Lane) -- Configurable Axes

    private var masterXYSection: some View {
        VStack(spacing: DS.spacingSM) {
            HStack(spacing: 0) {
                Text("DRIFT // FOCUS LANE")
                    .font(DS.font(DS.fontCaption, weight: .bold))
                    .foregroundColor(DS.success.opacity(0.5))
                Spacer()
                xyAxisModePicker
            }
            if let lane = engine.focusLane {
                LatentXYPad(
                    x: xyBindingX(lane: lane),
                    y: xyBindingY(lane: lane),
                    xRange: xyRangeX,
                    yRange: xyRangeY,
                    xLabel: xyLabelX,
                    yLabel: xyLabelY,
                    onDragStarted: xyAxisMode == .txtChs ? {
                        lane.suppressMacroApplication = true
                    } : nil,
                    onDragEnded: xyAxisMode == .txtChs ? {
                        lane.suppressMacroApplication = false
                        lane.applyMacroTexture()
                        lane.applyMacroChaos()
                    } : nil
                )
            } else {
                RoundedRectangle(cornerRadius: DS.radiusSM)
                    .fill(Color.black.opacity(0.5))
                    .frame(height: LRConstants.xyPadHeight)
                    .overlay(Text("NO LANE").font(DS.font(DS.fontBody)).foregroundColor(DS.textTertiary))
            }
        }
        .padding(.horizontal, DS.spacingXL)
        .padding(.vertical, DS.spacingMD)
    }

    private var xyAxisModePicker: some View {
        LRSegmentPicker(
            items: XYAxisMode.allCases,
            selected: xyAxisMode,
            color: DS.success,
            labelForItem: { $0.rawValue },
            onSelect: { xyAxisMode = $0 }
        )
        .frame(width: 200)
    }

    private func xyBindingX(lane: ResonatorLane) -> Binding<Float> {
        switch xyAxisMode {
        case .txtChs: return Binding(get: { lane.texture }, set: { lane.texture = $0 })
        case .cfgFbk: return Binding(get: { lane.guidanceScale }, set: { lane.guidanceScale = $0 })
        case .cutRes: return Binding(get: { lane.filterCutoff }, set: { lane.filterCutoff = $0 })
        }
    }

    private func xyBindingY(lane: ResonatorLane) -> Binding<Float> {
        switch xyAxisMode {
        case .txtChs: return Binding(get: { lane.chaos }, set: { lane.chaos = $0 })
        case .cfgFbk: return Binding(get: { lane.feedbackAmount }, set: { lane.feedbackAmount = $0 })
        case .cutRes: return Binding(get: { lane.filterResonance }, set: { lane.filterResonance = $0 })
        }
    }

    private var xyRangeX: ClosedRange<Float> {
        switch xyAxisMode {
        case .txtChs: return LRConstants.macroRange
        case .cfgFbk: return LRConstants.cfgScaleRange
        case .cutRes: return LRConstants.filterCutoffRange
        }
    }

    private var xyRangeY: ClosedRange<Float> {
        switch xyAxisMode {
        case .txtChs: return LRConstants.macroRange
        case .cfgFbk: return LRConstants.feedbackRange
        case .cutRes: return LRConstants.filterResonanceRange
        }
    }

    private var xyLabelX: String {
        switch xyAxisMode {
        case .txtChs: return "TXT"
        case .cfgFbk: return "CFG"
        case .cutRes: return "CUT"
        }
    }

    private var xyLabelY: String {
        switch xyAxisMode {
        case .txtChs: return "CHS"
        case .cfgFbk: return "FBK"
        case .cutRes: return "RES"
        }
    }

    // MARK: - Crossfader + Scenes -- Independent A/B Selection

    private var crossfaderSection: some View {
        VStack(spacing: DS.spacingMD) {
            HStack(spacing: DS.spacingMD) {
                Text("A")
                    .font(DS.font(DS.fontCaption, weight: .bold))
                    .foregroundColor(DS.info)
                    .frame(width: 12)

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        // Gradient track: Scene A color -> Scene B color
                        RoundedRectangle(cornerRadius: 3)
                            .fill(LinearGradient(
                                colors: [DS.info.opacity(0.4), DS.warning.opacity(0.4)],
                                startPoint: .leading,
                                endPoint: .trailing
                            ))
                            .frame(height: 6)
                            .frame(maxWidth: .infinity)
                            .offset(y: (geo.size.height - 6) / 2)

                        // Thumb indicator
                        let thumbX = CGFloat(engine.crossfaderPosition) * (geo.size.width - 14)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(DS.textPrimary)
                            .frame(width: 14, height: 18)
                            .offset(x: thumbX, y: (geo.size.height - 18) / 2)
                    }
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let pos = Float(min(max(value.location.x / geo.size.width, 0), 1))
                                engine.crossfaderPosition = pos
                                engine.applyCrossfader()
                            }
                    )
                    .overlay(
                        ScrollWheelCatcher { delta in
                            let newVal = Double(engine.crossfaderPosition) + delta * 0.003
                            engine.crossfaderPosition = Float(min(1, max(0, newVal)))
                            engine.applyCrossfader()
                        }
                    )
                }
                .frame(height: 22)

                Text("B")
                    .font(DS.font(DS.fontCaption, weight: .bold))
                    .foregroundColor(DS.warning)
                    .frame(width: 12)
            }

            // Blend position readout
            HStack {
                Text(String(format: "A: %d%%", Int((1 - engine.crossfaderPosition) * 100)))
                    .font(DS.font(DS.fontCaption2, weight: .medium))
                    .foregroundColor(DS.info.opacity(0.5))
                Spacer()
                Text(String(format: "B: %d%%", Int(engine.crossfaderPosition * 100)))
                    .font(DS.font(DS.fontCaption2, weight: .medium))
                    .foregroundColor(DS.warning.opacity(0.5))
            }

            sceneRowAB
            crossfadeDurationControl
        }
        .padding(.horizontal, DS.spacingXL)
        .padding(.vertical, DS.spacingMD)
    }

    private var sceneRowAB: some View {
        VStack(spacing: 3) {
            sceneRow(label: "A", selectedIndex: engine.crossfaderSceneAIndex) { index in
                engine.crossfaderSceneAIndex = index
                engine.applyScene(at: index)
                engine.crossfaderPosition = 0
            }
            sceneRow(label: "B", selectedIndex: engine.crossfaderSceneBIndex) { index in
                engine.crossfaderSceneBIndex = index
                engine.crossfaderPosition = 1
            }
        }
    }

    private func sceneRow(label: String, selectedIndex: Int, onTap: @escaping (Int) -> Void) -> some View {
        HStack(spacing: DS.spacingSM) {
            Text(label)
                .font(DS.font(DS.fontCaption, weight: .bold))
                .foregroundColor(DS.success.opacity(0.5))
                .frame(width: 10)
            ForEach(0..<min(8, engine.sceneBank.scenes.count), id: \.self) { index in
                Button(action: { onTap(index) }) {
                    Text("\(index + 1)")
                        .font(DS.font(DS.fontCaption, weight: .bold))
                        .foregroundColor(selectedIndex == index ? .black : DS.success.opacity(0.6))
                        .frame(width: 24, height: 22)
                        .background(selectedIndex == index ? DS.success : Color.gray.opacity(DS.inactiveOpacity))
                        .overlay(RoundedRectangle(cornerRadius: DS.radiusSM).stroke(DS.success.opacity(0.4), lineWidth: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.5)
                        .onEnded { [engine] _ in
                            DispatchQueue.main.async { engine.captureCurrentToScene(at: index) }
                        }
                )
                .animation(DS.stateTransition, value: selectedIndex)
            }
        }
    }

    private var crossfadeDurationControl: some View {
        HStack(spacing: DS.spacingMD) {
            Text("XFADE")
                .font(DS.font(DS.fontCaption2, weight: .bold))
                .foregroundColor(DS.textTertiary)
            Slider(
                value: Binding(
                    get: { engine.sceneBank.crossfadeDuration },
                    set: { [engine] val in
                        DispatchQueue.main.async {
                            var bank = engine.sceneBank
                            bank.crossfadeDuration = val
                            engine.sceneBank = bank
                        }
                    }
                ),
                in: 0.1...10.0
            )
            .accentColor(DS.success.opacity(0.6))
            .scrollableSlider(value: Binding(
                get: { engine.sceneBank.crossfadeDuration },
                set: { var b = engine.sceneBank; b.crossfadeDuration = $0; engine.sceneBank = b }
            ), range: 0.1...10.0)
            Text(String(format: "%.1fs", engine.sceneBank.crossfadeDuration))
                .font(DS.font(DS.fontCaption2, weight: .medium))
                .foregroundColor(DS.textSecondary)
                .frame(width: 28, alignment: .trailing)
        }
    }

    // MARK: - Step Grid -- Trig-Coded Pads + P-Lock Header

    private var stepGridSection: some View {
        VStack(spacing: DS.spacingSM) {
            HStack {
                LRSectionHeader(title: "STEP GRID", color: DS.success.opacity(0.5))
                chainLengthControl
                Spacer()
                stepAdvanceModePicker
            }

            let columns = Array(repeating: GridItem(.fixed(LRConstants.performanceStepPadSize), spacing: DS.spacingSM), count: LRConstants.performanceStepGridColumns)
            LazyVGrid(columns: columns, spacing: DS.spacingSM) {
                ForEach(0..<engine.stepGrid.steps.count, id: \.self) { index in
                    stepPad(index: index)
                }
            }

            if let idx = engine.pLockEditingStepIndex, idx >= 0, idx < engine.stepGrid.chainLength {
                pLockHeaderBar(stepIndex: idx)
            } else {
                Text("TAP A STEP TO EDIT P-LOCKS  ·  RIGHT-CLICK TO SET TRIG TYPE")
                    .font(DS.font(DS.fontCaption2, weight: .medium))
                    .foregroundColor(DS.textTertiary.opacity(0.5))
                    .padding(.top, DS.spacingXS)
            }
        }
        .padding(.horizontal, DS.spacingXL)
        .padding(.vertical, DS.spacingMD)
    }

    private var chainLengthControl: some View {
        HStack(spacing: 3) {
            Text("LEN:")
                .font(DS.font(DS.fontCaption2, weight: .bold))
                .foregroundColor(DS.textTertiary)
            Text("\(engine.stepGrid.chainLength)")
                .font(DS.font(DS.fontCaption2, weight: .bold))
                .foregroundColor(DS.success)
                .frame(width: 18)
            Button(action: {
                let newLen = max(LRConstants.chainLengthRange.lowerBound, engine.stepGrid.chainLength - 1)
                engine.stepGrid.chainLength = newLen
            }) {
                Text("-")
                    .font(DS.font(DS.fontCaption, weight: .bold))
                    .foregroundColor(DS.textSecondary)
                    .frame(width: 18, height: 18)
                    .background(Color.gray.opacity(DS.inactiveOpacity))
                    .cornerRadius(DS.radiusSM)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button(action: {
                let newLen = min(LRConstants.chainLengthRange.upperBound, engine.stepGrid.chainLength + 1)
                engine.stepGrid.chainLength = newLen
            }) {
                Text("+")
                    .font(DS.font(DS.fontCaption, weight: .bold))
                    .foregroundColor(DS.textSecondary)
                    .frame(width: 18, height: 18)
                    .background(Color.gray.opacity(DS.inactiveOpacity))
                    .cornerRadius(DS.radiusSM)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var stepAdvanceModePicker: some View {
        HStack(spacing: DS.spacingXS) {
            LRSegmentPicker(
                items: StepGrid.StepAdvanceMode.allCases,
                selected: engine.stepGrid.advanceMode,
                color: DS.success,
                labelForItem: { $0.rawValue.uppercased() },
                onSelect: { mode in
                    DispatchQueue.main.async { [engine] in
                        var grid = engine.stepGrid
                        grid.advanceMode = mode
                        engine.stepGrid = grid
                    }
                }
            )

            if engine.stepGrid.advanceMode == .manual {
                LRToggle(label: "TAP", isActive: true, activeColor: DS.warning) {
                    DispatchQueue.main.async { [engine] in
                        let chain = engine.stepGrid.chainLength
                        guard chain > 0 else { return }
                        let next = (engine.stepGrid.currentStepIndex + 1) % chain
                        var grid = engine.stepGrid
                        grid.currentStepIndex = next
                        engine.stepGrid = grid
                        engine.applyCurrentStepLocks()
                    }
                }
            }

            if engine.stepGrid.advanceMode == .time {
                bpmControl
            }
        }
    }

    private var bpmControl: some View {
        HStack(spacing: 3) {
            Text("BPM:")
                .font(DS.font(DS.fontCaption2, weight: .bold))
                .foregroundColor(DS.textTertiary)
            Button(action: {
                var grid = engine.stepGrid
                grid.stepTimeBPM = max(grid.stepTimeBPM - 10, LRConstants.stepTimeBPMRange.lowerBound)
                engine.stepGrid = grid
                engine.syncStepTimer()
            }) {
                Text("-")
                    .font(DS.font(DS.fontCaption, weight: .bold))
                    .foregroundColor(DS.textPrimary)
                    .frame(width: 20, height: 20)
                    .background(DS.surfaceElevated)
                    .cornerRadius(DS.radiusSM)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Text("\(engine.stepGrid.stepTimeBPM)")
                .font(DS.font(DS.fontCaption, weight: .bold))
                .foregroundColor(DS.success)
                .frame(width: 36)
            Button(action: {
                var grid = engine.stepGrid
                grid.stepTimeBPM = min(grid.stepTimeBPM + 10, LRConstants.stepTimeBPMRange.upperBound)
                engine.stepGrid = grid
                engine.syncStepTimer()
            }) {
                Text("+")
                    .font(DS.font(DS.fontCaption, weight: .bold))
                    .foregroundColor(DS.textPrimary)
                    .frame(width: 20, height: 20)
                    .background(DS.surfaceElevated)
                    .cornerRadius(DS.radiusSM)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Step Pad (color-coded by trig type)

    private func trigColor(for step: PerformanceStep, isActive: Bool) -> Color {
        guard isActive else { return Color.gray }
        switch step.trigType {
        case .note:    return DS.trigNote
        case .lock:    return DS.trigLock
        case .oneShot: return DS.trigOneShot
        case .skip:    return DS.trigSkip
        }
    }

    private func stepPad(index: Int) -> some View {
        let step = engine.stepGrid.step(at: index) ?? PerformanceStep()
        let isActive = index < engine.stepGrid.chainLength
        let isCurrent = index == engine.stepGrid.currentStepIndex
        let isSelected = index == engine.pLockEditingStepIndex
        let color = trigColor(for: step, isActive: isActive)

        return Button(action: {
            guard isActive else { return }
            if engine.pLockEditingStepIndex == index {
                engine.pLockEditingStepIndex = nil
            } else {
                engine.pLockEditingStepIndex = index
            }
        }) {
            ZStack {
                RoundedRectangle(cornerRadius: DS.radiusSM)
                    .fill(isCurrent ? color.opacity(0.5) : (isSelected ? color.opacity(0.25) : color.opacity(0.08)))
                VStack(spacing: 1) {
                    Text("\(index + 1)")
                        .font(DS.font(DS.fontCaption, weight: .bold))
                        .foregroundColor(isCurrent ? .white : DS.textSecondary)
                    if let prob = step.probability, prob < 1.0 {
                        Text("\(Int(prob * 100))%")
                            .font(DS.font(DS.fontCaption2, weight: .medium))
                            .foregroundColor(DS.warning.opacity(0.8))
                    }
                }
                if step.hasLock {
                    lockIndicatorDots(step: step)
                        .offset(x: 8, y: -12)
                }
                if !isActive {
                    RoundedRectangle(cornerRadius: DS.radiusSM)
                        .fill(Color.black.opacity(0.5))
                }
            }
            .frame(width: LRConstants.performanceStepPadSize, height: LRConstants.performanceStepPadSize)
            .overlay(RoundedRectangle(cornerRadius: DS.radiusSM)
                .stroke(isCurrent ? color : (isSelected ? DS.warning : DS.border), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(DS.stateTransition, value: isCurrent)
        .contextMenu {
            if isActive {
                ForEach(TrigType.allCases, id: \.self) { trig in
                    Button(action: { engine.setStepTrigType(at: index, trig) }) {
                        HStack {
                            Text(trigLabel(trig))
                            if step.trigType == trig {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
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

    // MARK: Lock Indicator Dots

    private func lockIndicatorDots(step: PerformanceStep) -> some View {
        Group {
            if step.lockCount <= 3 {
                HStack(spacing: 1) {
                    if step.cfg != nil         { Circle().fill(DS.warning).frame(width: 3, height: 3) }
                    if step.feedback != nil     { Circle().fill(DS.info).frame(width: 3, height: 3) }
                    if step.promptPhase != nil  { Circle().fill(DS.paramPhase).frame(width: 3, height: 3) }
                    if step.denoiseStrength != nil { Circle().fill(DS.paramDenoise.opacity(0.6)).frame(width: 3, height: 3) }
                    if step.texture != nil      { Circle().fill(DS.trigNote).frame(width: 3, height: 3) }
                    if step.chaos != nil        { Circle().fill(DS.info).frame(width: 3, height: 3) }
                    if step.warmth != nil       { Circle().fill(DS.trigNote.opacity(0.6)).frame(width: 3, height: 3) }
                    if step.filterCutoff != nil  { Circle().fill(DS.trigLock).frame(width: 3, height: 3) }
                    if step.filterResonance != nil { Circle().fill(DS.trigLock.opacity(0.7)).frame(width: 3, height: 3) }
                    if step.excitationMode != nil { Circle().fill(DS.success).frame(width: 3, height: 3) }
                    if step.delayMix != nil     { Circle().fill(DS.paramDelay).frame(width: 3, height: 3) }
                    if step.bitCrushDepth != nil { Circle().fill(DS.paramCrush.opacity(0.7)).frame(width: 3, height: 3) }
                }
            } else {
                Text("\(step.lockCount)L")
                    .font(DS.font(DS.fontCaption2, weight: .bold))
                    .foregroundColor(DS.warning)
            }
        }
    }

    // MARK: P-Lock Header Bar

    private func pLockHeaderBar(stepIndex: Int) -> some View {
        let step = engine.stepGrid.step(at: stepIndex) ?? PerformanceStep()
        return VStack(spacing: DS.spacingSM) {
            HStack(spacing: DS.spacingMD) {
                Text("STEP \(stepIndex + 1) P-LOCK")
                    .font(DS.font(DS.fontCaption2, weight: .bold))
                    .foregroundColor(DS.warning.opacity(0.8))

                trigTypeMiniPicker(stepIndex: stepIndex, current: step.trigType)

                probabilityControl(stepIndex: stepIndex, probability: step.probability)

                Spacer()

                LRToggle(label: "COPY", isActive: false, activeColor: DS.info) {
                    clipboardStep = engine.stepGrid.step(at: stepIndex)
                }
                LRToggle(label: "PASTE", isActive: clipboardStep != nil, activeColor: DS.info) {
                    if let clip = clipboardStep {
                        engine.stepGrid.setStep(clip, at: stepIndex)
                    }
                }
                LRToggle(label: "CLEAR", isActive: false, activeColor: DS.danger) {
                    engine.clearStep(at: stepIndex)
                }
            }
        }
        .padding(DS.spacingSM)
        .background(DS.warning.opacity(0.05))
        .overlay(RoundedRectangle(cornerRadius: DS.radiusSM).stroke(DS.warning.opacity(0.2), lineWidth: 1))
        .padding(.top, DS.spacingSM)
    }

    private func trigTypeMiniPicker(stepIndex: Int, current: TrigType) -> some View {
        HStack(spacing: 2) {
            trigMiniButton("N",  trig: .note,    current: current, stepIndex: stepIndex)
            trigMiniButton("L",  trig: .lock,    current: current, stepIndex: stepIndex)
            trigMiniButton("1x", trig: .oneShot, current: current, stepIndex: stepIndex)
            trigMiniButton("-",  trig: .skip,    current: current, stepIndex: stepIndex)
        }
    }

    private func trigMiniButton(_ label: String, trig: TrigType, current: TrigType, stepIndex: Int) -> some View {
        let isActive = trig == current
        let color = trigColor(for: PerformanceStep(trigType: trig), isActive: true)
        return Button(action: { engine.setStepTrigType(at: stepIndex, trig) }) {
            Text(label)
                .font(DS.font(DS.fontCaption2, weight: .bold))
                .foregroundColor(isActive ? .black : color.opacity(0.7))
                .frame(width: 22, height: 18)
                .background(isActive ? color : Color.clear)
                .overlay(RoundedRectangle(cornerRadius: 2).stroke(color.opacity(0.4), lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func probabilityControl(stepIndex: Int, probability: Float?) -> some View {
        HStack(spacing: 3) {
            Text("PROB:")
                .font(DS.font(DS.fontCaption2, weight: .bold))
                .foregroundColor(DS.textTertiary)
            Slider(
                value: Binding(
                    get: { Double(probability ?? 1.0) },
                    set: { val in
                        let f = Float(val)
                        engine.setStepProbability(at: stepIndex, probability: f >= 1.0 ? nil : f)
                    }
                ),
                in: 0...1
            )
            .accentColor(DS.warning.opacity(0.6))
            .scrollableSlider(value: Binding(
                get: { Double(probability ?? 1.0) },
                set: { let f = Float($0); engine.setStepProbability(at: stepIndex, probability: f >= 1.0 ? nil : f) }
            ), range: 0...1)
            .frame(width: 80)
            Text(probability != nil ? "\(Int((probability ?? 1) * 100))%" : "--")
                .font(DS.font(DS.fontCaption2, weight: .medium))
                .foregroundColor(DS.textSecondary)
                .frame(width: 28, alignment: .trailing)
        }
    }

    // MARK: - Lane Tabs + Focus Lane Strip

    private var laneTabsSection: some View {
        VStack(spacing: DS.spacingSM) {
            laneTabRow
            if let lane = engine.focusLane {
                focusLaneStrip(lane: lane)
            }
        }
        .padding(.horizontal, DS.spacingXL)
        .padding(.vertical, DS.spacingMD)
    }

    private var laneTabRow: some View {
        HStack(spacing: DS.spacingSM) {
            ForEach(engine.lanes) { lane in
                let isFocus = engine.focusLaneId == lane.id
                Button(action: { engine.focusLaneId = lane.id }) {
                    VStack(spacing: DS.spacingXS) {
                        HStack(spacing: 3) {
                            Text(String(lane.name.prefix(5)))
                                .font(DS.font(DS.fontCaption, weight: .bold))
                                .foregroundColor(isFocus ? .black : DS.success.opacity(0.6))
                            Text("i\(lane.iterationCount)")
                                .font(DS.font(DS.fontCaption2, weight: .medium))
                                .foregroundColor(isFocus ? .black.opacity(0.6) : DS.textTertiary)
                        }
                        HStack(spacing: DS.spacingXS) {
                            Button(action: { lane.isMuted.toggle(); engine.updateLaneMixerState() }) {
                                Text("M")
                                    .font(DS.font(DS.fontCaption2, weight: .bold))
                                    .foregroundColor(lane.isMuted ? DS.danger : DS.textTertiary)
                                    .frame(width: 20, height: 20)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Button(action: { lane.isSoloed.toggle(); engine.updateLaneMixerState() }) {
                                Text("S")
                                    .font(DS.font(DS.fontCaption2, weight: .bold))
                                    .foregroundColor(lane.isSoloed ? DS.warning : DS.textTertiary)
                                    .frame(width: 20, height: 20)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, DS.spacingMD)
                    .padding(.vertical, DS.spacingSM)
                    .frame(minWidth: 60)
                    .background(isFocus ? DS.success : Color.gray.opacity(DS.inactiveOpacity))
                    .cornerRadius(3)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(isFocus ? DS.success : DS.border, lineWidth: 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .animation(DS.stateTransition, value: isFocus)
            }
            Spacer()
        }
    }

    // MARK: Focus Lane Performance Strip (Context-Aware P-Lock Knobs)

    /// Creates a binding that reads/writes from a step lock when editing, or from the lane directly otherwise.
    /// The getter reads live from `engine.stepGrid` (not a captured snapshot) to avoid stale values during fast knob turns.
    private func pLockBinding(
        lane: ResonatorLane,
        stepIndex: Int?,
        laneGet: @escaping () -> Float,
        laneSet: @escaping (Float) -> Void,
        lockKeyPath: WritableKeyPath<PerformanceStep, Float?>
    ) -> Binding<Float> {
        if let idx = stepIndex {
            return Binding(
                get: { [engine] in
                    engine.stepGrid.step(at: idx)?[keyPath: lockKeyPath] ?? laneGet()
                },
                set: { [engine] in engine.setStepLock(at: idx, lockKeyPath, value: $0) }
            )
        }
        return Binding(get: laneGet, set: laneSet)
    }

    private func focusLaneStrip(lane: ResonatorLane) -> some View {
        let editIdx = engine.pLockEditingStepIndex
        let isEditing = editIdx != nil
        let knobSize: CGFloat = 48

        return VStack(spacing: DS.spacingSM) {
            // Row 1: Core sound-shaping (always visible)
            HStack(spacing: DS.spacingSM) {
                RetroKnob(
                    label: isEditing ? "CFG [L]" : "CFG",
                    value: pLockBinding(lane: lane, stepIndex: editIdx,
                                        laneGet: { lane.guidanceScale },
                                        laneSet: { lane.guidanceScale = $0 },
                                        lockKeyPath: \.cfg),
                    range: LRConstants.cfgScaleRange,
                    accentColor: isEditing ? .orange.opacity(0.7) : .orange,
                    size: knobSize
                )
                RetroKnob(
                    label: isEditing ? "FBK [L]" : "FBK",
                    value: pLockBinding(lane: lane, stepIndex: editIdx,
                                        laneGet: { lane.feedbackAmount },
                                        laneSet: { lane.feedbackAmount = $0 },
                                        lockKeyPath: \.feedback),
                    range: LRConstants.feedbackRange,
                    accentColor: isEditing ? .cyan.opacity(0.7) : .cyan,
                    size: knobSize
                )
                RetroKnob(
                    label: isEditing ? "CUT [L]" : "CUT",
                    value: pLockBinding(lane: lane, stepIndex: editIdx,
                                        laneGet: { lane.filterCutoff },
                                        laneSet: { lane.filterCutoff = $0 },
                                        lockKeyPath: \.filterCutoff),
                    range: LRConstants.filterCutoffRange,
                    accentColor: isEditing ? DS.warning.opacity(0.7) : DS.warning,
                    size: knobSize
                )
                RetroKnob(
                    label: isEditing ? "RES [L]" : "RES",
                    value: pLockBinding(lane: lane, stepIndex: editIdx,
                                        laneGet: { lane.filterResonance },
                                        laneSet: { lane.filterResonance = $0 },
                                        lockKeyPath: \.filterResonance),
                    range: LRConstants.filterResonanceRange,
                    accentColor: isEditing ? DS.warning.opacity(0.7) : DS.warning.opacity(0.8),
                    size: knobSize
                )
                RetroKnob(
                    label: isEditing ? "TXT [L]" : "TXT",
                    value: pLockBinding(lane: lane, stepIndex: editIdx,
                                        laneGet: { lane.texture },
                                        laneSet: { lane.texture = $0 },
                                        lockKeyPath: \.texture),
                    range: LRConstants.macroRange,
                    accentColor: isEditing ? .orange.opacity(0.6) : .orange.opacity(0.8),
                    size: knobSize
                )
                RetroKnob(
                    label: isEditing ? "CHS [L]" : "CHS",
                    value: pLockBinding(lane: lane, stepIndex: editIdx,
                                        laneGet: { lane.chaos },
                                        laneSet: { lane.chaos = $0 },
                                        lockKeyPath: \.chaos),
                    range: LRConstants.macroRange,
                    accentColor: isEditing ? .cyan.opacity(0.6) : .cyan.opacity(0.8),
                    size: knobSize
                )
                RetroKnob(
                    label: isEditing ? "WRM [L]" : "WRM",
                    value: pLockBinding(lane: lane, stepIndex: editIdx,
                                        laneGet: { lane.warmth },
                                        laneSet: { lane.warmth = $0 },
                                        lockKeyPath: \.warmth),
                    range: LRConstants.macroRange,
                    accentColor: isEditing ? .red.opacity(0.7) : .red.opacity(0.8),
                    size: knobSize
                )
                VStack(spacing: DS.spacingXS) {
                    focusLaneVolume(lane: lane)
                }
            }

            // Row 2: Effects + FX (always visible)
            HStack(spacing: DS.spacingSM) {
                RetroKnob(
                    label: isEditing ? "DLY [L]" : "DLY",
                    value: pLockBinding(lane: lane, stepIndex: editIdx,
                                        laneGet: { lane.delayMix },
                                        laneSet: { lane.delayMix = $0 },
                                        lockKeyPath: \.delayMix),
                    range: LRConstants.delayMixRange,
                    accentColor: isEditing ? DS.paramDelay.opacity(0.6) : DS.paramDelay.opacity(0.8),
                    size: knobSize
                )
                RetroKnob(
                    label: isEditing ? "CRUSH [L]" : "CRUSH",
                    value: pLockBinding(lane: lane, stepIndex: editIdx,
                                        laneGet: { lane.bitCrushDepth },
                                        laneSet: { lane.bitCrushDepth = $0 },
                                        lockKeyPath: \.bitCrushDepth),
                    range: LRConstants.bitCrushRange,
                    accentColor: isEditing ? DS.paramCrush.opacity(0.6) : DS.paramCrush.opacity(0.8),
                    size: knobSize
                )
                RetroKnob(
                    label: "D.TIME",
                    value: Binding(get: { lane.delayTime }, set: { lane.delayTime = $0 }),
                    range: LRConstants.delayTimeRange,
                    accentColor: DS.paramDelay.opacity(0.6),
                    size: knobSize
                )
                RetroKnob(
                    label: "D.FBK",
                    value: Binding(get: { lane.delayFeedback }, set: { lane.delayFeedback = $0 }),
                    range: LRConstants.delayFeedbackRange,
                    accentColor: DS.paramDelay.opacity(0.6),
                    size: knobSize
                )
                RetroKnob(
                    label: "ENT",
                    value: Binding(get: { lane.entropyLevel }, set: { lane.entropyLevel = $0 }),
                    range: LRConstants.entropyRange,
                    accentColor: DS.info.opacity(0.7),
                    size: knobSize
                )
                RetroKnob(
                    label: "GRAN",
                    value: Binding(get: { lane.granularity }, set: { lane.granularity = $0 }),
                    range: LRConstants.granularityRange,
                    accentColor: DS.info.opacity(0.7),
                    size: knobSize
                )
                Spacer()
            }

            // Row 3: Toggles + Phase + Excitation
            HStack(spacing: DS.spacingMD) {
                promptPhaseControl(lane: lane)
                Spacer()
                LRToggle(label: "FREEZE", isActive: lane.spectralFreezeActive, activeColor: .blue) {
                    DispatchQueue.main.async { lane.spectralFreezeActive.toggle() }
                }
                LRToggle(
                    label: lane.inferMethod.uppercased(),
                    isActive: lane.inferMethod == "sde",
                    activeColor: DS.warning
                ) {
                    DispatchQueue.main.async {
                        lane.inferMethod = (lane.inferMethod == "ode") ? "sde" : "ode"
                    }
                }
            }

            excitationModePicker(lane: lane)
        }
        .padding(DS.spacingMD)
        .background(Color.white.opacity(0.02))
        .overlay(RoundedRectangle(cornerRadius: DS.radiusMD).stroke(
            isEditing ? DS.warning.opacity(0.4) : DS.success.opacity(0.3), lineWidth: 1))
    }

    private func focusLaneVolume(lane: ResonatorLane) -> some View {
        VStack(spacing: DS.spacingXS) {
            Text("VOL")
                .font(DS.font(DS.fontCaption2, weight: .bold))
                .foregroundColor(DS.textTertiary)
            Slider(
                value: Binding(get: { lane.volume }, set: { lane.volume = $0 }),
                in: 0...1
            )
            .accentColor(DS.success)
            .scrollableSlider(value: Binding(get: { lane.volume }, set: { lane.volume = $0 }), range: 0...1)
            .frame(width: 60)
            .onChange(of: lane.volume) { _, _ in
                DispatchQueue.main.async { engine.updateLaneMixerState() }
            }
        }
    }

    private func promptPhaseControl(lane: ResonatorLane) -> some View {
        HStack(spacing: 3) {
            Text("PHASE")
                .font(DS.font(DS.fontCaption2, weight: .bold))
                .foregroundColor(DS.paramPhase.opacity(0.6))
            ForEach(1...3, id: \.self) { phase in
                LRToggle(
                    label: "P\(phase)",
                    isActive: lane.promptPhaseOverride == phase,
                    activeColor: .purple
                ) {
                    DispatchQueue.main.async {
                        if lane.promptPhaseOverride == phase {
                            lane.promptPhaseOverride = nil
                        } else {
                            lane.promptPhaseOverride = phase
                        }
                    }
                }
            }
        }
    }

    private func excitationModePicker(lane: ResonatorLane) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LRSegmentPicker(
                items: ExcitationMode.allCases,
                selected: lane.excitationMode,
                color: DS.success,
                labelForItem: { $0.rawValue },
                onSelect: { mode in
                    DispatchQueue.main.async { lane.excitationMode = mode }
                }
            )
        }
    }

    // MARK: - Trigger + Status

    private var triggerButton: some View {
        Group {
            if engine.isProcessing {
                if engine.canAbort {
                    LRActionButton(label: "ABORT", icon: "stop.fill", color: DS.danger, style: .primary) {
                        engine.toggleProcessing()
                    }
                } else {
                    HStack(spacing: 10) {
                        ProgressView().scaleEffect(0.7).progressViewStyle(CircularProgressViewStyle(tint: .white))
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
                LRActionButton(label: "START", icon: "waveform.path", color: DS.danger, style: .destructive) {
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
                .font(DS.font(DS.fontCaption, weight: .medium))
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

    private var statusBar: some View {
        HStack(spacing: DS.spacingMD) {
            Text("[ U N B R A N D E D ]")
                .font(DS.font(DS.fontCaption2, weight: .bold))
                .foregroundColor(DS.textDisabled)

            Spacer()

            Text("CYCLES: \(engine.globalCycleCount)")
                .font(DS.font(DS.fontCaption2, weight: .bold))
                .foregroundColor(DS.success.opacity(0.5))
            Text("STEP: \(engine.stepGrid.currentStepIndex + 1)/\(engine.stepGrid.chainLength)")
                .font(DS.font(DS.fontCaption2))
                .foregroundColor(DS.textTertiary)
            Text("MODE: \(engine.stepGrid.advanceMode.rawValue.uppercased())")
                .font(DS.font(DS.fontCaption2))
                .foregroundColor(DS.textTertiary)
        }
        .padding(.horizontal, DS.spacingXL)
        .padding(.bottom, DS.spacingMD)
    }
}
