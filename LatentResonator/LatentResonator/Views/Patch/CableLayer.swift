import SwiftUI

// MARK: - Cable Layer
//
// Sits underneath the node cards on the patch canvas and draws every
// cable as a horizontal-tangent Bézier. Cable color comes from the
// edge's `SignalType` (audio = cyan, control = orange, gate = green,
// trigger = red), thickness from the lock mode (perform mode dims and
// thins cables so the focus shifts to the live controls).
//
// Port-to-pixel resolution is done at draw time using the
// `GeometryProxy` the canvas hosts, applying the same coordinate space
// every port chip reports through `PatchPortLocationsKey`.

private typealias DS = LRConstants.DS

struct CableLayer: View {

    let edges: [GraphEdge]
    let portLocations: [PatchPortLocation]
    let lockMode: PatchLockMode
    let geometry: GeometryProxy

    var body: some View {
        Canvas { context, _ in
            for edge in edges {
                guard let source = portLocation(
                    nodeId: edge.sourceNodeId,
                    portId: edge.sourcePortId,
                    direction: .output
                ) else { continue }

                guard let target = portLocation(
                    nodeId: edge.targetNodeId,
                    portId: edge.targetPortId,
                    direction: .input
                ) else { continue }

                let p0 = geometry[source.anchor]
                let p1 = geometry[target.anchor]
                let path = bezier(from: p0, to: p1)
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

                // Subtle endpoint dots, matched to the cable color.
                // Helps when two cables of different types meet at the
                // same port chip (port chips are only 11pt wide).
                context.fill(Path(ellipseIn: CGRect(
                    x: p0.x - 2, y: p0.y - 2, width: 4, height: 4
                )), with: .color(color))
                context.fill(Path(ellipseIn: CGRect(
                    x: p1.x - 2, y: p1.y - 2, width: 4, height: 4
                )), with: .color(color))
            }
        }
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.15), value: lockMode)
    }

    // MARK: - Lookup

    private func portLocation(
        nodeId: UUID,
        portId: String,
        direction: PortDirection
    ) -> PatchPortLocation? {
        portLocations.first { loc in
            loc.nodeId == nodeId
                && loc.portId == portId
                && loc.direction == direction
        }
    }

    // MARK: - Bezier shape

    /// Horizontal-tangent Bézier (the patch-cable look). The control
    /// points push out perpendicular to the source/target edges, scaled
    /// with horizontal distance so short cables stay tight and long
    /// cables stay legible. The minimum tangent stops cables from
    /// collapsing to a straight line when source ≈ target.
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
