import SwiftUI

// MARK: - Envelope Curve View (P5 Slice 1 + Slice 2)
//
// Honest visualization of a `MetaParameterNode` breakpoint envelope.
// Renders the actual interpolation curve (honoring each segment's
// `CurveType`), a filled area under the curve, vertex markers, and a
// vertical playhead driven by the live sequencer/control-graph phase.
//
// Slice 1 (READ-ONLY): `onEdit == nil` — pure visualization, no gestures.
// Slice 2 (EDITABLE):  `onEdit != nil` — the gestures ARE the interface:
//   • drag a vertex → move it (clamped to [0,1] × [0,1])
//   • drag the curve body → insert a new breakpoint, then drag it
//   • double-click a vertex → delete it (disabled at the 2-bp minimum)
// No new decoration. No labels. Envion restraint preserved.
//
// Whitepaper §3.4 (D3 — MetaParameterNode).
// Geometry helpers (`pointAt`, `addSampledCurve`) are shared between
// the read-only render path and the Slice 2 hit-testing / normalization.

private typealias DS = LRConstants.DS

/// Number of samples per segment when stroking the curve. High enough
/// that exponential / logarithmic / S-curves read as smooth at any
/// reasonable view width, low enough to keep the Path cheap at 60Hz.
private let kSamplesPerSegment: Int = 24

/// Pixel radius around a vertex marker that counts as a "hit" for the
/// drag-to-move gesture. Generous on purpose: the visible dot is 4px,
/// but the touch target is larger so the gesture feels reliable.
private let kVertexHitRadius: CGFloat = 14

/// Minimum drag distance before the edit gesture commits. Prevents
/// accidental inserts / moves from a static click on the curve.
private let kEditDragMinDistance: CGFloat = 4

// MARK: - EnvelopeEdit (Slice 2 edit protocol)

/// Edit intents the `EnvelopeCurveView` can emit to its host. The host
/// (typically `PerformanceMotherbaseView`) translates these into
/// `MetaParameterNode.updateBreakpoint / addBreakpoint / removeBreakpoint`
/// calls and triggers `objectWillChange.send()` on the node graph.
///
/// `insert` does not carry an id: the node mints the id, re-renders, and
/// the view resolves the just-inserted vertex as the nearest breakpoint
/// to the ongoing drag location on the next gesture tick. This keeps the
/// protocol single-direction (view → host) and avoids a return channel.
enum EnvelopeEdit {
    /// Move an existing breakpoint to a new normalized (time, value).
    case move(id: UUID, time: Float, value: Float)
    /// Insert a new breakpoint at normalized (time, value).
    case insert(time: Float, value: Float)
    /// Delete the breakpoint with the given id. The host enforces the
    /// `MetaParameterNode` minimum of 2 breakpoints; the view also
    /// disables the delete gesture visually when at the floor.
    case delete(id: UUID)
}

struct EnvelopeCurveView: View {

    /// Breakpoints defining the envelope shape (normalized time 0...1, value 0...1).
    let breakpoints: [Breakpoint]

    /// The `MetaParameterNode` this view visualizes. The view polls
    /// `node.phase` at 60Hz inside its own `TimelineView` to drive the
    /// playhead — no engine-side publisher involved, so re-renders stay
    /// confined to this leaf view (Engineer P1 #3 / Programmer P2 #4).
    /// Optional so SwiftUI previews can render without a live node.
    var node: MetaParameterNode? = nil

    /// Envelope duration in seconds (currently informational — the curve
    /// itself is normalized to 0...1 along the time axis; `duration` is
    /// kept on the signature so future slices can render a time ruler
    /// without changing the call site).
    let duration: Float

    /// Loop mode — when true, the playhead wraps and the curve is drawn
    /// as a continuous loopable shape (no visual "end" cliff).
    let loopMode: Bool

    /// Fallback playhead position (0...1) used only when `node == nil`
    /// (previews / tests). When `node` is provided, the live `node.phase`
    /// polled at 60Hz overrides this.
    var progress: Double = 0

    /// Edit callback. When `nil`, the view is read-only (Slice 1 behavior
    /// preserved exactly — no gestures attach, no highlight state). When
    /// non-nil, drag-to-edit is enabled and the gestures become the
    /// interface. See `EnvelopeEdit` for the intent set.
    var onEdit: ((EnvelopeEdit) -> Void)? = nil

    /// Inset so vertex markers at the edges stay inside the panel.
    private let inset: CGFloat = 6

    // MARK: - Edit gesture state (Slice 2)

    /// id of the vertex currently being dragged, if any. Drives the
    /// active-vertex highlight (slightly larger circle, same `DS.neonAmbar`).
    @State private var draggingId: UUID?

    /// True between the insert-on-curve-body gesture start and the moment
    /// we resolve the just-inserted breakpoint's id (on the next tick,
    /// once the parent has re-rendered with the new breakpoint). While
    /// true, the move callback holds off until `draggingId` is bound.
    @State private var pendingInsert = false

    var body: some View {
        // 60Hz leaf-local refresh (Engineer P1 #3 / Programmer P2 #4).
        // The TimelineView re-evaluates only this view's body 60×/sec;
        // `node.phase` is polled inline so no engine-side publisher is
        // needed and the 1323-line `PerformanceMotherbaseView` body is
        // no longer invalidated at 60Hz. Same pattern as `MacroVUMeter`
        // (30Hz). Gestures inside the closure still work — the
        // `TimelineView` wraps the existing body verbatim.
        TimelineView(.periodic(from: .now, by: 1.0 / 60.0)) { _ in
            GeometryReader { geo in
                let rect = CGRect(origin: .zero, size: geo.size)
                    .insetBy(dx: inset, dy: inset)
                ZStack {
                    background
                    curveFill(in: rect)
                    curveStroke(in: rect)
                    playhead(progress: liveProgress, in: rect)
                    vertexMarkers(in: rect)
                }
                .contentShape(Rectangle())
                .gesture(editGesture(in: rect))
            }
            .frame(height: 96)
            .background(DS.panelHollow)
            .overlay(
                RoundedRectangle(cornerRadius: DS.radiusSM)
                    .stroke(DS.border, lineWidth: 1)
            )
            .cornerRadius(DS.radiusSM)
        }
    }

    /// Live playhead position polled from `node.phase` at the
    /// TimelineView's 60Hz tick. Falls back to the static `progress`
    /// (used by previews / node-less mounts).
    private var liveProgress: Double {
        node.map { Double($0.phase) } ?? progress
    }

    // MARK: - Background

    private var background: some View {
        // Subtle inner channel — the sunken track the curve sits in.
        // No grid, no labels. The curve is the interface.
        RoundedRectangle(cornerRadius: DS.radiusSM)
            .fill(DS.panelHollow)
    }

    // MARK: - Curve Path

    /// Stroked curve through the breakpoints, honoring each segment's
    /// `CurveType` by sampling the same shaping function the DSP uses
    /// (see `MetaParameterNode.interpolateValue`). This is the honest
    /// shape — not a Catmull-Rom smoothing that would lie about the
    /// actual envelope the audio thread sees.
    private func curveStroke(in rect: CGRect) -> some View {
        Path { path in
            addSampledCurve(to: &path, in: rect)
        }
        .stroke(DS.neonAmbar, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
    }

    /// Filled area under the curve — sparse amber wash, no gradient.
    private func curveFill(in rect: CGRect) -> some View {
        Path { path in
            guard let first = pointAt(breakpointIndex: 0, in: rect) else { return }
            path.move(to: CGPoint(x: first.x, y: rect.maxY))
            path.addLine(to: first)
            addSampledCurve(to: &path, in: rect)
            if let last = pointAt(breakpointIndex: breakpoints.count - 1, in: rect) {
                path.addLine(to: CGPoint(x: last.x, y: rect.maxY))
            }
            path.closeSubpath()
        }
        .fill(DS.neonAmbar.opacity(0.08))
    }

    /// Appends a finely-sampled polyline through all breakpoints to `path`.
    /// Honors per-segment `CurveType` so the visual matches the DSP output.
    private func addSampledCurve(to path: inout Path, in rect: CGRect) {
        guard breakpoints.count >= 2 else {
            // Single point or empty — draw a flat line at the value.
            if let p = pointAt(breakpointIndex: 0, in: rect) {
                path.move(to: p)
                path.addLine(to: CGPoint(x: rect.maxX, y: p.y))
            }
            return
        }

        let first = pointAt(breakpointIndex: 0, in: rect)!
        path.move(to: first)

        for i in 0..<(breakpoints.count - 1) {
            let from = breakpoints[i]
            let to = breakpoints[i + 1]
            let fromPt = pointAt(breakpointIndex: i, in: rect)!
            let toPt = pointAt(breakpointIndex: i + 1, in: rect)!

            let segmentSpan = max(to.time - from.time, 0.0001)
            for s in 1...kSamplesPerSegment {
                let t = Float(s) / Float(kSamplesPerSegment)
                let shaped = shapeT(t, curve: from.curve)
                let x = fromPt.x + (toPt.x - fromPt.x) * CGFloat(t)
                let y = fromPt.y + (toPt.y - fromPt.y) * CGFloat(shaped)
                path.addLine(to: CGPoint(x: x, y: y))
            }
            _ = segmentSpan  // kept for clarity; shaping is t-based
        }
    }

    // MARK: - Playhead

    private func playhead(progress p: Double, in rect: CGRect) -> some View {
        let clamped = max(0, min(1, p))
        let x = rect.minX + rect.width * clamped
        return Path { path in
            path.move(to: CGPoint(x: x, y: rect.minY))
            path.addLine(to: CGPoint(x: x, y: rect.maxY))
        }
        .stroke(DS.textTertiary, style: StrokeStyle(lineWidth: 1))
    }

    // MARK: - Vertex Markers (Slice 2: interactive when onEdit != nil)

    private func vertexMarkers(in rect: CGRect) -> some View {
        ZStack {
            ForEach(Array(breakpoints.enumerated()), id: \.element.id) { idx, bp in
                if let p = pointAt(breakpointIndex: idx, in: rect) {
                    let isActive = draggingId == bp.id
                    let canDelete = onEdit != nil && breakpoints.count > 2
                    // Visible dot — grows slightly while being dragged.
                    // Same `DS.neonAmbar` as Slice 1; no new color.
                    ZStack {
                        // Larger transparent hit target for double-tap-to-delete.
                        Circle()
                            .fill(Color.clear)
                            .frame(width: 24, height: 24)
                        Circle()
                            .fill(DS.neonAmbar)
                            .frame(width: isActive ? 6 : 4,
                                   height: isActive ? 6 : 4)
                    }
                    .position(p)
                    .onTapGesture(count: 2) {
                        guard canDelete else { return }
                        onEdit?(.delete(id: bp.id))
                    }
                }
            }
        }
    }

    // MARK: - Edit Gesture (Slice 2)

    /// Single `DragGesture` covering the whole curve area. Hit-tests on
    /// first tick: vertex → move; empty curve body → insert-then-move.
    /// Bails immediately when `onEdit == nil`, so read-only mounts pay
    /// no behavioral cost beyond a no-op gesture attachment.
    private func editGesture(in rect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: kEditDragMinDistance)
            .onChanged { value in
                guard let onEdit = onEdit else { return }
                let n = normalize(value.location, in: rect)

                // Drag start (first onChanged): decide intent.
                if draggingId == nil && !pendingInsert {
                    if let hit = hitTestVertex(at: value.location, in: rect) {
                        draggingId = hit
                    } else {
                        onEdit(.insert(time: n.time, value: n.value))
                        pendingInsert = true
                    }
                }

                // Resolve the just-inserted vertex once the parent has
                // re-rendered with the new breakpoint. The inserted bp
                // is the nearest by time to the drag location.
                if pendingInsert, draggingId == nil {
                    if let nearest = nearestBreakpoint(to: n.time) {
                        draggingId = nearest
                        pendingInsert = false
                    }
                }

                // Propagate the move.
                if let id = draggingId {
                    onEdit(.move(id: id, time: n.time, value: n.value))
                }
            }
            .onEnded { _ in
                draggingId = nil
                pendingInsert = false
            }
    }

    // MARK: - Geometry / Hit-testing Helpers

    /// Maps a breakpoint's (time, value) to a point in `rect`.
    /// time 0..1 → x, value 0..1 → y inverted (value 1 at top).
    private func pointAt(breakpointIndex idx: Int, in rect: CGRect) -> CGPoint? {
        guard idx >= 0, idx < breakpoints.count else { return nil }
        let bp = breakpoints[idx]
        let t = max(0, min(1, bp.time))
        let v = max(0, min(1, bp.value))
        return CGPoint(
            x: rect.minX + rect.width * CGFloat(t),
            y: rect.minY + rect.height * CGFloat(1 - v)
        )
    }

    /// Converts a drag location in view-space back to normalized
    /// (time, value) in [0, 1]. This is the inverse of `pointAt`.
    private func normalize(_ loc: CGPoint, in rect: CGRect) -> (time: Float, value: Float) {
        let t = max(0, min(1, (loc.x - rect.minX) / rect.width))
        let v = max(0, min(1, 1 - (loc.y - rect.minY) / rect.height))
        return (Float(t), Float(v))
    }

    /// Returns the id of the closest vertex within `kVertexHitRadius`
    /// of `loc`, or nil if no vertex is in range. Used at drag start
    /// to distinguish move from insert.
    private func hitTestVertex(at loc: CGPoint, in rect: CGRect) -> UUID? {
        var best: (UUID, CGFloat)?
        for (idx, bp) in breakpoints.enumerated() {
            guard let p = pointAt(breakpointIndex: idx, in: rect) else { continue }
            let d = hypot(p.x - loc.x, p.y - loc.y)
            if d <= kVertexHitRadius, best == nil || d < best!.1 {
                best = (bp.id, d)
            }
        }
        return best?.0
    }

    /// Returns the id of the breakpoint whose time is closest to `t`.
    /// Used to resolve `pendingInsert`: after `onEdit(.insert)` the
    /// parent re-renders with the new bp, which is by construction the
    /// nearest one to the drag location.
    private func nearestBreakpoint(to time: Float) -> UUID? {
        breakpoints.min(by: { abs($0.time - time) < abs($1.time - time) })?.id
    }

    /// Per-segment curve shaping — mirrors `MetaParameterNode.interpolateValue`
    /// so the visualization is honest about the actual DSP curve.
    private func shapeT(_ t: Float, curve: CurveType) -> Float {
        switch curve {
        case .linear:      return t
        case .exponential: return t * t
        case .logarithmic: return sqrt(t)
        case .sCurve:      return 3 * t * t - 2 * t * t * t
        case .step:        return t < 0.5 ? 0.0 : 1.0
        }
    }
}

// MARK: - Preview

#if DEBUG
#Preview("EnvelopeCurveView — ADSR (read-only)") {
    let breakpoints: [Breakpoint] = [
        Breakpoint(time: 0.0, value: 0.0, curve: .linear),
        Breakpoint(time: 0.1, value: 1.0, curve: .exponential),
        Breakpoint(time: 0.3, value: 0.7, curve: .sCurve),
        Breakpoint(time: 1.0, value: 0.0, curve: .exponential)
    ]
    return EnvelopeCurveView(
        breakpoints: breakpoints,
        duration: 2.0,
        loopMode: false,
        progress: 0.35
    )
    .padding()
    .background(Color.black)
}

#Preview("EnvelopeCurveView — editable") {
    struct Harness: View {
        @State private var breakpoints: [Breakpoint] = [
            Breakpoint(time: 0.0, value: 0.0, curve: .linear),
            Breakpoint(time: 0.25, value: 1.0, curve: .exponential),
            Breakpoint(time: 1.0, value: 0.0, curve: .exponential)
        ]
        var body: some View {
            EnvelopeCurveView(
                breakpoints: breakpoints,
                duration: 2.0,
                loopMode: false,
                progress: 0.5,
                onEdit: { edit in
                    switch edit {
                    case .move(let id, let t, let v):
                        if let i = breakpoints.firstIndex(where: { $0.id == id }) {
                            breakpoints[i].time = max(0, min(1, t))
                            breakpoints[i].value = max(0, min(1, v))
                            breakpoints.sort { $0.time < $1.time }
                        }
                    case .insert(let t, let v):
                        breakpoints.append(Breakpoint(time: t, value: v, curve: .linear))
                        breakpoints.sort { $0.time < $1.time }
                    case .delete(let id):
                        if breakpoints.count > 2 {
                            breakpoints.removeAll { $0.id == id }
                        }
                    }
                }
            )
            .padding()
            .background(Color.black)
        }
    }
    return Harness()
}
#endif
