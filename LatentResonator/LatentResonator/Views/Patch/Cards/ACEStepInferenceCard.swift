import SwiftUI

// MARK: - ACE-Step Inference Card
//
// Native node panel for `ACEStepInferenceNode` — the neural inference
// surface that drives the recursive loop. The prompt is the semantic
// filter P in whitepaper §3.3; the knobs are the diffusion controls
// (γ, N, α, entropy, granularity); the task picker routes the
// inference to the matching ACE-Step pipeline path (cover / repaint /
// extend / edit); the THINK toggle bypasses the LM planner (§6.1
// "circumventing the LM").
//
// The node itself does not render audio (see its class doc) — it is a
// parameter surface read by the connected `FeedbackLoopNode`. This card
// is the performer's handle on the neural black box.
//
// Ports (rendered by NodeCardChrome's port rails):
//   inputs:  [in (audio), prompt_in (control), cfg_cv (control)]
//   outputs: [out (audio), status (control)]

private typealias DS = LRConstants.DS

struct ACEStepInferenceCard: View {

    @ObservedObject var node: ACEStepInferenceNode
    @ObservedObject var engine: NeuralEngine
    let lockMode: PatchLockMode
    let isFocused: Bool

    private let taskOptions: [String] = ["cover", "repaint", "extend", "edit"]

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
    }

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
            return .loading
        case .error:
            return .error
        }
    }

    var body: some View {
        NodeCardChrome(
            node: node,
            lockMode: lockMode,
            isFocused: isFocused,
            footerText: footerText
        ) {
            VStack(spacing: DS.spacingSM) {
                promptField
                taskPicker
                knobRow
                thinkingToggle
            }
        }
    }

    // MARK: - Sub-views

    private var promptField: some View {
        TextEditor(text: promptBinding)
            .font(DS.font(DS.fontCaption, weight: .regular))
            .foregroundColor(DS.textPrimary)
            .frame(height: 44)
            .padding(DS.spacingXS)
            .background(DS.panelHollow)
            .cornerRadius(DS.radiusSM)
            .overlay(
                RoundedRectangle(cornerRadius: DS.radiusSM)
                    .stroke(DS.border, lineWidth: 1)
            )
    }

    private var taskPicker: some View {
        LRSegmentPicker(
            items: taskOptions,
            selected: currentTask,
            color: NodeCategory.neural.color,
            labelForItem: { $0.uppercased() },
            onSelect: { node.taskType = $0 }
        )
    }

    private var knobRow: some View {
        HStack(spacing: DS.spacingSM) {
            knob(label: "CFG",      binding: cfgBinding,        range: LRConstants.cfgScaleRange,        color: DS.neonTurquesa)
            knob(label: "STEPS",    binding: stepsBinding,      range: floatStepsRange,                  color: DS.neonAmbar)
            knob(label: "STRENGTH", binding: strengthBinding,   range: LRConstants.inputStrengthRange,    color: NodeCategory.neural.color)
            knob(label: "ENTROPY",  binding: entropyBinding,   range: 0...1,                             color: DS.neonAmbar)
        }
    }

    private var thinkingToggle: some View {
        HStack(spacing: DS.spacingXS) {
            Toggle(isOn: thinkingBinding) {
                Text("THINK")
                    .font(DS.font(DS.fontCaption2, weight: .bold))
                    .foregroundColor(DS.textTertiary)
                    .tracking(DS.trackingLab)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            Spacer()
            Text(thinkingBinding.wrappedValue ? "LM ON" : "LM BYPASS · §6.1")
                .font(DS.font(DS.fontCaption2, weight: .bold))
                .foregroundColor(thinkingBinding.wrappedValue ? DS.textTertiary : DS.neonTurquesa)
                .tracking(DS.trackingLab)
        }
    }

    private func knob(
        label: String,
        binding: Binding<Float>,
        range: ClosedRange<Float>,
        color: Color
    ) -> some View {
        VStack(spacing: 2) {
            RetroKnob(label: label, value: binding, range: range, accentColor: color, size: NodeCardMetrics.knobSize)
            Text(label)
                .font(DS.font(DS.fontCaption2, weight: .bold))
                .foregroundColor(DS.textTertiary)
        }
    }

    // MARK: - Bindings

    private var promptBinding: Binding<String> {
        Binding(get: { node.prompt }, set: { node.prompt = $0 })
    }

    private var cfgBinding: Binding<Float> {
        Binding(get: { node.guidanceScale }, set: { node.guidanceScale = $0 })
    }

    private var stepsBinding: Binding<Float> {
        Binding(
            get: { Float(node.numSteps) },
            set: { node.numSteps = Int($0) }
        )
    }

    private var strengthBinding: Binding<Float> {
        Binding(get: { node.inputStrength }, set: { node.inputStrength = $0 })
    }

    private var entropyBinding: Binding<Float> {
        Binding(get: { node.entropy }, set: { node.entropy = $0 })
    }

    private var thinkingBinding: Binding<Bool> {
        Binding(get: { node.thinking }, set: { node.thinking = $0 })
    }

    // MARK: - Derived

    private var currentTask: String {
        let t = node.taskType
        return taskOptions.contains(t) ? t : "cover"
    }

    private var floatStepsRange: ClosedRange<Float> {
        Float(LRConstants.aceStepsRange.lowerBound)...Float(LRConstants.aceStepsRange.upperBound)
    }

    // MARK: - Footer

    private var footerText: String {
        // Mirror the single bridge-readiness story used in RootView so the
        // performer sees the same state on the canvas card and in the status strip.
        let modelState = bridgeReadiness.label
        let task = currentTask.uppercased()
        let steps = node.numSteps
        let cfg = String(format: "%.1f", node.guidanceScale)
        return "\(task) · \(modelState) · \(steps)st · γ\(cfg)"
    }
}
