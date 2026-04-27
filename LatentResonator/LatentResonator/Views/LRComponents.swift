import SwiftUI
import AppKit

// MARK: - LR Design System Components
//
// Reusable UI primitives. No state, no wiring changes.

private typealias DS = LRConstants.DS

// MARK: - LRToggle
//
// Binary toggle button with consistent styling.
// Used for: M(ute), S(olo), FREEZE, TRIGLESS, REC, ODE/SDE.

struct LRToggle: View {

    let label: String
    let isActive: Bool
    let activeColor: Color
    var fullWidth: Bool = false
    var helpText: String? = nil
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(DS.font(DS.fontBody, weight: .bold))
                .foregroundColor(isActive ? .black : DS.textTertiary)
                .frame(maxWidth: fullWidth ? .infinity : nil)
                .padding(.horizontal, DS.togglePaddingH)
                .padding(.vertical, DS.togglePaddingV)
                .background(isActive ? activeColor.opacity(DS.activeOpacity) : DS.surfaceSubtle)
                .overlay(
                    RoundedRectangle(cornerRadius: DS.toggleCornerRadius)
                        .stroke(
                            isActive
                                ? activeColor.opacity(0.6)
                                : (isHovered ? DS.borderActive : DS.border),
                            lineWidth: 1
                        )
                )
                .cornerRadius(DS.toggleCornerRadius)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in isHovered = hovering }
        .animation(DS.stateTransition, value: isActive)
        .ifLet(helpText) { view, text in view.help(text) }
        .accessibilityLabel(label)
        .accessibilityValue(isActive ? "On" : "Off")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - LRSegmentPicker
//
// Horizontal segmented picker with consistent styling.
// Used for: ExcitationMode, FilterMode, SaturationMode, LFOTarget,
//           XYAxisMode, StepAdvanceMode, Phase selectors.

struct LRSegmentPicker<Item: Hashable>: View {

    let items: [Item]
    let selected: Item
    let color: Color
    let labelForItem: (Item) -> String
    let onSelect: (Item) -> Void

    var body: some View {
        HStack(spacing: DS.spacingXS) {
            ForEach(items, id: \.self) { item in
                LRSegmentButton(
                    label: labelForItem(item),
                    isSelected: item == selected,
                    color: color
                ) {
                    onSelect(item)
                }
            }
        }
    }
}

private struct LRSegmentButton: View {

    let label: String
    let isSelected: Bool
    let color: Color
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(DS.font(DS.fontCaption, weight: .bold))
                .foregroundColor(isSelected ? .black : DS.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, DS.togglePaddingV)
                .background(isSelected ? color.opacity(DS.activeOpacity) : DS.surfaceSubtle)
                .overlay(
                    RoundedRectangle(cornerRadius: DS.toggleCornerRadius)
                        .stroke(
                            isSelected
                                ? color.opacity(0.6)
                                : (isHovered ? DS.borderActive : DS.border),
                            lineWidth: 1
                        )
                )
                .cornerRadius(DS.toggleCornerRadius)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in isHovered = hovering }
        .animation(DS.stateTransition, value: isSelected)
        .accessibilityLabel(label)
        .accessibilityValue(isSelected ? "Selected" : "")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - LRStatusRow
//
// Single-line status indicator: [dot] LABEL: VALUE | optional extras.
// Used for: bridge process status, ACE-STEP status, lane running state.

struct LRStatusRow: View {

    let dotColor: Color
    let label: String
    let value: String
    var valueColor: Color = DS.textSecondary
    var extras: [(String, Color)] = []
    var errorText: String? = nil

    var body: some View {
        HStack(spacing: DS.spacingMD) {
            Circle()
                .fill(dotColor)
                .frame(width: DS.dotSM, height: DS.dotSM)
                .shadow(color: dotColor.opacity(0.35), radius: 1)

            Text(label)
                .font(DS.font(DS.fontCaption, weight: .bold))
                .foregroundColor(DS.textTertiary)

            Text(value)
                .font(DS.font(DS.fontCaption, weight: .bold))
                .foregroundColor(valueColor)

            ForEach(Array(extras.indices), id: \.self) { idx in
                Text(extras[idx].0)
                    .font(DS.font(DS.fontCaption, weight: .medium))
                    .foregroundColor(extras[idx].1)
            }

            Spacer()

            if let err = errorText {
                Text(err.prefix(35))
                    .font(DS.font(DS.fontCaption2))
                    .foregroundColor(DS.danger.opacity(0.5))
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }
}

// MARK: - LRSectionHeader
//
// Consistent section header with tracking and optional right-aligned content.

struct LRSectionHeader: View {

    let title: String
    var color: Color = DS.textTertiary
    var trailing: String? = nil
    var trailingColor: Color = DS.textTertiary

    var body: some View {
        HStack {
            Text(title)
                .font(DS.font(DS.fontCaption, weight: .bold))
                .foregroundColor(color)
                .tracking(DS.trackingLab)
            Spacer()
            if let trailing = trailing {
                Text(trailing)
                    .font(DS.font(DS.fontCaption, weight: .bold))
                    .foregroundColor(trailingColor)
            }
        }
    }
}

// MARK: - LRDivider (Panel Line)
//
// 2px sunken channel: panelHollow + bottom bevel.

struct LRDivider: View {
    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(DS.panelHollow)
                .frame(height: 1)
            Rectangle()
                .fill(DS.panelBevel)
                .frame(height: 1)
        }
        .frame(height: DS.panelDividerHeight)
    }
}

// MARK: - LRActionButton
//
// Trigger-style action button (INITIATE, ABORT, PANIC, DETAIL, REMOVE).

struct LRActionButton: View {

    enum Style { case primary, destructive, ghost }

    let label: String
    var icon: String? = nil
    var color: Color = DS.danger
    var style: Style = .primary
    var helpText: String? = nil
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.spacingMD) {
                if let icon = icon {
                    Image(systemName: icon).font(.system(size: DS.fontHeadline))
                }
                Text(label)
                    .font(DS.font(DS.fontHeadline, weight: .bold))
                    .tracking(2)
            }
            .foregroundColor(foregroundColor)
            .frame(maxWidth: .infinity)
            .padding(.vertical, DS.spacingLG)
            .background(backgroundColor)
            .overlay(Rectangle().stroke(color, lineWidth: style == .ghost ? 0 : 2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in isHovered = hovering }
        .ifLet(helpText) { view, text in view.help(text) }
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isButton)
    }

    private var foregroundColor: Color {
        switch style {
        case .primary:     return .black
        case .destructive: return color
        case .ghost:       return color.opacity(isHovered ? 0.8 : 0.5)
        }
    }

    private var backgroundColor: Color {
        switch style {
        case .primary:     return color
        case .destructive: return DS.titanioBottom
        case .ghost:       return Color.clear
        }
    }
}

// MARK: - LRParamSlider
//
// Consistent parameter slider with label and value readout.
// Supports scroll wheel / trackpad input for precise adjustment.

struct LRParamSlider: View {

    let label: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    var format: String = "%.1f"
    var multiplier: Float = 1.0
    var color: Color = DS.success
    var hint: String? = nil
    var isHighImpact: Bool = false

    var body: some View {
        HStack(spacing: DS.spacingMD) {
            HStack(spacing: DS.spacingXS) {
                if isHighImpact {
                    Rectangle()
                        .fill(color.opacity(0.6))
                        .frame(width: 2, height: 12)
                        .cornerRadius(1)
                }
                Text(label)
                    .font(DS.font(DS.fontCaption2, weight: .bold))
                    .foregroundColor(DS.textTertiary)
            }
            .frame(width: 86, alignment: .leading)
            Slider(value: $value, in: range)
                .accentColor(color)
                .overlay(
                    ScrollWheelCatcher { delta in
                        let span = range.upperBound - range.lowerBound
                        let step = Float(delta) * span * 0.003
                        value = min(range.upperBound, max(range.lowerBound, value + step))
                    }
                )
            Text(String(format: format, value * multiplier))
                .font(DS.font(DS.fontCaption, weight: .medium))
                .foregroundColor(color.opacity(0.7))
                .frame(width: 54, alignment: .trailing)
        }
        .ifLet(hint) { view, text in view.help(text) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(String(format: format, value * multiplier))
        .accessibilityAdjustableAction { direction in
            let span = range.upperBound - range.lowerBound
            let step = span * 0.05
            switch direction {
            case .increment:
                value = min(range.upperBound, value + step)
            case .decrement:
                value = max(range.lowerBound, value - step)
            @unknown default: break
            }
        }
    }
}

// MARK: - Scroll Wheel Catcher (macOS)
//
// Transparent NSView overlay that intercepts scrollWheel events from
// trackpad or mouse and forwards the vertical delta to the caller.
// Used by RetroKnob and LRParamSlider for precision input.

struct ScrollWheelCatcher: NSViewRepresentable {

    let onScroll: (CGFloat) -> Void

    func makeNSView(context: Context) -> ScrollWheelNSView {
        let view = ScrollWheelNSView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ nsView: ScrollWheelNSView, context: Context) {
        nsView.onScroll = onScroll
    }
}

final class ScrollWheelNSView: NSView {

    var onScroll: ((CGFloat) -> Void)?

    override func scrollWheel(with event: NSEvent) {
        let delta = event.scrollingDeltaY
        guard abs(delta) > 0.01 else { return }
        onScroll?(delta)
    }

    override func mouseDown(with event: NSEvent) { nextResponder?.mouseDown(with: event) }
    override func mouseUp(with event: NSEvent) { nextResponder?.mouseUp(with: event) }
    override func mouseDragged(with event: NSEvent) { nextResponder?.mouseDragged(with: event) }
    override var acceptsFirstResponder: Bool { false }
}

// MARK: - Slider + Scroll Modifier
//
// View extension for adding scroll-wheel support to any SwiftUI Slider.
// Usage: Slider(value: $val, in: range).scrollableSlider(value: $val, range: range)

extension View {
    func scrollableSlider(value: Binding<Float>, range: ClosedRange<Float>) -> some View {
        self.overlay(
            ScrollWheelCatcher { delta in
                let span = range.upperBound - range.lowerBound
                let step = Float(delta) * span * 0.003
                let newVal = value.wrappedValue + step
                value.wrappedValue = min(range.upperBound, max(range.lowerBound, newVal))
            }
        )
    }

    func scrollableSlider(value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        self.overlay(
            ScrollWheelCatcher { delta in
                let span = range.upperBound - range.lowerBound
                let step = delta * span * 0.003
                let newVal = value.wrappedValue + step
                value.wrappedValue = min(range.upperBound, max(range.lowerBound, newVal))
            }
        )
    }

    @ViewBuilder
    func ifLet<T, Modified: View>(_ value: T?, transform: (Self, T) -> Modified) -> some View {
        if let value = value {
            transform(self, value)
        } else {
            self
        }
    }
}

// MARK: - Modulation Strip View
//
// Compact modulator rack below the channel mixer. Shows all active
// modulators (Agitation, Control, Peak) with add/remove and connection
// management. Follows the GRM Atelier layout: modulators as bottom-row strips.

private typealias MDS = LRConstants.DS

struct ModulationStripView: View {
    @ObservedObject var graph: ModulationGraph
    /// v2.0: Available target nodes for modulation (replaces laneCount)
    let targetNodes: [any GraphNode]

    @State private var showConnectionSheet = false
    @State private var connectingSource: (any ModulationSource)?

    var body: some View {
        VStack(spacing: MDS.spacingMD) {
            LRSectionHeader(
                title: "MODULATION",
                trailing: "\(totalConnections) conn | \(graph.cachedOffsets.count) active | #\(graph.evaluationCount)"
            )
            .padding(.horizontal, MDS.spacingXL)

            if graph.agitations.isEmpty && graph.controls.isEmpty && graph.peaks.isEmpty {
                emptyState
            } else {
                modulatorList
            }

            addModulatorButtons
        }
    }

    private var totalConnections: Int {
        graph.agitations.reduce(0) { $0 + $1.connections.count }
        + graph.controls.reduce(0) { $0 + $1.connections.count }
        + graph.peaks.reduce(0) { $0 + $1.connections.count }
    }

    private var emptyState: some View {
        Text("No modulators. Add one to create evolving parameter movement.")
            .font(MDS.font(MDS.fontCaption))
            .foregroundColor(MDS.textTertiary)
            .padding(.horizontal, MDS.spacingXL)
    }

    private var modulatorList: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: MDS.spacingMD) {
                ForEach(graph.agitations) { mod in
                    agitationCard(mod)
                }
                ForEach(graph.controls) { mod in
                    controlCard(mod)
                }
                ForEach(graph.peaks) { mod in
                    peakCard(mod)
                }
            }
            .padding(.horizontal, MDS.spacingXL)
        }
    }

    private var addModulatorButtons: some View {
        HStack(spacing: MDS.spacingSM) {
            addButton("+ AGITATION") { graph.addAgitation() }
            addButton("+ CONTROL") { graph.addControl() }
            addButton("+ PEAK") { graph.addPeak() }
        }
        .padding(.horizontal, MDS.spacingXL)
    }

    private func addButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(MDS.font(MDS.fontCaption2, weight: .bold))
                .foregroundColor(MDS.neonTurquesa.opacity(0.6))
                .padding(.horizontal, MDS.togglePaddingH)
                .padding(.vertical, MDS.togglePaddingV)
                .overlay(
                    RoundedRectangle(cornerRadius: MDS.radiusSM)
                        .stroke(MDS.neonTurquesa.opacity(0.2), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Agitation Card

    private func agitationCard(_ mod: AgitationModulator) -> some View {
        VStack(spacing: MDS.spacingSM) {
            cardHeader(title: mod.name, color: .cyan, sourceId: mod.sourceId)

            HStack(spacing: MDS.spacingSM) {
                paramKnobMini(label: "RATE", value: Binding(
                    get: { mod.rate },
                    set: { mod.rate = $0 }
                ), range: 0.01...50.0)

                paramKnobMini(label: "DEPTH", value: Binding(
                    get: { mod.depth },
                    set: { mod.depth = $0 }
                ), range: 0...1)
            }

            effectiveParamRow(
                items: [("eR", mod.effectiveRate), ("eD", mod.effectiveDepth)]
            )

            waveformPicker(mod)
            connectionList(for: mod)
            connectButton(source: mod)
        }
        .padding(MDS.spacingSM)
        .frame(width: 160)
        .background(MDS.surfaceElevated)
        .cornerRadius(MDS.radiusMD)
        .overlay(
            RoundedRectangle(cornerRadius: MDS.radiusMD)
                .stroke(Color.cyan.opacity(0.2), lineWidth: 1)
        )
    }

    private func waveformPicker(_ mod: AgitationModulator) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(AgitationWaveform.allCases, id: \.rawValue) { wf in
                    Button(action: { mod.waveform = wf }) {
                        Text(wfLabel(wf))
                            .font(MDS.font(MDS.fontCaption2, weight: .bold))
                            .foregroundColor(mod.waveform == wf ? .cyan : MDS.textTertiary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(mod.waveform == wf ? Color.cyan.opacity(0.15) : .clear)
                            .cornerRadius(2)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func wfLabel(_ wf: AgitationWaveform) -> String {
        switch wf {
        case .sine: return "SIN"
        case .triangle: return "TRI"
        case .saw: return "SAW"
        case .square: return "SQR"
        case .sampleAndHold: return "S&H"
        case .randomWalk: return "RND"
        }
    }

    // MARK: - Control Card

    private func controlCard(_ mod: ControlModulator) -> some View {
        VStack(spacing: MDS.spacingSM) {
            cardHeader(title: mod.name, color: .yellow, sourceId: mod.sourceId)

            HStack(spacing: MDS.spacingSM) {
                paramKnobMini(label: "VALUE", value: Binding(
                    get: { mod.value },
                    set: { mod.value = $0 }
                ), range: 0...1)

                paramKnobMini(label: "SLEW", value: Binding(
                    get: { mod.slewRate },
                    set: { mod.slewRate = $0 }
                ), range: 0.001...1)
            }

            effectiveParamRow(
                items: [("eV", mod.effectiveValue), ("eS", mod.effectiveSlew)]
            )

            connectionList(for: mod)
            connectButton(source: mod)
        }
        .padding(MDS.spacingSM)
        .frame(width: 160)
        .background(MDS.surfaceElevated)
        .cornerRadius(MDS.radiusMD)
        .overlay(
            RoundedRectangle(cornerRadius: MDS.radiusMD)
                .stroke(Color.yellow.opacity(0.2), lineWidth: 1)
        )
    }

    // MARK: - Peak Card

    private func peakCard(_ mod: PeakModulator) -> some View {
        VStack(spacing: MDS.spacingSM) {
            cardHeader(title: mod.name, color: .red, sourceId: mod.sourceId)

            HStack(spacing: MDS.spacingSM) {
                paramKnobMini(label: "ATK", value: Binding(
                    get: { mod.attack },
                    set: { mod.attack = $0 }
                ), range: 0.001...2)

                paramKnobMini(label: "DEC", value: Binding(
                    get: { mod.decay },
                    set: { mod.decay = $0 }
                ), range: 0.001...5)
            }

            HStack(spacing: MDS.spacingSM) {
                paramKnobMini(label: "HOLD", value: Binding(
                    get: { mod.hold },
                    set: { mod.hold = $0 }
                ), range: 0...2)

                paramKnobMini(label: "PROB", value: Binding(
                    get: { mod.triggerProbability },
                    set: { mod.triggerProbability = $0 }
                ), range: 0...1)
            }

            effectiveParamRow(
                items: [("eA", mod.effectiveAttack), ("eD", mod.effectiveDecay)]
            )

            Button(action: { mod.trigger() }) {
                Text("TRIG")
                    .font(MDS.font(MDS.fontCaption2, weight: .bold))
                    .foregroundColor(.red)
                    .padding(.horizontal, MDS.togglePaddingH)
                    .padding(.vertical, 2)
                    .overlay(
                        RoundedRectangle(cornerRadius: MDS.radiusSM)
                            .stroke(Color.red.opacity(0.4), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)

            connectionList(for: mod)
            connectButton(source: mod)
        }
        .padding(MDS.spacingSM)
        .frame(width: 160)
        .background(MDS.surfaceElevated)
        .cornerRadius(MDS.radiusMD)
        .overlay(
            RoundedRectangle(cornerRadius: MDS.radiusMD)
                .stroke(Color.red.opacity(0.2), lineWidth: 1)
        )
    }

    // MARK: - Shared Card Components

    private func effectiveParamRow(items: [(String, Float)]) -> some View {
        HStack(spacing: 4) {
            ForEach(items, id: \.0) { label, val in
                HStack(spacing: 1) {
                    Text(label)
                        .font(.system(size: 7, weight: .medium, design: .monospaced))
                        .foregroundColor(MDS.textTertiary)
                    Text(String(format: "%.2f", val))
                        .font(.system(size: 7, weight: .bold, design: .monospaced))
                        .foregroundColor(MDS.neonTurquesa.opacity(0.5))
                }
            }
        }
    }

    private func cardHeader(title: String, color: Color, sourceId: UUID) -> some View {
        HStack {
            Circle()
                .fill(color.opacity(0.6))
                .frame(width: MDS.dotSM, height: MDS.dotSM)
            Text(title)
                .font(MDS.font(MDS.fontCaption, weight: .bold))
                .foregroundColor(MDS.textPrimary)
            Spacer()
            Button(action: { graph.removeSource(id: sourceId) }) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(MDS.textTertiary)
            }
            .buttonStyle(.plain)
        }
    }

    private func paramKnobMini(label: String, value: Binding<Float>, range: ClosedRange<Float>) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(MDS.font(MDS.fontCaption2))
                .foregroundColor(MDS.textTertiary)
            Text(String(format: "%.2f", value.wrappedValue))
                .font(MDS.font(MDS.fontCaption2, weight: .medium))
                .foregroundColor(MDS.textSecondary)
                .frame(width: 50)

            Slider(value: value, in: range)
                .controlSize(.mini)
                .frame(width: 60)
        }
    }

    private func connectionList(for source: any ModulationSource) -> some View {
        VStack(spacing: 2) {
            ForEach(source.connections) { conn in
                VStack(spacing: 0) {
                    HStack(spacing: 2) {
                        Text(connectionLabel(conn))
                            .font(MDS.font(MDS.fontCaption2))
                            .foregroundColor(MDS.textSecondary)
                            .lineLimit(1)
                        Spacer()
                        Text(String(format: "s:%.1f", conn.scale))
                            .font(MDS.font(MDS.fontCaption2))
                            .foregroundColor(MDS.textTertiary)
                        Button(action: { graph.disconnect(connectionId: conn.id) }) {
                            Image(systemName: "minus.circle.fill")
                                .font(.system(size: 8))
                                .foregroundColor(MDS.danger.opacity(0.5))
                        }
                        .buttonStyle(.plain)
                    }
                    HStack(spacing: 4) {
                        modulationMeter(value: conn.lastRawValue, label: "RAW")
                        modulationMeter(value: conn.lastScaledValue, label: "OUT")
                    }
                    .frame(height: 10)
                }
            }
        }
    }

    private func modulationMeter(value: Float, label: String) -> some View {
        let clamped = max(-1, min(1, value))
        let normalized = (clamped + 1) / 2.0
        return HStack(spacing: 1) {
            Text(label)
                .font(.system(size: 6, weight: .medium, design: .monospaced))
                .foregroundColor(MDS.textTertiary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color.white.opacity(0.05))
                    Rectangle()
                        .fill(meterColor(value))
                        .frame(width: geo.size.width * CGFloat(normalized))
                }
                .cornerRadius(1)
            }
            Text(String(format: "%+.2f", value))
                .font(.system(size: 6, weight: .medium, design: .monospaced))
                .foregroundColor(MDS.textTertiary)
                .frame(width: 28, alignment: .trailing)
        }
    }

    private func meterColor(_ value: Float) -> Color {
        if abs(value) < 0.01 { return Color.gray.opacity(0.3) }
        return value > 0 ? MDS.neonTurquesa.opacity(0.6) : Color.orange.opacity(0.6)
    }

    private func connectionLabel(_ conn: ModulationConnection) -> String {
        let dest = conn.destinationAddress
        let paramName = dest.parameter.rawValue
        // v2.0: Show node ID prefix for node-based addressing
        let nodePrefix = String(dest.nodeId.uuidString.prefix(4))
        return "\(nodePrefix).\(paramName)"
    }

    private func connectButton(source: any ModulationSource) -> some View {
        Menu {
            ForEach(targetNodes, id: \.id) { node in
                Menu("Node \(String(node.id.uuidString.prefix(8)))") {
                    ForEach(laneParameters, id: \.rawValue) { param in
                        Button(param.rawValue) {
                            let addr = ModulationAddress(nodeId: node.id, parameter: param)
                            graph.connect(source: source, to: addr, scale: 1.0)
                        }
                    }
                }
            }
        } label: {
            Text("+ CONNECT")
                .font(MDS.font(MDS.fontCaption2, weight: .bold))
                .foregroundColor(MDS.neonTurquesa.opacity(0.6))
                .padding(.horizontal, MDS.togglePaddingH)
                .padding(.vertical, 2)
                .overlay(
                    RoundedRectangle(cornerRadius: MDS.radiusSM)
                        .stroke(MDS.neonTurquesa.opacity(0.2), lineWidth: 1)
                )
        }
        .menuStyle(.borderlessButton)
    }

    private var laneParameters: [ModulationParameter] {
        [.filterCutoff, .feedback, .entropy, .granularity, .guidanceScale,
         .delayMix, .saturationMorph, .resonatorNote, .bitCrushDepth,
         .inputStrength, .volume, .filterResonance, .resonatorDecay]
    }
}
