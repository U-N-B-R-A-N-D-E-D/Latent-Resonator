import SwiftUI

// MARK: - Patch Canvas Types
//
// Shared layout / state primitives used by the native node canvas.
//
// The canvas is a single SwiftUI surface where every node renders its
// own card, and cables are drawn between port positions reported up via
// a `PreferenceKey`. There is no separate "Perform" view — the patch IS
// the performance surface (Max/Envion model).
//
// PERIMETER HONESTY NOTE (2026-07-27):
// The patch IS the performance surface for the 7 node types with dedicated,
// hand-crafted cards: `OscillatorNode`, `LadderFilterNode`, `DelayLineNode`,
// `MixerNode`, `MasterOutputNode`, `FeedbackLoopNode`, `ACEStepInferenceNode`.
//
// `GenericNodeCard` is the editable fallback: every Float/Double parameter
// on any `BaseGraphNode` subtype now renders a compact slider bound through
// `setParam`, so `KoenigSeedNode`, `NoiseNode`, `SilenceNode`, `AudioInputNode`,
// `CombFilterNode`, `TunableResonatorNode`, `BitCrusherNode`, `WaveshaperNode`,
// `PromptEngineNode`, `PromptBankNode`, `AgitationNode`, `PeakNode`,
// `ManualControlNode`, `MetaParameterNode`, `SequencerNode`,
// `SpectralAnalyzerNode`, `SpectralChainNode`, `ReverbNode`,
// `MarkovSequencerNode`, and `GestureRecorderNode` are all reachable from
// their own patch cards. Int/String/Bool parameters remain read-only on the
// generic card; dedicated cards remain the right place for those.
//
// `MacroNode` has its own dedicated `MacroCard` with an expanded/collapsed
// indicator and a double-click gesture that calls
// `NodeGraph.expand(macroId:)`, firing `topologyDidChange` and rebuilding the
// plan. It is no longer in the read-only bucket.
//
// PERFORM mode's `exposedControls` (auto-generated control surface, see
// `PerformLayoutEngine.swift`) can still expose ANY node's parameter —
// including ones that already have a dedicated CANVAS card. CANVAS-card
// coverage and PERFORM-exposure are two separate mechanisms; a node being
// editable on CANVAS does not preclude it from also being exposed in
// performance.

// MARK: - Port location reporting

/// One entry in the port-position preference dictionary.
///
/// Each `NodeCardChrome` reports the screen-coordinate position of every
/// port chip it draws via a `GeometryReader` in the named canvas space.
/// The canvas collects all entries and uses them to draw cables in the cable layer.
struct PatchPortLocation: Equatable {
    let nodeId: UUID
    let portId: String
    let direction: PortDirection
    let signalType: SignalType
    /// Resolved port-chip center in the named `PatchCanvasSpace` coordinate
    /// space. The preference key is Equatable over this point, so updates
    /// fire only when a port actually moves in canvas space (node drag,
    /// card resize, etc.) — not on every pan/zoom frame. Pan and zoom are
    /// view transforms applied to the canvas container, so they do not
    /// change coordinates inside this space.
    let center: CGPoint

    static func == (lhs: PatchPortLocation, rhs: PatchPortLocation) -> Bool {
        lhs.nodeId == rhs.nodeId
            && lhs.portId == rhs.portId
            && lhs.direction == rhs.direction
            && lhs.signalType == rhs.signalType
            && lhs.center == rhs.center
    }
}

// MARK: - Canvas metrics

enum PatchCanvasMetrics {
    /// Minimum canvas zoom. Below this the performer loses context.
    static let minZoom: CGFloat = 0.4
    /// Maximum canvas zoom. Above this the patch becomes too cramped.
    static let maxZoom: CGFloat = 2.5
    /// Visual grid spacing (screen space). Used for both the drawn grid and
    /// snap-to-grid placement. Must match the spacing drawn in
    /// `PatchCanvasView.gridBackground` so the cards land on the visible dots.
    static let gridSize: CGFloat = 32

    /// Minimap overlay size in screen points. Kept small so it covers as little
    /// of the patch as possible while still showing the overall layout.
    static let minimapSize: CGSize = CGSize(width: 200, height: 150)
    /// Padding added around the world bounding box so edge nodes aren't flush.
    static let minimapWorldPadding: CGFloat = 60
    /// Corner radius of the minimap panel background.
    static let minimapCornerRadius: CGFloat = 6
    /// Margin from the bottom-right corner of the canvas window.
    static let minimapMargin: CGFloat = 16
}

struct PatchPortLocationsKey: PreferenceKey {
    static var defaultValue: [PatchPortLocation] = []

    static func reduce(value: inout [PatchPortLocation], nextValue: () -> [PatchPortLocation]) {
        value.append(contentsOf: nextValue())
    }
}

// MARK: - Card frame reporting

/// One card's bounding frame in the named `PatchCanvasSpace` coordinate space.
/// Reported by every `NodeCardChrome` via a background `GeometryReader` so
/// marquee selection and zoom-to-fit can use the real rendered bounds instead
/// of guessing card heights from constants.
struct PatchCardFrame: Equatable {
    let nodeId: UUID
    let frame: CGRect
}

struct PatchCardFramesKey: PreferenceKey {
    static var defaultValue: [PatchCardFrame] = []

    static func reduce(value: inout [PatchCardFrame], nextValue: () -> [PatchCardFrame]) {
        value.append(contentsOf: nextValue())
    }
}

// MARK: - Canvas selection

/// Shared selection state for the canvas. Held as a static reference in
/// `NodeGraphStore` so both `PatchCanvasView` (rendering) and `RootView`
/// (keyboard shortcuts) can read/write the same set without threading a
/// binding through every layer. Also hosts the snap-to-grid toggle and the
/// minimap visibility toggle.
final class CanvasSelectionHandler: ObservableObject {
    @Published var selectedNodeIds: Set<UUID> = []
    @Published var snapToGrid: Bool = false
    @Published var showMinimap: Bool = false
    /// New UUID assigned from `RootView` when the user presses the zoom-to-fit
    /// shortcut. `PatchCanvasView` observes this and calls `zoomToFit(in:)` with
    /// the current viewport geometry without needing to pass a geometry binding
    /// up to the root view.
    @Published var zoomToFitTrigger: UUID = UUID()
}

private struct CanvasSelectionHandlerKey: EnvironmentKey {
    static let defaultValue: CanvasSelectionHandler = CanvasSelectionHandler()
}

extension EnvironmentValues {
    var canvasSelectionHandler: CanvasSelectionHandler {
        get { self[CanvasSelectionHandlerKey.self] }
        set { self[CanvasSelectionHandlerKey.self] = newValue }
    }
}

// MARK: - Port / cable interaction (Envion patch-cord model)

/// Stable identity for one port chip on the canvas.
struct PatchPortRef: Equatable, Hashable {
    let nodeId: UUID
    let portId: String
    let direction: PortDirection
    let signalType: SignalType
}

/// Callbacks threaded from `PatchCanvasView` into `NodeCardChrome` via
/// SwiftUI environment — keeps every card file untouched.
struct PatchPortInteractionHandlers {
    var onPortDragBegan: ((PatchPortRef, CGPoint) -> Void)?
    var onPortDragChanged: ((PatchPortRef, CGPoint) -> Void)?
    var onPortDragEnded: ((PatchPortRef, CGPoint) -> Void)?
    var onPortSecondaryClick: ((PatchPortRef) -> Void)?

    static let noop = PatchPortInteractionHandlers()
}

/// Stable reference wrapper for port interaction handlers. Stored as a
/// `@StateObject` in `PatchCanvasView` and passed through the environment so
/// `NodeCardChrome` bodies are not invalidated by every parent re-render.
final class PortInteractionHandler: ObservableObject {
    var handlers: PatchPortInteractionHandlers = .noop

    /// Source port of an in-progress cable drag. Updated only on drag start/end
    /// so port chips can highlight valid drop targets without a per-frame storm.
    @Published var activeCableDrag: PatchPortRef? = nil
}

private struct PortInteractionHandlerKey: EnvironmentKey {
    static let defaultValue: PortInteractionHandler = PortInteractionHandler()
}

extension EnvironmentValues {
    var portInteractionHandler: PortInteractionHandler {
        get { self[PortInteractionHandlerKey.self] }
        set { self[PortInteractionHandlerKey.self] = newValue }
    }
}

/// In-progress cable being drawn from an output port (Pure Data / Envion style).
/// When a drag starts from an input port that already has a cable, `reroute`
/// holds the existing edge; the edge is hidden during the drag and replaced
/// (or dropped) on release, producing one undo step for the whole operation.
struct PatchCableDragState: Equatable {
    let source: PatchPortRef
    var currentPoint: CGPoint
    var reroute: GraphEdge? = nil
}

// MARK: - Node card drag interaction

/// Callbacks threaded from `PatchCanvasView` into `NodeCardChrome` via
/// SwiftUI environment — keeps the drag handle scoped to the card header
/// so body controls (sliders, faders, knobs) do not fight the card gesture.
struct NodeCardDragHandlers {
    var onNodeDragChanged: ((UUID, CGSize) -> Void)?
    var onNodeDragEnded: ((UUID) -> Void)?
    static let noop = NodeCardDragHandlers()
}

/// Stable reference wrapper for the drag handlers. Stored as a `@StateObject`
/// in `PatchCanvasView` and passed through the environment so that
/// `NodeCardChrome` is not invalidated every time the parent body re-evaluates.
/// The reference identity is stable; the closures it holds update the canvas
/// state through the bindings they captured at initialization.
final class NodeDragHandler: ObservableObject {
    var handlers: NodeCardDragHandlers = .noop
}

private struct NodeDragHandlerKey: EnvironmentKey {
    static let defaultValue: NodeDragHandler = NodeDragHandler()
}

extension EnvironmentValues {
    var nodeDragHandler: NodeDragHandler {
        get { self[NodeDragHandlerKey.self] }
        set { self[NodeDragHandlerKey.self] = newValue }
    }
}

// MARK: - Lock state

/// Max/Envion-style lock toggle on a single canvas.
///
/// - `.unlocked`: nodes draggable; patch cords can be drawn between ports
///                and deleted via secondary-click. Edit affordances ON.
/// - `.locked`:   cables dimmed; structure is read-only so live knobs
///                stay the focus during performance.
enum PatchLockMode: String, CaseIterable {
    case unlocked
    case locked

    var iconName: String {
        switch self {
        case .unlocked: return "lock.open"
        case .locked:   return "lock.fill"
        }
    }

    var label: String {
        switch self {
        case .unlocked: return "UNLOCK"
        case .locked:   return "LOCK"
        }
    }
}

// MARK: - Canvas coordinate space

/// Named coordinate space anchored on `PatchCanvasView`'s own `GeometryReader`
/// content, so port-chip drag gestures (`NodeCardChrome.portDragGesture`)
/// report positions relative to the canvas's own origin instead of `.global`
/// (the whole window). `RootView` stacks a mode-toggle bar above
/// `PatchCanvasView`, so `.global` coordinates are offset by that bar's
/// height — every cable drag/drop landed that far off target, which made
/// cable connection look broken (BUG 3: "cables imposibles de jalar y
/// unir"). `PatchCanvasView.body` declares this space; `NodeCardChrome`
/// reads drag locations against it.
enum PatchCanvasSpace {
    static let name = "patchCanvas"
}

// MARK: - Card metrics

/// One source of truth for the visual rhythm of every node card. Tuning
/// these here propagates to all cards consistently — no per-card magic
/// numbers.
enum NodeCardMetrics {
    static let cornerRadius: CGFloat   = 8
    static let headerHeight: CGFloat   = 22
    static let portChipSize: CGFloat   = 11
    static let portColumnWidth: CGFloat = 16
    static let bodyPaddingH: CGFloat   = 10
    static let bodyPaddingV: CGFloat   = 8
    static let knobSize: CGFloat       = 44
    /// Minimum card width that fits the widest standard dedicated-card body.
    /// Widest row: 4 knobs × 44 pt + 3 × 8 pt spacing = 200 pt.
    /// Body horizontal padding: 2 × 10 pt = 20 pt.
    /// Port rails: 2 × 16 pt = 32 pt.
    /// Required width = 200 + 20 + 32 = 252 pt.
    static let minWidth: CGFloat       = 252
    static let footerHeight: CGFloat   = 14
    static let paramSliderHeight: CGFloat = 12
    static let paramValueMaxWidth: CGFloat  = 40
    /// Conservative fallback height for operations that need a card bbox
    /// before the real rendered frames have been reported (e.g., zoom-to-fit
    /// on the very first frame). Replaced by actual frames once layout runs.
    static let estimatedHeight: CGFloat = 80
}
