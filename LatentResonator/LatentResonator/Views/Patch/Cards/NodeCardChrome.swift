import SwiftUI

// MARK: - Node Card Chrome
//
// Shared SwiftUI shell around every node card. Provides:
//   - Header bar tinted by NodeCategory color
//   - Input / output port chips on the side rails
//   - Anchor-preference reporting so the canvas can draw cables to the
//     right pixel coordinates regardless of card size or position
//   - Footer with optional status text
//
// The card's domain-specific body (knobs, sliders, segment pickers, etc.)
// lives in the `body` view-builder closure of each concrete card.

private typealias DS = LRConstants.DS

struct NodeCardChrome<Content: View>: View {

    let node: any GraphNode
    let lockMode: PatchLockMode
    let isFocused: Bool
    let footerText: String?
    @ViewBuilder let content: () -> Content

    private var inputPorts: [NodePort] {
        node.ports.filter { $0.direction == .input }
    }

    private var outputPorts: [NodePort] {
        node.ports.filter { $0.direction == .output }
    }

    private var category: NodeCategory {
        node.category
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            contentBlock
            if let footerText = footerText {
                footer(text: footerText)
            }
        }
        .frame(minWidth: NodeCardMetrics.minWidth)
        .background(cardBackground)
        .overlay(cardBorder)
        .shadow(color: shadowColor, radius: isFocused ? 14 : 6, y: 2)
        .animation(.easeOut(duration: 0.12), value: isFocused)
        .animation(.easeOut(duration: 0.18), value: lockMode)
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: category.icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(category.color)
            Text(node.name)
                .font(DS.font(DS.fontCaption, weight: .bold))
                .foregroundColor(DS.textPrimary)
                .tracking(0.5)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Text(node.nodeType.uppercased())
                .font(DS.font(DS.fontCaption2))
                .foregroundColor(DS.textTertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .frame(height: NodeCardMetrics.headerHeight)
        .background(
            RoundedRectangle(cornerRadius: NodeCardMetrics.cornerRadius)
                .fill(category.color.opacity(0.16))
                .overlay(
                    Rectangle()
                        .fill(category.color.opacity(0.5))
                        .frame(height: 1)
                        .padding(.top, NodeCardMetrics.headerHeight - 1),
                    alignment: .bottom
                )
        )
        .clipShape(
            RoundedCorners(
                tl: NodeCardMetrics.cornerRadius,
                tr: NodeCardMetrics.cornerRadius,
                bl: 0, br: 0
            )
        )
    }

    private var contentBlock: some View {
        HStack(alignment: .center, spacing: 0) {
            portRail(ports: inputPorts, side: .input)
            content()
                .padding(.horizontal, NodeCardMetrics.bodyPaddingH)
                .padding(.vertical, NodeCardMetrics.bodyPaddingV)
                .frame(maxWidth: .infinity, alignment: .leading)
            portRail(ports: outputPorts, side: .output)
        }
    }

    private func footer(text: String) -> some View {
        Text(text)
            .font(DS.font(DS.fontCaption2))
            .foregroundColor(DS.textTertiary)
            .frame(height: NodeCardMetrics.footerHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, NodeCardMetrics.bodyPaddingH)
            .padding(.bottom, 4)
    }

    // MARK: - Port rail

    private func portRail(ports: [NodePort], side: PortDirection) -> some View {
        VStack(spacing: 6) {
            ForEach(ports, id: \.id) { port in
                portChip(port: port, side: side)
            }
        }
        .frame(width: NodeCardMetrics.portColumnWidth, alignment: side == .input ? .leading : .trailing)
        .padding(.vertical, 4)
    }

    private func portChip(port: NodePort, side: PortDirection) -> some View {
        let nodeId = node.id
        let portId = port.id
        let signalType = port.signalType

        return Circle()
            .fill(port.signalType.color)
            .frame(width: NodeCardMetrics.portChipSize, height: NodeCardMetrics.portChipSize)
            .overlay(
                Circle()
                    .stroke(DS.surfaceElevated, lineWidth: 1.5)
            )
            .help("\(port.label) · \(port.signalType.rawValue)")
            .anchorPreference(
                key: PatchPortLocationsKey.self,
                value: .center
            ) { anchor in
                [PatchPortLocation(
                    nodeId: nodeId,
                    portId: portId,
                    direction: side,
                    signalType: signalType,
                    anchor: anchor
                )]
            }
    }

    // MARK: - Look

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: NodeCardMetrics.cornerRadius)
            .fill(
                LinearGradient(
                    colors: [
                        DS.titanioTop,
                        DS.titanioBottom
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .opacity(lockMode == .locked ? 0.95 : 1.0)
    }

    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: NodeCardMetrics.cornerRadius)
            .stroke(
                isFocused ? category.color : DS.border,
                lineWidth: isFocused ? 1.5 : 1
            )
    }

    private var shadowColor: Color {
        isFocused
            ? category.color.opacity(0.45)
            : Color.black.opacity(0.35)
    }
}

// MARK: - Rounded-corner shape (per-corner radii)

/// SwiftUI's built-in `RoundedRectangle` doesn't expose per-corner radii.
/// We use this for the header strip so its top corners match the card's
/// outer radius while its bottom corners stay square against the body.
struct RoundedCorners: Shape {
    let tl: CGFloat
    let tr: CGFloat
    let bl: CGFloat
    let br: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.size.width
        let h = rect.size.height
        let tlClamped = min(min(tl, h / 2), w / 2)
        let trClamped = min(min(tr, h / 2), w / 2)
        let blClamped = min(min(bl, h / 2), w / 2)
        let brClamped = min(min(br, h / 2), w / 2)

        path.move(to: CGPoint(x: rect.minX + tlClamped, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - trClamped, y: rect.minY))
        path.addArc(
            center: CGPoint(x: rect.maxX - trClamped, y: rect.minY + trClamped),
            radius: trClamped,
            startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - brClamped))
        path.addArc(
            center: CGPoint(x: rect.maxX - brClamped, y: rect.maxY - brClamped),
            radius: brClamped,
            startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.minX + blClamped, y: rect.maxY))
        path.addArc(
            center: CGPoint(x: rect.minX + blClamped, y: rect.maxY - blClamped),
            radius: blClamped,
            startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + tlClamped))
        path.addArc(
            center: CGPoint(x: rect.minX + tlClamped, y: rect.minY + tlClamped),
            radius: tlClamped,
            startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false
        )
        path.closeSubpath()
        return path
    }
}
