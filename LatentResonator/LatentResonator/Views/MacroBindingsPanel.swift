import SwiftUI

// MARK: - Macro Bindings Panel (Gap #5)
//
// UI for creating and managing macro control bindings.
// One exposed control can drive multiple target parameters with scaling curves.
//
// Accessed from PERFORM mode to create one-to-many parameter mappings.

private typealias DS = LRConstants.DS

struct MacroBindingsPanel: View {
    @ObservedObject var engine: NeuralEngine
    @Environment(\.dismiss) var dismiss

    @State private var selectedControlId: UUID?
    @State private var showingAddBinding = false

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            LRDivider()

            if engine.nodeGraph.exposedControls.isEmpty {
                emptyStateView
            } else {
                controlsList
            }
        }
        .frame(width: 500, height: 600)
        .background(DS.surfaceOverlay)
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: DS.spacingMD) {
            VStack(alignment: .leading, spacing: DS.spacingXS) {
                Text("MACRO BINDINGS")
                    .font(DS.font(DS.fontTitle, weight: .bold))
                    .foregroundColor(DS.textPrimary)
                Text("Map one control to many parameters")
                    .font(DS.font(DS.fontCaption))
                    .foregroundColor(DS.textSecondary)
            }

            Spacer()

            Button(action: { dismiss() }) {
                Text("DONE")
                    .font(DS.font(DS.fontCaption, weight: .bold))
                    .foregroundColor(DS.neonTurquesa)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, DS.spacingXL)
        .padding(.vertical, DS.spacingMD)
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: DS.spacingLG) {
            Spacer()

            Text("NO EXPOSED CONTROLS")
                .font(DS.font(DS.fontBody, weight: .bold))
                .foregroundColor(DS.textSecondary)

            Text("Exposed controls appear here when you mark parameters in STAGES. Right-click a parameter on a canvas card and select 'Expose to Perform'.")
                .font(DS.font(DS.fontCaption))
                .foregroundColor(DS.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, DS.spacingXL)

            Spacer()
        }
    }

    // MARK: - Controls List

    private var controlsList: some View {
        ScrollView {
            VStack(spacing: DS.spacingMD) {
                ForEach(engine.nodeGraph.exposedControls) { control in
                    ControlRow(
                        control: control,
                        bindings: bindingsFor(control: control),
                        isSelected: selectedControlId == control.id,
                        onSelect: { selectedControlId = control.id },
                        onAddBinding: {
                            selectedControlId = control.id
                            showingAddBinding = true
                        },
                        onRemoveBinding: { bindingId in
                            removeBinding(id: bindingId)
                        }
                    )
                }
            }
            .padding(DS.spacingMD)
        }
        .sheet(isPresented: $showingAddBinding) {
            if let controlId = selectedControlId,
               let control = engine.nodeGraph.exposedControls.first(where: { $0.id == controlId }) {
                AddBindingSheet(
                    control: control,
                    nodes: Array(engine.nodeGraph.nodes.values),
                    onAdd: { target in
                        addBinding(controlId: controlId, target: target)
                        showingAddBinding = false
                    },
                    onCancel: { showingAddBinding = false }
                )
            }
        }
    }

    // MARK: - Helpers

    private func bindingsFor(control: ExposedControl) -> [MacroBinding] {
        engine.nodeGraph.macroBindings.filter { $0.exposedControlId == control.id }
    }

    private func addBinding(controlId: UUID, target: MacroTarget) {
        // Check if binding already exists
        if let existingIndex = engine.nodeGraph.macroBindings.firstIndex(where: {
            $0.exposedControlId == controlId
        }) {
            // Append to existing binding
            let existing = engine.nodeGraph.macroBindings[existingIndex]
            var newTargets = existing.targets
            newTargets.append(target)
            let updatedBinding = MacroBinding(
                id: existing.id,
                exposedControlId: controlId,
                targets: newTargets
            )
            engine.nodeGraph.macroBindings[existingIndex] = updatedBinding
        } else {
            // Create new binding
            let binding = MacroBinding(
                exposedControlId: controlId,
                targets: [target]
            )
            engine.nodeGraph.macroBindings.append(binding)
        }
        engine.nodeGraph.objectWillChange.send()
    }

    private func removeBinding(id: UUID) {
        engine.nodeGraph.macroBindings.removeAll { $0.id == id }
        engine.nodeGraph.objectWillChange.send()
    }
}

// MARK: - Control Row

private struct ControlRow: View {
    let control: ExposedControl
    let bindings: [MacroBinding]
    let isSelected: Bool
    let onSelect: () -> Void
    let onAddBinding: () -> Void
    let onRemoveBinding: (UUID) -> Void

    var body: some View {
        VStack(spacing: DS.spacingSM) {
            // Control Header
            HStack(spacing: DS.spacingSM) {
                Text("★")
                    .font(DS.font(DS.fontCaption, weight: .bold))
                    .foregroundColor(DS.neonAmbar)

                VStack(alignment: .leading, spacing: 2) {
                    Text(control.label)
                        .font(DS.font(DS.fontBody, weight: .semibold))
                        .foregroundColor(DS.textPrimary)
                    Text("\(control.nodeId.uuidString.prefix(8))...\(control.paramId)")
                        .font(DS.font(DS.fontCaption2))
                        .foregroundColor(DS.textTertiary)
                        .lineLimit(1)
                }

                Spacer()

                Text("\(bindings.count) binding\(bindings.count == 1 ? "" : "s")")
                    .font(DS.font(DS.fontCaption2))
                    .foregroundColor(DS.textSecondary)

                Button(action: onAddBinding) {
                    Text("+")
                        .font(DS.font(DS.fontBody, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 24, height: 24)
                        .background(DS.neonTurquesa)
                        .cornerRadius(3)
                }
                .buttonStyle(.plain)
                .help("Add target parameter to this control")
            }
            .padding(DS.spacingSM)
            .background(isSelected ? DS.neonTurquesa.opacity(0.1) : DS.surfaceSubtle)
            .overlay(RoundedRectangle(cornerRadius: DS.radiusSM)
                .stroke(isSelected ? DS.neonTurquesa.opacity(0.5) : DS.border, lineWidth: 1))
            .onTapGesture { onSelect() }

            // Bindings List
            if !bindings.isEmpty {
                VStack(spacing: DS.spacingXS) {
                    ForEach(bindings) { binding in
                        ForEach(binding.targets.indices, id: \.self) { idx in
                            let target = binding.targets[idx]
                            BindingRow(target: target, onDelete: {
                                onRemoveBinding(binding.id)
                            })
                        }
                    }
                }
                .padding(.leading, DS.spacingLG)
            }
        }
    }
}

// MARK: - Binding Row

private struct BindingRow: View {
    let target: MacroTarget
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: DS.spacingSM) {
            Text("→")
                .font(DS.font(DS.fontCaption))
                .foregroundColor(DS.neonTurquesa)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(target.nodeId.uuidString.prefix(8))...")
                    .font(DS.font(DS.fontCaption2))
                    .foregroundColor(DS.textSecondary)
                Text(target.paramId)
                    .font(DS.font(DS.fontCaption2, weight: .bold))
                    .foregroundColor(DS.textPrimary)
            }

            Spacer()

            // Curve badge
            Text(target.curve.rawValue.uppercased())
                .font(DS.font(DS.fontCaption2, weight: .bold))
                .foregroundColor(DS.textTertiary)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(DS.surfaceElevated)
                .cornerRadius(2)

            // Range
            Text("\(String(format: "%.1f", target.inputRange.lowerBound))-\(String(format: "%.1f", target.inputRange.upperBound)) → \(String(format: "%.1f", target.outputRange.lowerBound))-\(String(format: "%.1f", target.outputRange.upperBound))")
                .font(DS.font(DS.fontCaption2))
                .foregroundColor(DS.textTertiary)

            Button(action: onDelete) {
                Text("✕")
                    .font(DS.font(DS.fontCaption, weight: .bold))
                    .foregroundColor(DS.danger)
            }
            .buttonStyle(.plain)
        }
        .padding(DS.spacingSM)
        .background(DS.surfaceElevated.opacity(0.5))
        .cornerRadius(DS.radiusSM)
    }
}

// MARK: - Add Binding Sheet

private struct AddBindingSheet: View {
    let control: ExposedControl
    let nodes: [any GraphNode]
    let onAdd: (MacroTarget) -> Void
    let onCancel: () -> Void

    @State private var selectedNodeId: UUID?
    @State private var selectedParamId: String = ""
    @State private var selectedCurve: ScalingCurve = .linear
    @State private var inputMin: Float = 0.0
    @State private var inputMax: Float = 1.0
    @State private var outputMin: Float = 0.0
    @State private var outputMax: Float = 1.0

    private var availableParams: [String] {
        guard let node = nodes.first(where: { $0.id == selectedNodeId }) else { return [] }
        return Array(node.parameters.keys).sorted()
    }

    var body: some View {
        VStack(spacing: DS.spacingLG) {
            // Header
            HStack {
                Text("ADD BINDING")
                    .font(DS.font(DS.fontTitle, weight: .bold))
                    .foregroundColor(DS.textPrimary)
                Spacer()
                Button("Cancel", action: onCancel)
                    .font(DS.font(DS.fontBody))
                    .foregroundColor(DS.textSecondary)
            }

            LRDivider()

            // Source Info
            HStack(spacing: DS.spacingSM) {
                Text("★")
                    .font(DS.font(DS.fontCaption, weight: .bold))
                    .foregroundColor(DS.neonAmbar)
                Text(control.label)
                    .font(DS.font(DS.fontBody, weight: .semibold))
                    .foregroundColor(DS.textPrimary)
                Spacer()
            }
            .padding(DS.spacingSM)
            .background(DS.neonAmbar.opacity(0.1))
            .cornerRadius(DS.radiusSM)

            // Target Selection
            VStack(alignment: .leading, spacing: DS.spacingSM) {
                Text("TARGET NODE")
                    .font(DS.font(DS.fontCaption, weight: .bold))
                    .foregroundColor(DS.textSecondary)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: DS.spacingSM) {
                        ForEach(nodes, id: \.id) { node in
                            NodeSelectButton(
                                node: node,
                                isSelected: selectedNodeId == node.id,
                                onSelect: {
                                    selectedNodeId = node.id
                                    selectedParamId = ""
                                }
                            )
                        }
                    }
                }
            }

            // Parameter Selection
            if selectedNodeId != nil {
                VStack(alignment: .leading, spacing: DS.spacingSM) {
                    Text("TARGET PARAMETER")
                        .font(DS.font(DS.fontCaption, weight: .bold))
                        .foregroundColor(DS.textSecondary)

                    if availableParams.isEmpty {
                        Text("No parameters available")
                            .font(DS.font(DS.fontCaption))
                            .foregroundColor(DS.textTertiary)
                    } else {
                        FlowLayout(spacing: DS.spacingXS) {
                            ForEach(availableParams, id: \.self) { param in
                                ParamButton(
                                    param: param,
                                    isSelected: selectedParamId == param,
                                    onSelect: { selectedParamId = param }
                                )
                            }
                        }
                    }
                }
            }

            // Curve Selection
            VStack(alignment: .leading, spacing: DS.spacingSM) {
                Text("SCALING CURVE")
                    .font(DS.font(DS.fontCaption, weight: .bold))
                    .foregroundColor(DS.textSecondary)

                HStack(spacing: DS.spacingSM) {
                    ForEach(ScalingCurve.allCases, id: \.self) { curve in
                        CurveButton(
                            curve: curve,
                            isSelected: selectedCurve == curve,
                            onSelect: { selectedCurve = curve }
                        )
                    }
                }
            }

            // Range Inputs
            VStack(alignment: .leading, spacing: DS.spacingSM) {
                Text("VALUE RANGES")
                    .font(DS.font(DS.fontCaption, weight: .bold))
                    .foregroundColor(DS.textSecondary)

                HStack(spacing: DS.spacingMD) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Input")
                            .font(DS.font(DS.fontCaption2))
                            .foregroundColor(DS.textTertiary)
                        HStack(spacing: 4) {
                            TextField("Min", value: $inputMin, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 60)
                            Text("→")
                                .foregroundColor(DS.textTertiary)
                            TextField("Max", value: $inputMax, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 60)
                        }
                    }

                    Spacer()

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Output")
                            .font(DS.font(DS.fontCaption2))
                            .foregroundColor(DS.textTertiary)
                        HStack(spacing: 4) {
                            TextField("Min", value: $outputMin, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 60)
                            Text("→")
                                .foregroundColor(DS.textTertiary)
                            TextField("Max", value: $outputMax, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 60)
                        }
                    }
                }
            }

            Spacer()

            // Actions
            HStack(spacing: DS.spacingMD) {
                Button("Cancel", action: onCancel)
                    .font(DS.font(DS.fontBody))
                    .foregroundColor(DS.textSecondary)

                Spacer()

                Button(action: addBinding) {
                    Text("ADD BINDING")
                        .font(DS.font(DS.fontBody, weight: .bold))
                        .foregroundColor(.black)
                        .padding(.horizontal, DS.spacingLG)
                        .padding(.vertical, DS.spacingSM)
                        .background(canAdd ? DS.neonTurquesa : DS.textDisabled)
                        .cornerRadius(3)
                }
                .buttonStyle(.plain)
                .disabled(!canAdd)
            }
        }
        .padding(DS.spacingXL)
        .frame(width: 450, height: 500)
        .background(DS.surfaceOverlay)
    }

    private var canAdd: Bool {
        selectedNodeId != nil && !selectedParamId.isEmpty
    }

    private func addBinding() {
        guard let nodeId = selectedNodeId else { return }
        let target = MacroTarget(
            nodeId: nodeId,
            paramId: selectedParamId,
            inputRange: inputMin...inputMax,
            outputRange: outputMin...outputMax,
            curve: selectedCurve
        )
        onAdd(target)
    }
}

// MARK: - Helper Views

private struct NodeSelectButton: View {
    let node: any GraphNode
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 2) {
                Text(node.nodeType.uppercased())
                    .font(DS.font(DS.fontCaption2, weight: .bold))
                    .foregroundColor(isSelected ? .black : DS.textSecondary)
                Text(node.name)
                    .font(DS.font(DS.fontCaption2))
                    .foregroundColor(isSelected ? .black.opacity(0.7) : DS.textTertiary)
                    .lineLimit(1)
            }
            .padding(.horizontal, DS.spacingSM)
            .padding(.vertical, DS.spacingXS)
            .frame(width: 100)
            .background(isSelected ? DS.neonTurquesa : DS.surfaceSubtle)
            .cornerRadius(3)
        }
        .buttonStyle(.plain)
    }
}

private struct ParamButton: View {
    let param: String
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            Text(param)
                .font(DS.font(DS.fontCaption2, weight: isSelected ? .bold : .medium))
                .foregroundColor(isSelected ? .black : DS.textSecondary)
                .padding(.horizontal, DS.spacingSM)
                .padding(.vertical, 4)
                .background(isSelected ? DS.neonTurquesa : DS.surfaceElevated)
                .cornerRadius(2)
        }
        .buttonStyle(.plain)
    }
}

private struct CurveButton: View {
    let curve: ScalingCurve
    let isSelected: Bool
    let onSelect: () -> Void

    private var description: String {
        switch curve {
        case .linear: return "1:1"
        case .exponential: return "Exp"
        case .logarithmic: return "Log"
        case .inverted: return "Inv"
        case .sCurve: return "S"
        }
    }

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 2) {
                Text(description)
                    .font(DS.font(DS.fontCaption, weight: .bold))
                    .foregroundColor(isSelected ? .black : DS.textSecondary)
                Text(curve.rawValue.capitalized)
                    .font(DS.font(DS.fontCaption2))
                    .foregroundColor(isSelected ? .black.opacity(0.7) : DS.textTertiary)
            }
            .frame(width: 60, height: 44)
            .background(isSelected ? DS.neonTurquesa : DS.surfaceSubtle)
            .cornerRadius(3)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Flow Layout (for parameter buttons)

private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = FlowResult(in: proposal.width ?? 0, subviews: subviews, spacing: spacing)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = FlowResult(in: bounds.width, subviews: subviews, spacing: spacing)
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: result.positions[index].x + bounds.minX,
                                      y: result.positions[index].y + bounds.minY),
                         proposal: .unspecified)
        }
    }

    private struct FlowResult {
        var size: CGSize = .zero
        var positions: [CGPoint] = []

        init(in maxWidth: CGFloat, subviews: Subviews, spacing: CGFloat) {
            var x: CGFloat = 0
            var y: CGFloat = 0
            var rowHeight: CGFloat = 0

            for subview in subviews {
                let size = subview.sizeThatFits(.unspecified)
                if x + size.width > maxWidth && x > 0 {
                    x = 0
                    y += rowHeight + spacing
                    rowHeight = 0
                }
                positions.append(CGPoint(x: x, y: y))
                rowHeight = max(rowHeight, size.height)
                x += size.width + spacing
            }

            self.size = CGSize(width: maxWidth, height: y + rowHeight)
        }
    }
}

// MARK: - Extensions

extension ScalingCurve: CaseIterable {
    static var allCases: [ScalingCurve] = [.linear, .exponential, .logarithmic, .inverted, .sCurve]
}
