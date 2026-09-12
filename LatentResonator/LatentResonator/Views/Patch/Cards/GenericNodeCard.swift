import SwiftUI

// MARK: - Generic Node Card
//
// Fallback panel for any `GraphNode` that does not have a hand-crafted
// card yet. Renders the node's parameters as a uniform list of knobs +
// fields driven entirely by `parameters: [String: Any]` introspection.
//
// This keeps the canvas honest: every node in the user's patch shows up
// with a recognizable identity (icon, name, color), even before its
// dedicated card lands. Once a card is built we just add a case in
// `NodeCardFactory`; the generic path remains as the safety net.

private typealias DS = LRConstants.DS

struct GenericNodeCard: View {

    @ObservedObject var node: BaseGraphNode
    let engine: NeuralEngine
    let lockMode: PatchLockMode
    let isFocused: Bool

    var body: some View {
        NodeCardChrome(
            node: node,
            lockMode: lockMode,
            isFocused: isFocused,
            footerText: nil
        ) {
            if parameterEntries.isEmpty {
                emptyBody
            } else {
                parameterList
            }
        }
    }

    // MARK: - Sub-views

    private var emptyBody: some View {
        Text("NO PARAMETERS")
            .font(DS.font(DS.fontCaption2, weight: .bold))
            .foregroundColor(DS.textTertiary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 6)
    }

    private var parameterList: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(parameterEntries, id: \.key) { entry in
                parameterRow(key: entry.key, value: entry.value)
            }
        }
    }

    private func parameterRow(key: String, value: Any) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(key.uppercased())
                    .font(DS.font(DS.fontCaption2, weight: .bold))
                    .foregroundColor(DS.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(format(value))
                    .font(DS.font(DS.fontCaption, weight: .semibold))
                    .foregroundColor(DS.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: NodeCardMetrics.paramValueMaxWidth, alignment: .trailing)
            }

            if isBool(value) {
                Toggle(isOn: boolBinding(for: key)) {
                    Text(key.uppercased())
                        .font(DS.font(DS.fontCaption2))
                        .foregroundColor(DS.textTertiary)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .frame(height: NodeCardMetrics.paramSliderHeight)
            } else if isInt(value) {
                let binding = intBinding(for: key)
                let range = inferredIntRange(for: key)
                HStack(spacing: 4) {
                    Button {
                        let next = max(range.lowerBound, binding.wrappedValue - 1)
                        if next != binding.wrappedValue { binding.wrappedValue = next }
                    } label: {
                        Text("−")
                            .font(DS.font(DS.fontCaption, weight: .bold))
                            .foregroundColor(DS.neonTurquesa)
                            .frame(width: 18, height: 18)
                            .background(DS.neonTurquesa.opacity(0.12))
                            .cornerRadius(2)
                    }
                    .buttonStyle(.plain)

                    Text("\(binding.wrappedValue)")
                        .font(DS.font(DS.fontCaption, weight: .bold))
                        .foregroundColor(DS.textPrimary)
                        .frame(minWidth: 24)

                    Button {
                        let next = min(range.upperBound, binding.wrappedValue + 1)
                        if next != binding.wrappedValue { binding.wrappedValue = next }
                    } label: {
                        Text("+")
                            .font(DS.font(DS.fontCaption, weight: .bold))
                            .foregroundColor(DS.neonTurquesa)
                            .frame(width: 18, height: 18)
                            .background(DS.neonTurquesa.opacity(0.12))
                            .cornerRadius(2)
                    }
                    .buttonStyle(.plain)

                    Spacer()
                }
                .frame(height: NodeCardMetrics.paramSliderHeight)
            } else if isNumeric(value) {
                let binding = floatBinding(for: key)
                let range = inferredRange(for: key)
                Slider(value: binding, in: range)
                    .accentColor(DS.neonTurquesa)
                    .scrollableSlider(value: binding, range: range)
                    .frame(height: NodeCardMetrics.paramSliderHeight)
            }
        }
        .contextMenu {
            if lockMode == .unlocked, isNumeric(value) {
                let alreadyExposed = isExposed(key: key)
                Button {
                    if alreadyExposed {
                        removeExposedControl(key: key)
                    } else {
                        addExposedControl(key: key, value: value)
                    }
                } label: {
                    Label(
                        alreadyExposed ? "Unexpose from Perform" : "Expose to Perform",
                        systemImage: alreadyExposed ? "star.slash" : "star"
                    )
                }
            }
        }
    }

    private func isExposed(key: String) -> Bool {
        engine.nodeGraph.exposedControls.contains { $0.nodeId == node.id && $0.paramId == key }
    }

    private func addExposedControl(key: String, value: Any) {
        guard let floatValue = value as? Float ?? (value as? Double).map({ Float($0) }) else { return }
        let control = ExposedControl(
            id: UUID(),
            nodeId: node.id,
            paramId: key,
            label: musicalLabel(for: key),
            controlType: inferControlType(for: key),
            range: inferredRange(for: key),
            defaultValue: floatValue,
            midiCC: nil,
            position: engine.nodeGraph.exposedControls.count
        )
        engine.nodeGraph.addExposedControl(control)
    }

    private func removeExposedControl(key: String) {
        guard let control = engine.nodeGraph.exposedControls.first(where: { $0.nodeId == node.id && $0.paramId == key }) else { return }
        engine.nodeGraph.removeExposedControl(id: control.id)
    }

    private func musicalLabel(for paramId: String) -> String {
        paramId
            .replacingOccurrences(of: "([A-Z])", with: " $1", options: .regularExpression)
            .capitalized
    }

    private func inferControlType(for paramId: String) -> ControlWidget {
        if paramId.contains("enabled") || paramId.contains("active") || paramId.contains("bypass") {
            return .toggle
        }
        if paramId.contains("X") || paramId.contains("Y") {
            return .xyPad
        }
        if paramId.contains("mode") || paramId.contains("type") {
            return .dropdown
        }
        return .knob
    }

    // MARK: - Typed control helpers

    /// True for Float/Double parameters — exposed as a generic slider.
    private func isNumeric(_ value: Any) -> Bool {
        value is Float || value is Double
    }

    /// True for Boolean parameters — exposed as a compact switch.
    private func isBool(_ value: Any) -> Bool {
        value is Bool
    }

    /// True for Integer parameters — exposed as a compact stepper.
    private func isInt(_ value: Any) -> Bool {
        value is Int
    }

    /// Binding to a parameter as Float, writing back through `setParam` so
    /// the audio thread picks up the edit on its next block via `getParam`.
    private func floatBinding(for key: String) -> Binding<Float> {
        Binding(
            get: { node.getParam(key, default: Float(0)) },
            set: { node.setParam(key, value: $0) }
        )
    }

    private func boolBinding(for key: String) -> Binding<Bool> {
        Binding(
            get: { node.getParam(key, default: false) },
            set: { node.setParam(key, value: $0) }
        )
    }

    private func intBinding(for key: String) -> Binding<Int> {
        Binding(
            get: { node.getParam(key, default: 0) },
            set: { node.setParam(key, value: $0) }
        )
    }

    /// Best-effort range inference for generic Float parameters.
    private func inferredRange(for paramId: String) -> ClosedRange<Float> {
        switch paramId {
        case "frequency", "cutoff", "rate", "pitch":
            return 20.0...20_000.0
        case "delayTime", "decay", "attack", "release", "duration":
            return 0.0...2.0
        case "amplitude", "volume", "masterGain", "gain", "feedback",
             "mix", "wetDryMix", "depth", "amount", "drive", "probability",
             "resonance", "texture", "chaos", "warmth", "bias":
            return 0.0...1.0
        default:
            return 0.0...1.0
        }
    }

    /// Best-effort range inference for generic Int parameters.
    private func inferredIntRange(for paramId: String) -> ClosedRange<Int> {
        switch paramId {
        case "numSteps", "inferenceSteps":
            return 1...64
        case "euclideanPulses", "euclideanSteps":
            return 0...32
        case "fftSize":
            return 256...4096
        default:
            return 0...100
        }
    }

    // MARK: - Helpers

    /// Stable, alphabetized parameter listing so the card layout doesn't
    /// flicker as Swift's dictionary order changes between runs.
    private var parameterEntries: [(key: String, value: Any)] {
        node.parameters
            .sorted { $0.key < $1.key }
            .map { ($0.key, $0.value) }
    }

    private func format(_ value: Any) -> String {
        if let f = value as? Float {
            return String(format: "%.3g", f)
        }
        if let d = value as? Double {
            return String(format: "%.3g", d)
        }
        if let i = value as? Int {
            return "\(i)"
        }
        if let b = value as? Bool {
            return b ? "ON" : "OFF"
        }
        if let s = value as? String {
            return s
        }
        return String(describing: value)
    }
}
