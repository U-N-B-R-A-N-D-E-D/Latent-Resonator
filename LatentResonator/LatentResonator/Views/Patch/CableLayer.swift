import SwiftUI

// MARK: - Cable Layer
//
// Draws patch cables underneath node cards. When unlocked, cables accept
// secondary-click to delete (Envion / Pure Data patch-cord model).

private typealias DS = LRConstants.DS

struct CableLayer: View {

    let edges: [GraphEdge]
    let lockMode: PatchLockMode
    var previewDrag: PatchCableDragState? = nil
    var resolvedCenters: [PatchPortRef: CGPoint] = [:]
    var onSelectEdge: ((UUID) -> Void)? = nil

    var body: some View {
        ZStack {
            Canvas { context, _ in
                for edge in edges {
                    guard let path = path(for: edge) else { continue }
                    let color = edge.signalType.color.opacity(opacity(for: edge.signalType))
                    context.stroke(
                        path,
                        with: .color(color),
                        style: StrokeStyle(
                            lineWidth: lineWidth(for: edge.signalType),
                            lineCap: .round,
                            lineJoin: .round
                        )
                    )
                }

                if let preview = previewDrag,
                   let start = resolvedCenters[preview.source] {
                    let previewPath = bezier(from: start, to: preview.currentPoint)
                    context.stroke(
                        previewPath,
                        with: .color(preview.source.signalType.color.opacity(0.9)),
                        style: StrokeStyle(lineWidth: 2.4, lineCap: .round, dash: [6, 4])
                    )
                }
            }
            .allowsHitTesting(false)

            if lockMode == .unlocked {
                cableHitOverlay
            }
        }
        .animation(.easeOut(duration: 0.15), value: lockMode)
    }

    /// Invisible hit targets along each cable for secondary-click delete.
    private var cableHitOverlay: some View {
        ForEach(edges, id: \.id) { edge in
            if let path = path(for: edge) {
                path
                    .stroke(Color.clear, lineWidth: 14)
                    .contentShape(path.strokedPath(StrokeStyle(lineWidth: 14, lineCap: .round)))
                    .onTapGesture(count: 2) {
                        onSelectEdge?(edge.id)
                    }
                    .help("Double-click to delete cable")
            }
        }
    }

    // MARK: - Lookup

    private func path(for edge: GraphEdge) -> Path? {
        let sourceRef = PatchPortRef(
            nodeId: edge.sourceNodeId,
            portId: edge.sourcePortId,
            direction: .output,
            signalType: edge.signalType
        )
        let targetRef = PatchPortRef(
            nodeId: edge.targetNodeId,
            portId: edge.targetPortId,
            direction: .input,
            signalType: edge.signalType
        )
        #if DEBUG
        let hasSource = resolvedCenters[sourceRef] != nil
        let hasTarget = resolvedCenters[targetRef] != nil
        print("[Cable] edge \(edge.id.uuidString.prefix(8)) sourceHit=\(hasSource) targetHit=\(hasTarget) totalCenters=\(resolvedCenters.count)")
        #endif
        guard let p0 = resolvedCenters[sourceRef], let p1 = resolvedCenters[targetRef] else { return nil }
        return bezier(from: p0, to: p1)
    }

    // MARK: - Bezier shape

    private func bezier(from p0: CGPoint, to p1: CGPoint) -> Path {
        let dx = abs(p1.x - p0.x)
        let tangent = max(50, dx * 0.5)
        let c0 = CGPoint(x: p0.x + tangent, y: p0.y)
        let c1 = CGPoint(x: p1.x - tangent, y: p1.y)
        var path = Path()
        path.move(to: p0)
        path.addCurve(to: p1, control1: c0, control2: c1)
        return path
    }

    // MARK: - Visual rules

    private func lineWidth(for signalType: SignalType) -> CGFloat {
        let base: CGFloat = signalType == .audio ? 2.2 : 1.4
        return lockMode == .locked ? max(base * 0.55, 1.0) : base
    }

    private func opacity(for signalType: SignalType) -> Double {
        switch lockMode {
        case .unlocked: return signalType == .audio ? 0.85 : 0.7
        case .locked:   return signalType == .audio ? 0.45 : 0.3
        }
    }
}
