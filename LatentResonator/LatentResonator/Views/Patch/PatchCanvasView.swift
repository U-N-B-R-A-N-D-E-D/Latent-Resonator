import SwiftUI

// MARK: - Patch Canvas View
//
// Single SwiftUI surface that hosts the entire `NodeGraph`. Replaces
// the WebView-based PATCH editor and the separate PERFORM motherbase
// — same canvas, the lock toggle in the top bar gates editing without
// changing what you see.
//
// Architecture
//   ZStack
//     ├── grid background (subtle dotted, scales with zoom)
//     ├── CableLayer    (Bézier cables under the cards)
//     └── ForEach node → NodeCardFactory positioned at (node.x, node.y)
//
// Node positions are persisted on the `GraphNode` itself (`x`, `y`
// already exist on `BaseGraphNode`) so dragging a card immediately
// updates the model and survives a relaunch through `NodeGraphStore`.

private typealias DS = LRConstants.DS

struct PatchCanvasView: View {

    @ObservedObject var engine: NeuralEngine
    @Binding var lockMode: PatchLockMode
    @State private var focusNodeId: UUID? = nil

    /// Pan offset accumulated by trackpad-drag on empty canvas.
    @State private var pan: CGSize = .zero
    @State private var dragStart: CGSize = .zero

    /// Zoom factor. Held conservative (0.5–2.0) so users can't get lost.
    @State private var zoom: CGFloat = 1.0

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Backdrop
                LinearGradient(
                    colors: [DS.titanioBottom, DS.titanioBase],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                // Dotted grid that scales with zoom
                gridBackground

                // Cable + node content lives in one transformed coordinate
                // space so pan / zoom apply uniformly.
                content(geometry: geometry)
                    .scaleEffect(zoom, anchor: .topLeading)
                    .offset(pan)

                // Top status overlay (compact — does not steal canvas space).
                statusOverlay
            }
            .gesture(canvasPanGesture)
            .background(panGestureSurface)
            .onAppear {
                // Center the canvas on the existing nodes the first time
                // it shows up so the user lands on their patch instead of
                // staring at empty space.
                if pan == .zero {
                    pan = autoCenterOffset(in: geometry.size)
                }
            }
        }
    }

    // MARK: - Content

    private func content(geometry: GeometryProxy) -> some View {
        // Capture port locations from the cards through the preference
        // system, then feed them to the cable layer for rendering.
        ZStack {
            // Cables are drawn in the same coordinate space as the
            // node cards, but underneath them.
            cablesView(geometry: geometry)
            nodeCards
        }
        .frame(width: max(2400, geometry.size.width / max(zoom, 0.5)),
               height: max(1600, geometry.size.height / max(zoom, 0.5)),
               alignment: .topLeading)
    }

    private var nodeCards: some View {
        ForEach(Array(engine.nodeGraph.nodes.values), id: \.id) { node in
            NodeCardFactory(
                node: node,
                lockMode: lockMode,
                isFocused: focusNodeId == node.id
            )
            // Snap each card to the position stored on the node itself.
            // We use `.offset(...)` instead of `.position(...)` because
            // `.position` makes the parent ZStack offer its FULL bounds
            // as available size to the card, which then stretches the
            // card to window-width. `.offset` only shifts the rendered
            // origin and leaves the layout frame intact, so the card
            // keeps its NodeCardMetrics.minWidth (180pt) intrinsic size.
            .offset(x: CGFloat(node.x), y: CGFloat(node.y))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onTapGesture {
                focusNodeId = node.id
            }
            // NOTE — drag-to-reposition is intentionally deferred to a
            // follow-up. SwiftUI's `DragGesture.translation` is a
            // cumulative delta from the gesture's start; doing the math
            // safely needs per-node start-position bookkeeping. Skipping
            // it for the first cut keeps the canvas honest: positions
            // come from `node_graph.json` until cable editing lands.
        }
    }

    private func cablesView(geometry: GeometryProxy) -> some View {
        // The OverlayPreferenceValue pattern lets us read every port
        // location reported by the cards on the same render pass. The
        // cable layer then resolves each anchor against the parent
        // geometry and draws its Bézier on top.
        Color.clear
            .overlayPreferenceValue(PatchPortLocationsKey.self) { locations in
                CableLayer(
                    edges: Array(engine.nodeGraph.edges.values),
                    portLocations: locations,
                    lockMode: lockMode,
                    geometry: geometry
                )
            }
    }

    // MARK: - Status overlay

    private var statusOverlay: some View {
        VStack {
            HStack(spacing: 12) {
                Spacer()
                Text("ZOOM \(Int(zoom * 100))%")
                    .font(DS.font(DS.fontCaption2, weight: .bold))
                    .foregroundColor(DS.textTertiary)
                Text("\(engine.nodeGraph.nodes.count) NODES · \(engine.nodeGraph.edges.count) CABLES")
                    .font(DS.font(DS.fontCaption2, weight: .bold))
                    .foregroundColor(DS.textTertiary)
                LRSegmentPicker(
                    items: PatchLockMode.allCases,
                    selected: lockMode,
                    color: lockMode == .locked ? DS.neonAmbar : DS.neonTurquesa,
                    labelForItem: { $0.label },
                    onSelect: { lockMode = $0 }
                )
                .help("UNLOCK: drag nodes, expose connections.  LOCK: dim structure, focus on the live controls.")
            }
            .padding(.horizontal, DS.spacingLG)
            .padding(.vertical, DS.spacingSM)
            .background(.ultraThinMaterial)
            Spacer()
        }
    }

    // MARK: - Background

    private var gridBackground: some View {
        Canvas { context, size in
            let spacing: CGFloat = 32 * zoom
            let dotRadius: CGFloat = 0.8
            let xOffset = pan.width.truncatingRemainder(dividingBy: spacing)
            let yOffset = pan.height.truncatingRemainder(dividingBy: spacing)

            var x = xOffset
            while x < size.width {
                var y = yOffset
                while y < size.height {
                    context.fill(
                        Path(ellipseIn: CGRect(x: x, y: y, width: dotRadius * 2, height: dotRadius * 2)),
                        with: .color(DS.border.opacity(0.6))
                    )
                    y += spacing
                }
                x += spacing
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    // MARK: - Gestures

    /// Background drag for canvas-wide panning. Active only when the
    /// initial touch lands on the empty canvas (the gesture is attached
    /// to the underlying surface, not the cards). Locked-mode disables
    /// panning so a stray drag can't shift the live performance view.
    private var canvasPanGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                guard lockMode == .unlocked else { return }
                pan = CGSize(
                    width: dragStart.width + value.translation.width,
                    height: dragStart.height + value.translation.height
                )
            }
            .onEnded { _ in dragStart = pan }
    }

    private var panGestureSurface: some View {
        // A non-hit-tested clear background so dragging on empty canvas
        // pans, but dragging on a card lets the card's own gesture win.
        Color.clear
            .contentShape(Rectangle())
            .ignoresSafeArea()
    }

    // MARK: - Helpers

    private func autoCenterOffset(in size: CGSize) -> CGSize {
        let nodes = Array(engine.nodeGraph.nodes.values)
        guard !nodes.isEmpty else { return .zero }

        let xs = nodes.map { CGFloat($0.x) }
        let ys = nodes.map { CGFloat($0.y) }
        let minX = xs.min() ?? 0
        let minY = ys.min() ?? 0

        // Leave a small gutter from the top-left so the first node isn't
        // glued to the very edge.
        return CGSize(width: -minX + 80, height: -minY + 80)
    }
}
