import SwiftUI

// MARK: - Patch Canvas View
//
// Envion / Pure Data-style node+cable canvas. One SwiftUI surface hosts the
// entire `NodeGraph`; the lock toggle gates structural edits without hiding
// the patch. Node positions persist on each `GraphNode` (`x`, `y`) through
// `NodeGraphStore`.

private typealias DS = LRConstants.DS

struct PatchCanvasView: View {

    @ObservedObject var engine: NeuralEngine
    @Binding var lockMode: PatchLockMode
    @Binding var showTopologyReservoir: Bool
    @Binding var focusNodeId: UUID?

    /// Single shared history owner. `NodeGraphStore` holds the instance so the
    /// canvas view and `RootView` keyboard shortcuts observe the same object.
    @ObservedObject private var history = NodeGraphStore.history
    /// Single shared canvas selection. Holds `selectedNodeIds` and the
    /// snap-to-grid toggle so keyboard shortcuts can read/write them directly.
    @ObservedObject private var selectionHandler = NodeGraphStore.selection

    /// Pan offset accumulated by trackpad-drag on empty canvas.
    @State private var pan: CGSize = .zero
    @State private var dragStart: CGSize = .zero

    /// Zoom factor. Held conservative (0.5–2.0) so users can't get lost.
    @State private var zoom: CGFloat = 1.0
    /// Zoom value at the start of a magnification gesture — used to compute
    /// the absolute zoom from the gesture's relative scale.
    @State private var zoomStart: CGFloat = 1.0

    /// Node drag bookkeeping (canvas coordinates, pre-zoom). Holds the original
    /// model position for every node that is part of the active drag, so a
    /// multi-selection can be moved with one local-offset gesture and committed
    /// as a single history step.
    @State private var nodeDragOrigins: [UUID: (x: Double, y: Double)] = [:]
    /// Visual drag offset applied to the card during the gesture.
    /// Committed to `NodeGraph` only on `onEnded` to avoid the state
    /// feedback loop that made the whole canvas tremble.
    @State private var nodeDragOffsets: [UUID: CGSize] = [:]

    /// Patch cord being drawn from an output port (or the picked-up output end
    /// of an existing cable when re-routing from an input port).
    @State private var cableDragState: PatchCableDragState? = nil

    /// Resolved port positions for hit-testing cable endpoints and drawing
    /// existing cables.
    @State private var resolvedPortCenters: [PatchPortRef: CGPoint] = [:]

    /// Resolved card bounding frames in canvas space. Used for marquee selection
    /// and zoom-to-fit so we don't rely on guessed card heights.
    @State private var cardFrames: [UUID: CGRect] = [:]

    /// Transient marquee selection rect, drawn in the named canvas space.
    @State private var marqueeRect: CGRect? = nil

    /// Transient validation feedback after a failed connect attempt.
    @State private var cableEditMessage: String? = nil

    /// Minimal auto-save indicator. NodeGraph does not expose its internal
    /// save state, so we derive "SAVING…" from topology changes and confirm
    /// "SAVED" once the persisted session exists after the debounce interval.
    @State private var saveIndicator: SaveIndicator = .idle
    @State private var saveIndicatorTask: Task<Void, Never>? = nil

    /// Stable reference wrappers for the two interaction callbacks passed to
    /// every card. Held in `@StateObject`s so their environment values have a
    /// stable identity; the closures are installed from `body` once the view is
    /// mounted, so `NodeCardChrome` bodies are not invalidated by every parent
    /// re-render.
    @StateObject private var dragHandler: NodeDragHandler
    @StateObject private var portInteractionHandler: PortInteractionHandler

    init(engine: NeuralEngine, lockMode: Binding<PatchLockMode>, showTopologyReservoir: Binding<Bool>, focusNodeId: Binding<UUID?>) {
        self.engine = engine
        self._lockMode = lockMode
        self._showTopologyReservoir = showTopologyReservoir
        self._focusNodeId = focusNodeId

        // Bind the shared history owner to the live graph. The graph instance is
        // created once in `NeuralEngine` and mutated in place, so this single
        // assignment is enough for the lifetime of the app.
        NodeGraphStore.history.graph = engine.nodeGraph

        // The handler closures are installed from `body` once the @StateObjects
        // are mounted. Creating the bindings here would read the @State wrappers
        // before the view is installed, which triggers SwiftUI's "Accessing State's
        // value outside of being installed on a View" warning.
        self._dragHandler = StateObject(wrappedValue: NodeDragHandler())
        self._portInteractionHandler = StateObject(wrappedValue: PortInteractionHandler())
    }

    var body: some View {
        let _ = installHandlers()

        GeometryReader { geometry in
            ZStack {
                LinearGradient(
                    colors: [DS.titanioBottom, DS.titanioBase],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                gridBackground

                // ONE transformed container holds both cables and cards. The
                // CableLayer is a sibling of the node cards, not a background
                // of a separate view, so both share exactly the same local
                // coordinate space and the same scale/offset transform. The
                // named coordinate space is attached to this container; port
                // chips report their centers in that space, and the cable
                // layer draws directly from those centers.
                canvasContainer
                    .coordinateSpace(name: PatchCanvasSpace.name)
                    .scaleEffect(zoom, anchor: .topLeading)
                    .offset(pan)

                statusOverlay(in: geometry.size)

                if selectionHandler.showMinimap {
                    minimapOverlay(in: geometry.size)
                }
            }
            // Pan is attached to the surface container, not a background layer,
            // so empty-canvas drags are recognized even when the gradient / cards
            // sit in front. Child gestures (node header drag, port drag, sliders)
            // take precedence by living inside this container.
            .gesture(canvasPanGesture)
            .simultaneousGesture(zoomGesture(in: geometry))
            .contextMenu {
                if lockMode == .unlocked {
                    addNodeMenu(in: geometry)
                }
            }
            .onAppear {
                if pan == .zero {
                    pan = autoCenterOffset(in: geometry.size)
                }
                // Re-bind the shared history owner whenever this view appears,
                // covering re-creation after a topology load or state change.
                NodeGraphStore.history.graph = engine.nodeGraph
            }
            .onReceive(selectionHandler.$zoomToFitTrigger) { _ in
                zoomToFit(in: geometry.size)
            }
        }
    }

    /// Installs the node-drag and port-interaction closures once the view's
    /// @StateObjects are mounted. Calling this from `init` would read the
    /// @State property wrappers before installation and trigger the SwiftUI
    /// "Accessing State outside of being installed" warning.
    private func installHandlers() {
        let engine = self.engine
        let lockMode = self.lockMode
        let port = self.portInteractionHandler

        let nodeDragOriginsBinding = $nodeDragOrigins
        let nodeDragOffsetsBinding = $nodeDragOffsets

        dragHandler.handlers = NodeCardDragHandlers(
            onNodeDragChanged: { id, translation in
                guard lockMode == .unlocked else { return }
                let selected = NodeGraphStore.selection.selectedNodeIds
                let moveIds: [UUID] = selected.contains(id) ? Array(selected) : [id]
                if nodeDragOriginsBinding.wrappedValue.isEmpty {
                    var origins = nodeDragOriginsBinding.wrappedValue
                    for moveId in moveIds {
                        guard let node = engine.nodeGraph.nodes[moveId] else { continue }
                        origins[moveId] = (x: node.x, y: node.y)
                    }
                    nodeDragOriginsBinding.wrappedValue = origins
                }
                var offsets = nodeDragOffsetsBinding.wrappedValue
                for moveId in moveIds {
                    guard nodeDragOriginsBinding.wrappedValue[moveId] != nil else { continue }
                    offsets[moveId] = CGSize(width: translation.width, height: translation.height)
                }
                nodeDragOffsetsBinding.wrappedValue = offsets
            },
            onNodeDragEnded: { id in
                guard lockMode == .unlocked else { return }
                let selected = NodeGraphStore.selection.selectedNodeIds
                let moveIds: [UUID] = selected.contains(id) ? Array(selected) : [id]
                var before: [UUID: CGPoint] = [:]
                var after: [UUID: CGPoint] = [:]
                var offsets = nodeDragOffsetsBinding.wrappedValue
                let snapEnabled = NodeGraphStore.selection.snapToGrid
                for moveId in moveIds {
                    guard let offset = offsets[moveId],
                          let origin = nodeDragOriginsBinding.wrappedValue[moveId] else { continue }
                    before[moveId] = CGPoint(x: origin.x, y: origin.y)
                    var raw = CGPoint(
                        x: origin.x + Double(offset.width),
                        y: origin.y + Double(offset.height)
                    )
                    if snapEnabled {
                        raw = PatchCanvasView.snapToGrid(raw)
                    }
                    after[moveId] = raw
                    engine.nodeGraph.setNodePosition(id: moveId, x: Double(raw.x), y: Double(raw.y))
                    offsets[moveId] = nil
                }
                nodeDragOffsetsBinding.wrappedValue = offsets
                nodeDragOriginsBinding.wrappedValue = [:]
                if !before.isEmpty {
                    NodeGraphStore.history.execute(MoveNodesCommand(before: before, after: after))
                }
            }
        )

        let cableDragStateBinding = $cableDragState
        let cableEditMessageBinding = $cableEditMessage
        let resolvedPortCentersBinding = $resolvedPortCenters

        portInteractionHandler.handlers = PatchPortInteractionHandlers(
            onPortDragChanged: { portRef, point in
                guard lockMode == .unlocked else { return }
                if cableDragStateBinding.wrappedValue == nil {
                    if portRef.direction == .output {
                        cableDragStateBinding.wrappedValue = PatchCableDragState(source: portRef, currentPoint: point)
                        cableEditMessageBinding.wrappedValue = nil
                        port.activeCableDrag = portRef
                    } else if portRef.direction == .input,
                              let edge = engine.nodeGraph.edge(into: portRef.nodeId, portId: portRef.portId) {
                        // Max/Pd-style re-route: pick up the existing cable from
                        // the output port on the other end. The edge is hidden in
                        // CableLayer while the drag is in progress.
                        let sourceRef = PatchPortRef(
                            nodeId: edge.sourceNodeId,
                            portId: edge.sourcePortId,
                            direction: .output,
                            signalType: edge.signalType
                        )
                        cableDragStateBinding.wrappedValue = PatchCableDragState(
                            source: sourceRef,
                            currentPoint: point,
                            reroute: edge
                        )
                        cableEditMessageBinding.wrappedValue = nil
                        port.activeCableDrag = sourceRef
                    }
                } else if var state = cableDragStateBinding.wrappedValue {
                    state.currentPoint = point
                    cableDragStateBinding.wrappedValue = state
                }
            },
            onPortDragEnded: { portRef, point in
                guard lockMode == .unlocked else { return }
                defer {
                    cableDragStateBinding.wrappedValue = nil
                    port.activeCableDrag = nil
                }

                let threshold: CGFloat = 22
                var best: (PatchPortRef, CGFloat)? = nil
                for (ref, center) in resolvedPortCentersBinding.wrappedValue {
                    guard ref.direction == .input, ref.signalType == portRef.signalType else { continue }
                    let dist = hypot(center.x - point.x, center.y - point.y)
                    if dist <= threshold, best == nil || dist < best!.1 {
                        best = (ref, dist)
                    }
                }

                let dragState = cableDragStateBinding.wrappedValue
                let source = dragState?.source ?? portRef

                guard let target = best?.0 else {
                    // Drop on empty space: if this was a re-route, disconnect the old cable.
                    if let reroute = dragState?.reroute, engine.nodeGraph.edges[reroute.id] != nil {
                        NodeGraphStore.history.execute(DisconnectEdgeCommand(edgeId: reroute.id, graph: engine.nodeGraph))
                        cableEditMessageBinding.wrappedValue = "Cable disconnected"
                    } else {
                        cableEditMessageBinding.wrappedValue = "Drop on an input port"
                        #if DEBUG
                        print("[Cable] no input port near \(point) — resolvedPortCenters has \(resolvedPortCentersBinding.wrappedValue.count) ports")
                        #endif
                    }
                    return
                }

                guard source.direction == .output, target.direction == .input, source.nodeId != target.nodeId else { return }

                if let reroute = dragState?.reroute {
                    guard reroute.targetNodeId != target.nodeId || reroute.targetPortId != target.portId else {
                        // Dropped back on the same input: leave the original cable intact.
                        return
                    }
                    let ok = NodeGraphStore.history.execute(Self.connectCommand(source: source, target: target, replacing: reroute, graph: engine.nodeGraph))
                    cableEditMessageBinding.wrappedValue = ok ? "Cable re-routed" : "Cable rejected"
                    #if DEBUG
                    if ok {
                        print("[Cable] re-routed \(source.nodeId.uuidString.prefix(8)):\(source.portId) -> \(target.nodeId.uuidString.prefix(8)):\(target.portId)")
                    }
                    #endif
                } else {
                    let ok = NodeGraphStore.history.execute(Self.connectCommand(source: source, target: target, replacing: nil, graph: engine.nodeGraph))
                    cableEditMessageBinding.wrappedValue = ok ? "Connected" : "Cable rejected"
                    #if DEBUG
                    if ok {
                        print("[Cable] connected \(source.nodeId.uuidString.prefix(8)):\(source.portId) -> \(target.nodeId.uuidString.prefix(8)):\(target.portId)")
                    }
                    #endif
                }
            },
            onPortSecondaryClick: { portRef in
                guard lockMode == .unlocked else { return }
                // Disconnect all edges touching this port as one history step.
                let edges = engine.nodeGraph.edges.values.filter { edge in
                    (edge.sourceNodeId == portRef.nodeId && edge.sourcePortId == portRef.portId)
                        || (edge.targetNodeId == portRef.nodeId && edge.targetPortId == portRef.portId)
                }
                if edges.isEmpty { return }
                let commands = edges.map { DisconnectEdgeCommand(edgeId: $0.id, graph: engine.nodeGraph) }
                NodeGraphStore.history.execute(CompoundCommand(commands: commands))
                cableEditMessageBinding.wrappedValue = "Port disconnected"
            }
        )
    }

    /// Builds a compound connect command that disconnects any existing audio
    /// input on the target and (for re-routes) the old cable, then connects
    /// the new edge. All of it is recorded as a single history step.
    private static func connectCommand(
        source: PatchPortRef,
        target: PatchPortRef,
        replacing reroute: GraphEdge?,
        graph: NodeGraph
    ) -> GraphCommand {
        var commands: [GraphCommand] = []
        if let reroute = reroute, graph.edges[reroute.id] != nil {
            commands.append(DisconnectEdgeCommand(edgeId: reroute.id, graph: graph))
        }
        if target.signalType == .audio,
           let existing = graph.edge(into: target.nodeId, portId: target.portId),
           existing.id != reroute?.id {
            commands.append(DisconnectEdgeCommand(edgeId: existing.id, graph: graph))
        }
        commands.append(ConnectEdgeCommand(edge: GraphEdge(
            id: UUID(),
            sourceNodeId: source.nodeId,
            sourcePortId: source.portId,
            targetNodeId: target.nodeId,
            targetPortId: target.portId,
            signalType: source.signalType
        )))
        return CompoundCommand(commands: commands)
    }

    // MARK: - Canvas container (single transform for cables + cards)

    private var canvasContainer: some View {
        GeometryReader { canvasGeometry in
            // Hide the picked-up edge during a re-route so it looks like the
            // cable is being moved, not duplicated.
            let visibleEdges = Array(engine.nodeGraph.edges.values).filter { edge in
                edge.id != cableDragState?.reroute?.id
            }

            ZStack(alignment: .topLeading) {
                // Invisible full-area tap target behind cables and cards so
                // clicking empty canvas space clears the selection.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectionHandler.selectedNodeIds.removeAll()
                    }

                CableLayer(
                    edges: visibleEdges,
                    lockMode: lockMode,
                    previewDrag: cableDragState,
                    resolvedCenters: resolvedPortCenters,
                    onSelectEdge: { edgeId in
                        guard lockMode == .unlocked else { return }
                        guard engine.nodeGraph.edges[edgeId] != nil else { return }
                        NodeGraphStore.history.execute(DisconnectEdgeCommand(edgeId: edgeId, graph: engine.nodeGraph))
                        cableEditMessage = "Cable removed"
                    }
                )

                nodeCards

                if let marqueeRect = marqueeRect {
                    Rectangle()
                        .stroke(DS.neonTurquesa, lineWidth: 1)
                        .background(DS.neonTurquesa.opacity(0.08))
                        .frame(width: marqueeRect.width, height: marqueeRect.height)
                        .position(x: marqueeRect.midX, y: marqueeRect.midY)
                }
            }
            .frame(width: max(2400, canvasGeometry.size.width / max(zoom, 0.5)),
                   height: max(1600, canvasGeometry.size.height / max(zoom, 0.5)),
                   alignment: .topLeading)
            .onPreferenceChange(PatchPortLocationsKey.self) { locations in
                #if DEBUG
                print("[PortPref] count=\(locations.count) first=\(locations.first?.center ?? .zero)")
                #endif
                // Each port chip reports a resolved CGPoint in the named
                // canvas space. Updates only fire when a port's center
                // actually changes (drag, card resize, add/remove), not on
                // every pan/zoom frame.
                resolvedPortCenters = resolvePortCenters(locations: locations)
            }
            .onPreferenceChange(PatchCardFramesKey.self) { frames in
                // Collect the real rendered card frames in canvas space. Used
                // for marquee selection and zoom-to-fit instead of guessing
                // card heights from constants.
                var map: [UUID: CGRect] = [:]
                for frame in frames { map[frame.nodeId] = frame.frame }
                cardFrames = map
            }
            .onReceive(engine.nodeGraph.topologyDidChange) { _ in
                // Auto-save is debounced inside NodeGraph; the indicator gives
                // the performer a minimal confirmation that the edit is being
                // persisted without reading private NodeGraph state.
                scheduleSaveIndicator()
            }
            .environment(\.portInteractionHandler, portInteractionHandler)
            .environmentObject(portInteractionHandler)
            .environment(\.nodeDragHandler, dragHandler)
            .environmentObject(selectionHandler)
        }
    }

    private var nodeCards: some View {
        ForEach(Array(engine.nodeGraph.nodes.values), id: \.id) { node in
            nodeCardView(for: node)
        }
    }

    private func nodeCardView(for node: any GraphNode) -> some View {
        let dragOffset = nodeDragOffsets[node.id] ?? .zero
        #if DEBUG
        print("[Card] id=\(node.id.uuidString.prefix(8)) x=\(node.x) y=\(node.y)")
        #endif
        return NodeCardFactory(
            engine: engine,
            node: node,
            lockMode: lockMode,
            isFocused: focusNodeId == node.id
        )
        .offset(
            x: CGFloat(node.x) + dragOffset.width,
            y: CGFloat(node.y) + dragOffset.height
        )
        .onTapGesture {
            if NSEvent.modifierFlags.contains(.shift) {
                if selectionHandler.selectedNodeIds.contains(node.id) {
                    selectionHandler.selectedNodeIds.remove(node.id)
                } else {
                    selectionHandler.selectedNodeIds.insert(node.id)
                }
            } else {
                selectionHandler.selectedNodeIds = [node.id]
                focusNodeId = node.id
            }
        }
        .contextMenu {
            nodeContextMenu(for: node)
        }
    }

    @ViewBuilder
    private func nodeContextMenu(for node: any GraphNode) -> some View {
        if lockMode == .unlocked {
            let selected = selectionHandler.selectedNodeIds
            let targetIds = selected.isEmpty ? [node.id] : Array(selected)
            let deletable = targetIds.filter { engine.nodeGraph.nodes[$0]?.nodeType != "master_output" }
            Button(role: .destructive) {
                guard !deletable.isEmpty else { return }
                let commands = deletable.map { RemoveNodeCommand(nodeId: $0, graph: engine.nodeGraph) }
                if NodeGraphStore.history.execute(CompoundCommand(commands: commands)) {
                    for id in deletable {
                        if focusNodeId == id { focusNodeId = nil }
                    }
                    selectionHandler.selectedNodeIds.subtract(deletable)
                    cableEditMessage = "\(deletable.count) node(s) removed"
                }
            } label: {
                Label("Remove node", systemImage: "trash")
            }
            .disabled(deletable.isEmpty)
        }
    }

    // MARK: - Port / cable geometry

    private func resolvePortCenters(
        locations: [PatchPortLocation]
    ) -> [PatchPortRef: CGPoint] {
        var map: [PatchPortRef: CGPoint] = [:]
        for loc in locations {
            let ref = PatchPortRef(
                nodeId: loc.nodeId,
                portId: loc.portId,
                direction: loc.direction,
                signalType: loc.signalType
            )
            map[ref] = loc.center
        }
        return map
    }

    // MARK: - Node drag

    // MARK: - Add-node palette

    /// Stage-grouped node palette (Envion §3.1 — coarse named stages, not a
    /// flat type list). Right-click on empty canvas reveals this menu; the
    /// new node lands at the visible viewport center so placement is
    /// predictable and the performer can drag it into place.
    private func addNodeMenu(in geometry: GeometryProxy) -> some View {
        var position = viewportCenter(in: geometry)
        if selectionHandler.snapToGrid {
            position = PatchCanvasView.snapToGrid(position)
        }
        return ForEach(NodePalette.groups, id: \.stage) { group in
            Section(group.stage) {
                ForEach(group.entries, id: \.type) { entry in
                    Button {
                        let command = AddNodeCommand(nodeType: entry.type, position: position)
                        if NodeGraphStore.history.execute(command), let newId = command.createdNodeId {
                            focusNodeId = newId
                            selectionHandler.selectedNodeIds = [newId]
                            cableEditMessage = "\(entry.label) added"
                        }
                    } label: {
                        Label(entry.label, systemImage: entry.icon)
                    }
                }
            }
        }
    }

    private func viewportCenter(in geometry: GeometryProxy) -> CGPoint {
        CGPoint(
            x: Double((geometry.size.width / 2 - pan.width) / zoom),
            y: Double((geometry.size.height / 2 - pan.height) / zoom)
        )
    }

    // MARK: - Status overlay

    private func statusOverlay(in size: CGSize) -> some View {
        VStack {
            HStack(spacing: 12) {
                Button(action: { showTopologyReservoir = true }) {
                    HStack(spacing: 4) {
                        Image(systemName: "square.stack.3d.up")
                            .font(.system(size: 9, weight: .bold))
                        Text("RESERVOIR")
                            .font(DS.font(DS.fontCaption2, weight: .bold))
                    }
                    .foregroundColor(DS.neonTurquesa)
                }
                .buttonStyle(.plain)
                .help("Load or save topology")

                Spacer()

                if let cableEditMessage {
                    Text(cableEditMessage.uppercased())
                        .font(DS.font(DS.fontCaption2, weight: .bold))
                        .foregroundColor(DS.neonAmbar)
                        .task(id: cableEditMessage) {
                            // Auto-clear transient cable/edit feedback after 2.5s
                            // so the overlay does not lie about a stale action.
                            try? await Task.sleep(nanoseconds: 2_500_000_000)
                            self.cableEditMessage = nil
                        }
                }

                Button(action: { NodeGraphStore.history.undo() }) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(history.canUndo ? DS.textPrimary : DS.textDisabled)
                }
                .buttonStyle(.plain)
                .disabled(!history.canUndo)
                .help("Undo (Cmd+Z)")

                Button(action: { NodeGraphStore.history.redo() }) {
                    Image(systemName: "arrow.uturn.forward")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(history.canRedo ? DS.textPrimary : DS.textDisabled)
                }
                .buttonStyle(.plain)
                .disabled(!history.canRedo)
                .help("Redo (Cmd+Shift+Z)")

                Button(action: { selectionHandler.snapToGrid.toggle() }) {
                    Image(systemName: selectionHandler.snapToGrid ? "grid" : "grid.circle")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(selectionHandler.snapToGrid ? DS.neonTurquesa : DS.textTertiary)
                }
                .buttonStyle(.plain)
                .help("Toggle snap to grid (G)")

                Button(action: { zoomToFit(in: size) }) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(DS.textTertiary)
                }
                .buttonStyle(.plain)
                .help("Zoom to fit (Cmd+0)")

                Button(action: { selectionHandler.showMinimap.toggle() }) {
                    Image(systemName: selectionHandler.showMinimap ? "map.fill" : "map")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(selectionHandler.showMinimap ? DS.neonTurquesa : DS.textTertiary)
                }
                .buttonStyle(.plain)
                .help("Toggle minimap (Cmd+Shift+M)")

                Button(action: resetView) {
                    Text("ZOOM \(Int(zoom * 100))%")
                        .font(DS.font(DS.fontCaption2, weight: .bold))
                        .foregroundColor(zoom == 1.0 ? DS.textTertiary : DS.neonTurquesa)
                }
                .buttonStyle(.plain)
                .help("Reset view — zoom to 100% and re-center")
                Text("\(distinctStageCount) STAGES · \(engine.nodeGraph.edges.count) CABLES")
                    .font(DS.font(DS.fontCaption2, weight: .bold))
                    .foregroundColor(DS.textTertiary)

                switch saveIndicator {
                case .idle:
                    EmptyView()
                case .saving:
                    Text("SAVING…")
                        .font(DS.font(DS.fontCaption2, weight: .bold))
                        .foregroundColor(DS.neonTurquesa)
                case .saved:
                    Text("SAVED")
                        .font(DS.font(DS.fontCaption2, weight: .bold))
                        .foregroundColor(DS.success)
                }

                LRSegmentPicker(
                    items: PatchLockMode.allCases,
                    selected: lockMode,
                    color: lockMode == .locked ? DS.neonAmbar : DS.neonTurquesa,
                    labelForItem: { $0.label },
                    onSelect: { lockMode = $0 }
                )
                .help("UNLOCK: drag nodes, patch cables. LOCK: play without editing topology.")
            }
            .padding(.horizontal, DS.spacingLG)
            .padding(.vertical, DS.spacingSM)
            .background(.ultraThinMaterial)
            Spacer()
        }
    }

    private func resetView() {
        withAnimation(.easeOut(duration: 0.2)) {
            zoom = 1.0
            zoomStart = 1.0
        }
        // `autoCenterOffset` derives the offset from node bounds; the size
        // param is unused on this path, so `.zero` is safe here.
        pan = autoCenterOffset(in: .zero)
    }

    // MARK: - Background

    private var gridBackground: some View {
        Canvas { context, size in
            let spacing = PatchCanvasMetrics.gridSize * zoom
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

    private var canvasPanGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                if NSEvent.modifierFlags.contains(.shift) {
                    // Shift+drag draws a marquee selection rect in the named
                    // canvas space. Plain drag continues to pan the canvas.
                    let start = screenToCanvas(value.startLocation)
                    let current = screenToCanvas(value.location)
                    marqueeRect = CGRect(
                        x: min(start.x, current.x),
                        y: min(start.y, current.y),
                        width: abs(current.x - start.x),
                        height: abs(current.y - start.y)
                    )
                } else {
                    // Pan works in both LOCK and UNLOCK — navigating the canvas is
                    // not a topology edit. Only node drag / cable edit are gated
                    // by `lockMode` (see `nodeDragGesture`, `portInteractionHandlers`).
                    pan = CGSize(
                        width: dragStart.width + value.translation.width,
                        height: dragStart.height + value.translation.height
                    )
                }
            }
            .onEnded { _ in
                if NSEvent.modifierFlags.contains(.shift) {
                    finalizeMarquee()
                    marqueeRect = nil
                } else {
                    dragStart = pan
                }
            }
    }

    private func zoomGesture(in geometry: GeometryProxy) -> some Gesture {
        MagnificationGesture()
            .onChanged { scale in
                let proposed = zoomStart * scale
                let newZoom = min(max(proposed, PatchCanvasMetrics.minZoom), PatchCanvasMetrics.maxZoom)
                guard zoom != 0 else { return }
                // Zoom toward the viewport center so the patch stays anchored
                // under the performer's focus. Adjust pan so the center point
                // remains fixed in screen space.
                let zoomRatio = newZoom / zoom
                let center = CGPoint(
                    x: geometry.size.width / 2,
                    y: geometry.size.height / 2
                )
                pan = CGSize(
                    width: center.x - (center.x - pan.width) * zoomRatio,
                    height: center.y - (center.y - pan.height) * zoomRatio
                )
                zoom = newZoom
            }
            .onEnded { _ in
                zoomStart = zoom
                dragStart = pan
            }
    }

    // MARK: - Helpers

    /// BUG 4 fix: the mode tab for this view is labeled "STAGES" (see
    /// `RootView.modeToggleBar`), but the status readout here used to show
    /// `nodeGraph.nodes.count` under that label — the total node count, not
    /// a stage count. Several nodes routinely share one `StageKind` (three
    /// oscillators are all "seed"), so the number was actively misleading
    /// about how many signal stages the current patch actually has. This
    /// mirrors PERFORM's own "N STAGES" figure (`stageGroups.count` in
    /// `PerformanceMotherbaseView`), computed the same way: distinct
    /// `effectiveStageKind` values across the graph's nodes.
    private var distinctStageCount: Int {
        Set(engine.nodeGraph.nodes.values.compactMap { $0.effectiveStageKind }).count
    }

    private func autoCenterOffset(in size: CGSize) -> CGSize {
        let nodes = Array(engine.nodeGraph.nodes.values)
        guard !nodes.isEmpty else { return .zero }

        let xs = nodes.map { CGFloat($0.x) }
        let ys = nodes.map { CGFloat($0.y) }
        let minX = xs.min() ?? 0
        let minY = ys.min() ?? 0

        return CGSize(width: -minX + 80, height: -minY + 80)
    }

    /// Convert a screen-space point from the outer `GeometryReader` into the
    /// named `PatchCanvasSpace` coordinate system. The canvas container applies
    /// `.offset(pan)` and `.scaleEffect(zoom)` after the coordinate space, so
    /// the inverse transform is `(point - pan) / zoom`.
    private func screenToCanvas(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: (point.x - pan.width) / zoom,
            y: (point.y - pan.height) / zoom
        )
    }

    /// Select every node whose reported card frame intersects the marquee rect.
    private func finalizeMarquee() {
        guard let rect = marqueeRect else { return }
        var newSelection = Set<UUID>()
        for (nodeId, frame) in cardFrames where frame.intersects(rect) {
            newSelection.insert(nodeId)
        }
        selectionHandler.selectedNodeIds = newSelection
    }

    /// Round a canvas-space point to the nearest visual grid intersection.
    private static func snapToGrid(_ point: CGPoint) -> CGPoint {
        let gridSize = PatchCanvasMetrics.gridSize
        return CGPoint(
            x: round(point.x / gridSize) * gridSize,
            y: round(point.y / gridSize) * gridSize
        )
    }

    /// Compute the bounding box of all rendered cards and fit the viewport to it
    /// with a small margin. Clamped to the canvas zoom range.
    private func zoomToFit(in size: CGSize) {
        let allNodes = Array(engine.nodeGraph.nodes.values)
        guard !allNodes.isEmpty else { return }

        let frames = Array(cardFrames.values)
        let bbox: CGRect
        if !frames.isEmpty {
            bbox = frames.reduce(frames[0]) { $0.union($1) }
        } else {
            // Fallback before the first layout pass: estimate from node positions.
            let xs = allNodes.map { CGFloat($0.x) }
            let ys = allNodes.map { CGFloat($0.y) }
            let minX = xs.min() ?? 0
            let minY = ys.min() ?? 0
            let maxX = xs.max() ?? 0
            let maxY = ys.max() ?? 0
            bbox = CGRect(
                x: minX,
                y: minY,
                width: max(maxX - minX + NodeCardMetrics.minWidth, NodeCardMetrics.minWidth),
                height: max(maxY - minY + NodeCardMetrics.estimatedHeight, NodeCardMetrics.estimatedHeight)
            )
        }

        let margin: CGFloat = 40
        let padded = bbox.insetBy(dx: -margin, dy: -margin)
        let zoomX = size.width / padded.width
        let zoomY = size.height / padded.height
        let newZoom = min(max(min(zoomX, zoomY), PatchCanvasMetrics.minZoom), PatchCanvasMetrics.maxZoom)

        let newPan = CGSize(
            width: (size.width / 2) - (padded.midX * newZoom),
            height: (size.height / 2) - (padded.midY * newZoom)
        )

        withAnimation(.easeOut(duration: 0.2)) {
            zoom = newZoom
            zoomStart = newZoom
            pan = newPan
            dragStart = newPan
        }
    }

    private enum SaveIndicator: Equatable {
        case idle, saving, saved
    }

    /// Reflects the graph's debounced auto-save without touching NodeGraph internals.
    /// Topology changes move the badge to SAVING; after the debounce interval we
    /// confirm SAVED if a persisted session exists.
    private func scheduleSaveIndicator() {
        saveIndicatorTask?.cancel()
        saveIndicator = .saving
        saveIndicatorTask = Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            saveIndicator = NodeGraphStore.hasSavedSession ? .saved : .idle
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            saveIndicator = .idle
        }
    }

    // MARK: - Minimap

    /// Floating minimap overlay anchored to the bottom-right of the canvas.
    /// Reads published node positions directly, so it updates on topology
    /// changes and drag commits without any per-frame environment trickery.
    private func minimapOverlay(in size: CGSize) -> some View {
        let nodes = Array(engine.nodeGraph.nodes.values)
        let world = minimapWorld(in: size)
        let scale = minimapScale(world: world)
        let viewport = minimapViewport(in: size)

        return VStack {
            Spacer()
            HStack {
                Spacer()
                MinimapView(
                    nodes: nodes,
                    viewport: viewport,
                    world: world,
                    scale: scale
                ) { minimapPoint in
                    let worldPoint = CGPoint(
                        x: world.origin.x + Double(minimapPoint.x / scale),
                        y: world.origin.y + Double(minimapPoint.y / scale)
                    )
                    withAnimation(.easeOut(duration: 0.2)) {
                        pan = CGSize(
                            width: size.width / 2 - CGFloat(worldPoint.x) * zoom,
                            height: size.height / 2 - CGFloat(worldPoint.y) * zoom
                        )
                        dragStart = pan
                    }
                }
                .padding(PatchCanvasMetrics.minimapMargin)
            }
        }
    }

    /// Bounding box of all node cards plus the current viewport, padded so the
    /// minimap stays useful even when the viewport is larger than the nodes.
    private func minimapWorld(in size: CGSize) -> CGRect {
        let viewport = minimapViewport(in: size)
        var world = viewport
        for node in engine.nodeGraph.nodes.values {
            let nodeRect = CGRect(
                x: node.x,
                y: node.y,
                width: Double(NodeCardMetrics.minWidth),
                height: Double(NodeCardMetrics.estimatedHeight)
            )
            world = world.union(nodeRect)
        }
        let padding = PatchCanvasMetrics.minimapWorldPadding
        return world.insetBy(dx: -Double(padding), dy: -Double(padding))
    }

    /// Current visible canvas area in the named canvas space.
    private func minimapViewport(in size: CGSize) -> CGRect {
        CGRect(
            x: Double(-pan.width / zoom),
            y: Double(-pan.height / zoom),
            width: Double(size.width / zoom),
            height: Double(size.height / zoom)
        )
    }

    private func minimapScale(world: CGRect) -> CGFloat {
        let minimapSize = PatchCanvasMetrics.minimapSize
        guard world.width > 0 && world.height > 0 else { return 1 }
        return min(
            minimapSize.width / CGFloat(world.width),
            minimapSize.height / CGFloat(world.height)
        )
    }
}

/// Scaled-down overview of the patch. Draws node rectangles and the viewport
/// frame; tap or drag to recenter the canvas on that world point.
private struct MinimapView: View {
    let nodes: [any GraphNode]
    let viewport: CGRect
    let world: CGRect
    let scale: CGFloat
    let onSelect: (CGPoint) -> Void

    var body: some View {
        Canvas { context, _ in
            let panel = CGRect(origin: .zero, size: PatchCanvasMetrics.minimapSize)
            let panelPath = Path(
                roundedRect: panel,
                cornerRadius: PatchCanvasMetrics.minimapCornerRadius
            )
            context.fill(panelPath, with: .color(DS.surfaceOverlay))
            context.stroke(panelPath, with: .color(DS.border), lineWidth: 1)

            for node in nodes {
                let rect = CGRect(
                    x: (node.x - world.origin.x) * Double(scale),
                    y: (node.y - world.origin.y) * Double(scale),
                    width: Double(NodeCardMetrics.minWidth) * Double(scale),
                    height: Double(NodeCardMetrics.estimatedHeight) * Double(scale)
                )
                context.fill(Path(rect), with: .color(DS.textTertiary.opacity(0.5)))
            }

            let viewportRect = CGRect(
                x: (viewport.origin.x - world.origin.x) * Double(scale),
                y: (viewport.origin.y - world.origin.y) * Double(scale),
                width: viewport.size.width * Double(scale),
                height: viewport.size.height * Double(scale)
            )
            let viewportPath = Path(
                roundedRect: viewportRect,
                cornerRadius: PatchCanvasMetrics.minimapCornerRadius / 2
            )
            context.stroke(viewportPath, with: .color(DS.neonTurquesa), lineWidth: 1.5)
        }
        .frame(width: PatchCanvasMetrics.minimapSize.width,
               height: PatchCanvasMetrics.minimapSize.height)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    onSelect(value.location)
                }
        )
    }
}

// MARK: - Node Palette
//
// Stage-grouped catalogue of insertable node types. Mirrors Envion's coarse
// stage taxonomy (§3.1): Seed / Resonator / Spectra / Ladder / Echo / Flat,
// plus the Control / Neural / Macro auxiliaries. The palette is the only
// surface that grows when a new node type lands — `NodeFactory` and the
// canvas pick it up automatically.

private struct NodePalette {
    struct Entry: Hashable {
        let type: String
        let label: String
        let icon: String
    }

    struct Group: Hashable {
        let stage: String
        let entries: [Entry]
    }

    static let groups: [Group] = [
        Group(stage: "SEED", entries: [
            Entry(type: "oscillator",    label: "Oscillator",    icon: "waveform"),
            Entry(type: "noise",          label: "Noise",        icon: "waveform.path"),
            Entry(type: "koenig_seed",    label: "Koenig Seed",   icon: "seal"),
            Entry(type: "audio_input",    label: "Audio Input",  icon: "mic"),
        ]),
        Group(stage: "RESONATOR", entries: [
            Entry(type: "feedback_loop",       label: "Feedback Loop",   icon: "arrow.triangle.2.circlepath"),
            Entry(type: "ace_step_inference",  label: "ACE Inference",   icon: "brain.head.profile"),
        ]),
        Group(stage: "SPECTRA", entries: [
            Entry(type: "spectral_chain",    label: "Spectral Chain",  icon: "chart.line.uptrend.xyaxis"),
            Entry(type: "spectral_analyzer", label: "Spectral Analyzer", icon: "chart.bar"),
            Entry(type: "spectral_feedback", label: "Spectral Feedback", icon: "infinity"),
        ]),
        Group(stage: "LADDER", entries: [
            Entry(type: "ladder_filter",     label: "Ladder Filter",    icon: "slider.horizontal.3"),
            Entry(type: "comb_filter",       label: "Comb Filter",      icon: "slider.vertical.3"),
            Entry(type: "tunable_resonator", label: "Tunable Resonator", icon: "tuningfork"),
            Entry(type: "bit_crusher",       label: "Bit Crusher",      icon: "square.grid.3x3"),
            Entry(type: "waveshaper",        label: "Waveshaper",       icon: "waveform.path.ecg"),
        ]),
        Group(stage: "ECHO", entries: [
            Entry(type: "delay_line", label: "Delay Line", icon: "clock.arrow.circlepath"),
            Entry(type: "reverb",     label: "Reverb",     icon: "wave.3.right"),
        ]),
        Group(stage: "FLAT", entries: [
            Entry(type: "mixer",        label: "Mixer",        icon: "slider.horizontal.2.square"),
            Entry(type: "passthrough",  label: "Passthrough",  icon: "arrow.right"),
            Entry(type: "silence",      label: "Silence",      icon: "speaker.slash"),
            Entry(type: "master_output", label: "Master Out",  icon: "speaker.wave.3"),
        ]),
        Group(stage: "CONTROL", entries: [
            Entry(type: "meta_parameter",    label: "Meta Parameter",   icon: "gauge"),
            Entry(type: "step_sequencer",    label: "Step Sequencer",    icon: "square.grid.4x4.fill"),
            Entry(type: "markov_sequencer",  label: "Markov Sequencer",  icon: "shuffle"),
            Entry(type: "gesture_recorder", label: "Gesture Recorder",  icon: "hand.draw"),
            Entry(type: "agitation",         label: "Agitation",         icon: "tornado"),
            Entry(type: "peak",              label: "Peak",              icon: "mountain.2"),
            Entry(type: "manual_control",    label: "Manual Control",   icon: "hand.tap"),
        ]),
        Group(stage: "NEURAL", entries: [
            Entry(type: "prompt_engine", label: "Prompt Engine", icon: "text.bubble"),
            Entry(type: "prompt_bank",   label: "Prompt Bank",   icon: "books.vertical"),
        ]),
        Group(stage: "MACRO", entries: [
            Entry(type: "macro", label: "Macro", icon: "rectangle.stack"),
        ]),
    ]
}

