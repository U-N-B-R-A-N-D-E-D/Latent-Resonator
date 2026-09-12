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

    @EnvironmentObject var portInteractionHandler: PortInteractionHandler
    @Environment(\.nodeDragHandler) private var nodeDragHandler
    @EnvironmentObject var selectionHandler: CanvasSelectionHandler

    private var isSelected: Bool {
        selectionHandler.selectedNodeIds.contains(node.id)
    }

    private var inputPorts: [NodePort] {
        node.ports.filter { $0.direction == .input }
    }

    private var outputPorts: [NodePort] {
        node.ports.filter { $0.direction == .output }
    }

    private var category: NodeCategory {
        node.category
    }

    private var stageKind: StageKind? {
        node.effectiveStageKind
    }

    private var stageAccent: Color {
        stageKind?.accentColor ?? category.color.opacity(0.55)
    }

    private var isHero: Bool {
        node.isResonatorHero
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            contentBlock
            if let footerText = footerText {
                footer(text: footerText)
            }
        }
        .frame(width: isHero ? NodeCardMetrics.minWidth + 8 : NodeCardMetrics.minWidth)
        .fixedSize(horizontal: false, vertical: true)
        .background(cardBackground)
        .overlay(cardBorder)
        .overlay(selectionBorder)
        .background(
            // Report the card's bounding frame in the named canvas space so
            // marquee selection and zoom-to-fit can use real rendered bounds.
            GeometryReader { cardGeometry in
                let frame = cardGeometry.frame(in: .named(PatchCanvasSpace.name))
                Color.clear
                    .preference(
                        key: PatchCardFramesKey.self,
                        value: [PatchCardFrame(nodeId: node.id, frame: frame)]
                    )
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: NodeCardMetrics.cornerRadius))
        .shadow(color: shadowColor, radius: isFocused ? 14 : (isHero ? 10 : 6), y: 2)
        .animation(.easeOut(duration: 0.12), value: isFocused)
        .animation(.easeOut(duration: 0.18), value: lockMode)
        .gesture(nodeDragGesture())
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(stageAccent)
                .frame(width: 6, height: 6)

            if let stageKind = stageKind {
                Text(stageKind.headerLabel)
                    .font(DS.font(DS.fontCaption, weight: .bold))
                    .foregroundColor(stageAccent)
                    .tracking(0.8)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                Text(node.name.uppercased())
                    .font(DS.font(DS.fontCaption, weight: .bold))
                    .foregroundColor(DS.textPrimary)
                    .tracking(0.5)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 4)

            if let stageKind = stageKind, node.name.uppercased() != stageKind.headerLabel {
                Text(node.name)
                    .font(DS.font(DS.fontCaption2))
                    .foregroundColor(DS.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: NodeCardMetrics.headerHeight)
        .background(
            RoundedRectangle(cornerRadius: NodeCardMetrics.cornerRadius)
                .fill(stageAccent.opacity(isHero ? 0.22 : 0.14))
                .overlay(
                    Rectangle()
                        .fill(stageAccent.opacity(isHero ? 0.65 : 0.4))
                        .frame(height: isHero ? 2 : 1)
                        .padding(.top, NodeCardMetrics.headerHeight - (isHero ? 2 : 1)),
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
            .lineLimit(1)
            .truncationMode(.tail)
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
        let portRef = PatchPortRef(
            nodeId: nodeId,
            portId: portId,
            direction: side,
            signalType: signalType
        )
        let isValidDropTarget: Bool = {
            guard lockMode == .unlocked,
                  let source = portInteractionHandler.activeCableDrag,
                  port.direction == .input,
                  source.signalType == port.signalType,
                  source.nodeId != nodeId else { return false }
            return true
        }()

        return Circle()
            .fill(port.signalType.color)
            .frame(width: NodeCardMetrics.portChipSize, height: NodeCardMetrics.portChipSize)
            .overlay(
                Circle()
                    .stroke(DS.surfaceElevated, lineWidth: 1.5)
            )
            .overlay(
                Circle()
                    .stroke(DS.neonTurquesa, lineWidth: 2)
                    .frame(width: NodeCardMetrics.portChipSize + 7, height: NodeCardMetrics.portChipSize + 7)
                    .opacity(isValidDropTarget ? 1 : 0)
                    .animation(.easeOut(duration: 0.12), value: isValidDropTarget)
            )
            .help("\(port.label) · \(port.signalType.rawValue)")
            .background(
                // Report the port chip's center in the named canvas space.
                // Using .background(GeometryReader { Color.clear.preference })
                // matches the card-frame reporter and avoids the non-standard
                // GeometryReader wrapper that was failing to propagate.
                GeometryReader { portGeometry in
                    let portFrame = portGeometry.frame(in: .named(PatchCanvasSpace.name))
                    let center = CGPoint(x: portFrame.midX, y: portFrame.midY)
                    #if DEBUG
                    let _: () = print("[PortChip] port=\(portId) center=\(center)")
                    #endif
                    Color.clear
                        .preference(
                            key: PatchPortLocationsKey.self,
                            value: [PatchPortLocation(
                                nodeId: nodeId,
                                portId: portId,
                                direction: side,
                                signalType: signalType,
                                center: center
                            )]
                        )
                }
            )
            .gesture(portDragGesture(for: portRef))
            .onTapGesture(count: 2) {
                guard lockMode == .unlocked else { return }
                portInteractionHandler.handlers.onPortSecondaryClick?(portRef)
            }
    }

    /// Output ports start a patch cord; input ports complete one. Double-click
    /// on a port removes its cable(s).
    private func portDragGesture(for portRef: PatchPortRef) -> some Gesture {
        // Named space, not `.global`: `.global` is relative to the whole
        // window, but `RootView` stacks a mode-toggle bar above the canvas,
        // so every `.global` point used to land offset by that bar's height
        // — see `PatchCanvasSpace`.
        DragGesture(minimumDistance: 4, coordinateSpace: .named(PatchCanvasSpace.name))
            .onChanged { value in
                guard lockMode == .unlocked else { return }
                portInteractionHandler.handlers.onPortDragChanged?(portRef, value.location)
            }
            .onEnded { value in
                guard lockMode == .unlocked else { return }
                portInteractionHandler.handlers.onPortDragEnded?(portRef, value.location)
            }
    }

    /// Drag the card from anywhere on the card background. Child controls
    /// (sliders, knobs, faders, buttons, port chips) have their own gestures
    /// and win by SwiftUI's child-first gesture precedence, so dragging a
    /// control adjusts the control, not the card.
    private func nodeDragGesture() -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .local)
            .onChanged { value in
                guard lockMode == .unlocked else { return }
                #if DEBUG
                print("[Drag] node=\(node.id.uuidString.prefix(8)) translation=\(value.translation)")
                #endif
                nodeDragHandler.handlers.onNodeDragChanged?(node.id, value.translation)
            }
            .onEnded { _ in
                guard lockMode == .unlocked else { return }
                nodeDragHandler.handlers.onNodeDragEnded?(node.id)
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
                isFocused ? stageAccent : (isHero ? stageAccent.opacity(0.55) : DS.border),
                lineWidth: isFocused ? 1.5 : (isHero ? 1.75 : 1)
            )
    }

    private var selectionBorder: some View {
        RoundedRectangle(cornerRadius: NodeCardMetrics.cornerRadius)
            .stroke(DS.neonTurquesa, lineWidth: 2)
            .opacity(isSelected ? 1 : 0)
            .animation(.easeOut(duration: 0.12), value: isSelected)
    }

    private var shadowColor: Color {
        if isFocused {
            return stageAccent.opacity(0.45)
        }
        if isHero {
            return stageAccent.opacity(0.25)
        }
        return Color.black.opacity(0.35)
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
