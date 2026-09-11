import SwiftUI

// MARK: - Macro Card
//
// Dedicated canvas panel for a collapsed/expanded MacroNode. Shows the
// macro's stage identity and expansion state, and wires the documented
// double-click gesture to `NodeGraph.expand(macroId:)` so the performer
// can open/close a macro directly from the patch surface.
//
// Ports (rendered by NodeCardChrome's port rails):
//   inputs:  dynamic set from `macro.exposedPorts` (audio/control)
//   outputs: dynamic set from `macro.exposedPorts` (audio/control)

private typealias DS = LRConstants.DS

struct MacroCard: View {

    @ObservedObject var node: MacroNode
    let lockMode: PatchLockMode
    let isFocused: Bool
    let onExpand: () -> Void

    var body: some View {
        NodeCardChrome(
            node: node,
            lockMode: lockMode,
            isFocused: isFocused,
            footerText: footerText
        ) {
            VStack(spacing: 6) {
                expansionIndicator
                macroInfo
            }
        }
        .onTapGesture(count: 2) {
            guard lockMode == .unlocked else { return }
            onExpand()
        }
    }

    // MARK: - Sub-views

    private var expansionIndicator: some View {
        HStack(spacing: DS.spacingXS) {
            Image(systemName: node.isExpanded ? "rectangle.stack.fill" : "rectangle.stack")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(node.isExpanded ? DS.neonTurquesa : DS.textTertiary)
            Text(node.isExpanded ? "EXPANDED" : "COLLAPSED")
                .font(DS.font(DS.fontCaption2, weight: .bold))
                .foregroundColor(node.isExpanded ? DS.neonTurquesa : DS.textTertiary)
                .tracking(DS.trackingLab)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var macroInfo: some View {
        HStack(spacing: DS.spacingXS) {
            Text("MACRO")
                .font(DS.font(DS.fontCaption2, weight: .bold))
                .foregroundColor(DS.textTertiary)
                .tracking(DS.trackingLab)
            Spacer(minLength: 4)
            Text(node.name)
                .font(DS.font(DS.fontCaption, weight: .semibold))
                .foregroundColor(DS.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    // MARK: - Footer

    private var footerText: String {
        let portCount = node.ports.count
        return "\(portCount) PORTS · DOUBLE-CLICK TO \(node.isExpanded ? "COLLAPSE" : "EXPAND")"
    }
}
