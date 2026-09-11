import Foundation
import SwiftUI
import AVFoundation
import CoreAudio
import Combine
import Accelerate

// MARK: - Neural Engine (v2.0 Graph-Native Architecture)
//
// Manages the NodeGraph which is the source of truth for all audio processing.
// Each MacroNode in the graph represents a processing lane (v1.x concept migrated).
//
// Architecture (v2.0 graph-native):
//
//   +--------------------------------------------------------+
//   |  NodeGraph (Source of Truth)                            |
//   |  ┌─────────────┐  ┌─────────────┐     ┌─────────────┐   |
//   |  │  MacroNode  │  │  MacroNode  │ ... │  MacroNode  │   |
//   |  │ (was Lane)  │  │ (was Lane)  │     │ (was Lane)  │   |
//   |  │ ┌─────────┐ │  │ ┌─────────┐ │     │ ┌─────────┐ │   |
//   |  │ │Internal │ │  │ │Internal │ │     │ │Internal │ │   |
//   |  │ │ Graph   │ │  │ │ Graph   │ │     │ │ Graph   │ │   |
//   |  │ └────┬────┘ │  │ └────┬────┘ │     │ └────┬────┘ │   |
//   |  │   OUT│      │  │   OUT│      │     │   OUT│      │   |
//   |  └──────┼──────┘  └──────┼──────┘     └──────┼──────┘   |
//   |         │                │                      │        |
//   |         +--------+-------+----------------------+        |
//   |                  v                                       |
//   |           MixerNode (masterMixerNode)                   |
//   |                  │                                       |
//   |           MasterOutputNode -> mainMixerNode              |
//   +------------------│---------------------------------------+
//                      │
//            GraphAudioEngine (v2.0 pull-render single-source-node)
//
// White paper reference:
//   §3.3 -- Recursive formula per macro
//   §6.1 -- Black Box Resonator (each macro is one resonator)
//   §1.2 -- The Lucier Chamber (delay per macro)
//
// v2.0 Migration Notes:
//   - ResonatorLane replaced by MacroNode (encapsulated subgraph)
//   - laneSlots pre-allocation removed (dynamic graph-based)
//   - All lane operations now use MacroNode operations via NodeGraph
//   - Scene persistence uses GraphSnapshot (node parameters)

final class NeuralEngine: ObservableObject {

    // MARK: - v2.0 Node Graph (Source of Truth)

    /// The complete signal processing graph. All nodes, edges, and parameters live here.
    /// This is the single source of truth for the entire audio system.
    let nodeGraph = NodeGraph()

    // MARK: - Computed Lane Access (v1.x Compatibility)

    /// All active macros (formerly "lanes"). UI observes this for the mixer layout.
    /// Computed from nodeGraph - always reflects current graph state.
    var macroNodes: [MacroNode] {
        nodeGraph.nodes.values.compactMap { $0 as? MacroNode }
    }

    /// v1.x compatibility: `lanes` now returns MacroNodes as they serve the same purpose.
    @Published var lanes: [MacroNode] = []

    /// All sequencer nodes in the graph.
    var sequencerNodes: [SequencerNode] {
        nodeGraph.nodes.values.compactMap { $0 as? SequencerNode }
    }

    /// All feedback loop nodes in the graph.
    var feedbackLoopNodes: [FeedbackLoopNode] {
        nodeGraph.nodes.values.compactMap { $0 as? FeedbackLoopNode }
    }

    /// All meta-parameter (envelope) nodes in the graph.
    /// (P5 Slice 1 — envelope playhead publisher removed; this is kept
    /// as a graph-introspection helper for future UI/audit paths.)
    var metaParameterNodes: [MetaParameterNode] {
        nodeGraph.nodes.values.compactMap { $0 as? MetaParameterNode }
    }

    // MARK: - Global State

    @Published var isProcessing: Bool = false

    /// False for 3s after start so Abort button is disabled (avoids accidental tap killing first inference).
    @Published var canAbort: Bool = true

    /// A.7/A.8: Result of the most recent `verifyAudioPipeline()` run (populated
    /// on every `startProcessing()`, after any auto-restore). UI-facing
    /// counterpart to the console-only "PIPELINE UNHEALTHY" diagnostic --
    /// drives the SILENT badge in `RootView`/`PerformanceMotherbaseView` so a
    /// performer can see *why* nothing is audible instead of a fake "READY".
    @Published private(set) var lastPipelineStatus = PipelineStatus()

    /// Ignore stop for this long after start (first inference can take several seconds).
    private var lastStartTime: Date?
    private let startDebounceInterval: TimeInterval = 3.0

    /// True when processing was started in Perform mode and user briefly switched to Setup.
    /// Used to avoid stopping when returning to Perform (no warning, keep playing).
    var processingStartedInPerformMode: Bool = false

    // MARK: - ACE-Step Bridge (Shared)

    /// HTTP bridge to the Python ACE-Step inference server.
    let aceBridge = ACEStepBridge()

    // MARK: - Bridge Process Manager (All-in-One Lifecycle)

    /// Manages the Python bridge server process lifecycle.
    let bridgeProcess = BridgeProcessManager()

    // MARK: - Master Recording (Whitepaper §5)

    /// Master bus recorder -- captures mixed output of all macros.
    let masterRecorder = AudioRecorder()
    @Published var isMasterRecording: Bool = false

    // MARK: - Performance / Motherbase

    /// Scene bank owned by SceneManager; exposed for UI binding and persistence.
    var sceneBank: SceneBank {
        get { sceneManager.sceneBank }
        set { sceneManager.sceneBank = newValue }
    }

    /// Manages scene bank and scene operations (apply, capture, crossfade).
    let sceneManager = SceneManager()
    @Published var pLockEditingStepIndex: Int? = nil
    /// Shift+click selection for batch operations. Cleared when focus macro changes.
    @Published var selectedStepIndices: Set<Int> = []

    /// v2.0: Focus on a specific MacroNode by ID.
    @Published var focusMacroId: UUID?

    /// v2.0: Focus macro (first macro whose id matches focusMacroId, or first macro).
    var focusMacro: MacroNode? {
        if let id = focusMacroId, let macro = macroNodes.first(where: { $0.id == id }) {
            return macro
        }
        return macroNodes.first
    }

    /// v1.x compatibility: focusLane returns the focus macro (MacroNode is the v2.0 lane equivalent).
    var focusLane: MacroNode? { focusMacro }

    /// v1.x compatibility: focusLaneId returns the focus macro ID.
    var focusLaneId: UUID? { focusMacroId }

    /// Step grid access for the focused macro (Focus Lane UX).
    /// v2.0: Step grids are stored in SequencerNodes within the MacroNode's internal graph.
    var focusStepGrid: StepGrid? {
        guard let macro = focusMacro else { return nil }
        // Find the first sequencer node in the macro's internal graph
        return macro.internalGraph.nodes.values
            .compactMap { $0 as? SequencerNode }
            .first?.stepGrid
    }

    /// Access to the focused sequencer node for step operations.
    /// v2.0: SequencerNode is inside the focus macro's internal graph.
    var focusSequencerNode: SequencerNode? {
        guard let macro = focusMacro else { return nil }
        return macro.internalGraph.nodes.values
            .compactMap { $0 as? SequencerNode }
            .first
    }
    /// Total iteration count across all feedback loops (for step advance).
    var globalCycleCount: Int {
        feedbackLoopNodes.reduce(0) { $0 + $1.iterationCount }
    }

    /// Crossfader position 0...1 (A = 0, B = 1). Blends between sceneAIndex and sceneBIndex.
    @Published var crossfaderPosition: Float = 0
    @Published var crossfaderSceneAIndex: Int = 0
    @Published var crossfaderSceneBIndex: Int = 1

    // MARK: - Audio Engine
//
    // P5 Slice 1 — Envelope Playhead: REMOVED.
    // The previous `@Published var envelopePlayhead` + 60Hz
    // `updateEnvelopePlayhead()` lifted a MetaParameterNode's `phase`
    // into a published Double solely to drive `EnvelopeCurveView`'s
    // playhead. The value was never bound — only its change triggered
    // `PerformanceMotherbaseView` (1323 lines) re-evaluation at 60Hz.
    // `EnvelopeCurveView` now wraps its own body in
    // `TimelineView(.periodic(by: 1/60))` reading `node.phase` directly,
    // confining the re-render to the leaf view. Same pattern as
    // `MacroVUMeter` at 30Hz.

    private let audioEngine = AVAudioEngine()
    private let masterMixerNode = AVAudioMixerNode()

    // MARK: - Audio Input (Shared Ring Buffer for .audioInput Excitation)

    /// Shared ring buffer fed by the hardware input tap. Macros configured
    /// as .audioInput read from this buffer instead of their oscillator.
    let audioInputBuffer = CircularAudioBuffer(capacity: LRConstants.audioInputBufferCapacity)
    /// Whether an input tap is currently installed on the audio engine.
    private var inputTapInstalled: Bool = false

    // MARK: - Output Device Management
    //
    // Professional audio apps (Logic Pro, Ableton, Pro Tools) set the output
    // device's sample rate to match their session rate before starting the
    // audio engine. This eliminates format-conversion ambiguity and ensures
    // the CoreAudio HAL IOProc activates reliably -- especially on USB
    // interfaces like the MOTU M2 at non-standard rates (192kHz).

    /// CoreAudio ID of the system's default output device.
    private var outputDeviceID: AudioDeviceID = 0

    /// Original device sample rate, saved so we can restore it on exit.
    private var originalDeviceSampleRate: Float64?

    // MARK: - MIDI Input (§6 -- Controller Mapping)

    /// CoreMIDI input manager -- routes CC messages through ParameterRouter
    /// into the focus macro's parameters and engine-global controls.
    let midiInput = MIDIInputManager()
    var oscInput = OSCInputManager()

    // MARK: - Processing Format

    private var processingFormat: AVAudioFormat?

    private var effectiveFormat: AVAudioFormat {
        if let fmt = processingFormat { return fmt }
        guard let fmt = AVAudioFormat(
            standardFormatWithSampleRate: LRConstants.sampleRate,
            channels: AVAudioChannelCount(LRConstants.channelCount)
        ) else {
            fatalError("NeuralEngine: standardFormat 48kHz/2ch failed")
        }
        return fmt
    }

    // MARK: - v2.0 Graph Audio Engine
    //
    // Pull-render graph engine: a single AVAudioSourceNode walks the
    // NodeGraph in topological order each render block. Topology changes
    // are atomic plan swaps — no AVAudioEngine restart, no clicks.

    /// Owns the root AVAudioSourceNode and renders the entire graph.
    private var graphAudioEngine: GraphAudioEngine?

    /// 60 Hz control-graph evaluator (LFO / meta-parameter CV routing).
    private let controlGraphEvaluator = ControlGraphEvaluator()

    // MARK: - v2.0 Sequencer Engine

    /// Owns step timer and advance logic for all SequencerNodes in the graph.
    /// v2.0: Graph-native, no lane dependencies.
    private lazy var sequencerEngine: SequencerEngine = SequencerEngine(
        nodeGraph: nodeGraph,
        isProcessingGetter: { [weak self] in self?.isProcessing ?? false }
    )

    // MARK: - Lifecycle

    private var cancellables = Set<AnyCancellable>()

    /// Forwards each live `FeedbackLoopNode.objectWillChange` to
    /// `NeuralEngine.objectWillChange`. Needed because `NodeGraph.nodes` is
    /// `@Published` on the *dictionary*, not on the objects inside it -- so
    /// a node mutating its own `iterationCount`/`lastOutcome` would
    /// otherwise never cause RootView / PerformanceMotherbaseView (which
    /// observe `engine`, not the node directly) to refresh. Rebuilt by
    /// `observeFeedbackLoopNodes()` whenever the graph's node set changes.
    private var feedbackLoopObservers = Set<AnyCancellable>()

    /// (Re)subscribes to every `FeedbackLoopNode` currently in the graph so
    /// its neural telemetry (iterationCount, lastOutcome, inferenceStartedAt)
    /// reliably drives the status strip in RootView/PerformanceMotherbaseView.
    private func observeFeedbackLoopNodes() {
        feedbackLoopObservers.removeAll()
        for node in feedbackLoopNodes {
            node.objectWillChange
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.objectWillChange.send() }
                .store(in: &feedbackLoopObservers)
        }
    }

    // MARK: - MIDI Routing Setup
    //
    // P3.13 Slice 4: the parameter-routing implementation moved to the
    // stateless `ParameterRouterController` helper (see
    // `Graph/ParameterRouterController.swift`). These instance methods are
    // now thin delegators that pass `focusMacro`, `crossfaderPosition`,
    // `nodeGraph`, the `objectWillChange.send()` side effect (as `notify`),
    // and the `updateMacroMixerState` side effect (as `mixerStateUpdater`);
    // callers keep the same private signatures.

    /// Shared routing logic for both MIDI CC and OSC input.
    private func applyParameter(_ param: ControlParameter, value: Float) {
        // P3.13 Slice 4: the .crossfader case stays in NeuralEngine — it
        // mutates engine state (`crossfaderPosition`) and calls
        // `applyCrossfader()` which routes through `sceneManager` (scene
        // crossfade). Extracting it would re-couple the stateless helper to
        // scene state, violating the Slice 4 "do not touch scene" constraint.
        // See TODO(P3.13 Slice 5) in ParameterRouterController.swift.
        switch param {
        case .crossfader:
            crossfaderPosition = value
            applyCrossfader()
            return
        default:
            ParameterRouterController.applyParameter(
                param,
                value: value,
                focusMacro: focusMacro,
                crossfaderPosition: crossfaderPosition,
                nodeGraph: nodeGraph,
                notify: { self.objectWillChange.send() },
                mixerStateUpdater: { self.updateMacroMixerState() }
            )
        }
    }

    /// Fallback routing for MIDI CC / OSC when there's no focus macro to
    /// receive the change (flat/legacy topologies -- see `applyParameter`).
    /// P3.13 Slice 4: implementation moved to
    /// `ParameterRouterController.applyParameterToGraphNodes`.
    private func applyParameterToGraphNodes(_ param: ControlParameter, value: Float) {
        ParameterRouterController.applyParameterToGraphNodes(param, value: value, nodeGraph: nodeGraph)
    }

    /// Applies `value` to `key` on every node of type `T` in the main graph.
    /// P3.13 Slice 4: implementation moved to
    /// `ParameterRouterController.setParameterOnNodes`.
    private func setParameterOnNodes<T: GraphNode>(ofType type: T.Type, key: String, value: Float) {
        ParameterRouterController.setParameterOnNodes(ofType: type, key: key, value: value, nodeGraph: nodeGraph)
    }

    /// Connect MIDI CC and OSC input to the focus macro and engine-global parameters.
    //
    // P3.13 Slice 4: setupMIDIRouting STAYS in NeuralEngine. It registers
    // closures on `midiInput.onParameterChange` and `oscInput.onParameterChange`
    // that capture `[weak self]` and call `self?.applyParameter(...)`. Too
    // coupled to the engine's MIDI/OSC input manager instances (and through
    // them to CoreMIDI / NWListener system APIs) to extract cleanly into a
    // stateless helper without re-introducing a weak-engine reference —
    // exactly the coupling the Slice 4 extraction is meant to break.
    // See TODO(P3.13 Slice 5) in ParameterRouterController.swift.
    private func setupMIDIRouting() {
        midiInput.onParameterChange = { [weak self] param, value in
            self?.applyParameter(param, value: value)
        }
        midiInput.start()

        oscInput.onParameterChange = { [weak self] param, value in
            self?.applyParameter(param, value: value)
        }
        if oscInput.isEnabled { oscInput.start() }
    }

    init() {
        NSLog("[LR-FATAL] NeuralEngine init STARTING")
        
        configureOutputDevice()   // Set device to 48kHz BEFORE building graph
        setupProcessingFormat()
        setupMasterMixer()

        // v2.0: Initialize the pull-render graph audio engine. Its root
        // AVAudioSourceNode is attached and wired into the master mixer
        // chain here; afterwards we never touch AVAudioEngine connect/detach
        // for graph-internal nodes — topology changes are plan swaps.
        let engine = GraphAudioEngine(
            format: effectiveFormat,
            frameCapacity: LRConstants.bufferSize
        )
        audioEngine.attach(engine.rootSourceNode)
        audioEngine.connect(engine.rootSourceNode, to: masterMixerNode, format: effectiveFormat)
        graphAudioEngine = engine

        // Bridge injection: nodeGraph.aceBridge must be set before any node is
        // created (deserialize / addNode / NodeFactory all read it) so
        // FeedbackLoopNode and ACEStepInferenceNode instances are wired to the
        // real bridge from the moment they're constructed.
        nodeGraph.aceBridge = aceBridge

        // Audio input ring injection: same timing as the bridge so that
        // AudioInputNode instances receive the shared buffer at construction.
        nodeGraph.audioInputBuffer = audioInputBuffer

        // So terminateServer() can see when an /infer request is in flight
        // and wait for it instead of killing the bridge mid-request.
        bridgeProcess.aceBridge = aceBridge

        // v2.0: Load saved graph or bootstrap with factory topology
        NSLog("[LR-FATAL] About to call loadGraphOrBootstrap")
        loadGraphOrBootstrap()
        NSLog("[LR-FATAL] NeuralEngine init COMPLETE - nodes: %d", nodeGraph.nodes.count)

        // Build the initial ExecutionPlan from the loaded graph and adopt it.
        // The topologyDidChange subscription is configured below, so this
        // first build needs to happen explicitly.
        NSLog("[LR-FATAL] Rebuilding audio graph after bootstrap...")
        rebuildAudioGraphIfNeeded()
        NSLog("[LR-FATAL] Audio graph rebuilt. Plan steps: %d", graphAudioEngine?.currentPlanStepCount ?? 0)

        // Also update lanes array immediately so UI has data
        updateLanesArray()
        observeFeedbackLoopNodes()
        observeMacroInternalGraphs()

        // v2.0: Subscribe to node graph changes for lane array updates
        nodeGraph.$nodes
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateLanesArray()
                // Re-subscribe: FeedbackLoopNode instances can be replaced
                // wholesale by a graph load, and `@Published var nodes` only
                // fires when the dictionary itself changes -- not when a
                // property on one of the node objects it holds changes.
                self?.observeFeedbackLoopNodes()
                // Engineer P2 #8: re-subscribe to each macro's
                // internalGraph.topologyDidChange too — macros can be
                // added/removed by a graph load, and the internal
                // subscription set must track the live macro set.
                self?.observeMacroInternalGraphs()
            }
            .store(in: &cancellables)

        // Performance state (Motherbase) -- load saved state or initialize defaults
        if let saved = PerformanceStateStore.load() {
            var bank = saved.sceneBank
            bank.ensureCapacity()
            sceneManager.sceneBank = bank
            // v2.0: Restore step grids to sequencer nodes if available
            restoreStepGrids(from: saved.stepGrids)
            crossfaderSceneAIndex = saved.crossfaderSceneAIndex
            crossfaderSceneBIndex = saved.crossfaderSceneBIndex
        } else {
            var bank = sceneManager.sceneBank
            bank.ensureCapacity()
            sceneManager.sceneBank = bank
        }

        // Wire the scene manager to the active step's p-locks so locked
        // parameters are skipped during scene recall and crossfade.
        sceneManager.lockedParameterFilter = { [weak self] nodeId, paramId in
            guard let self = self else { return false }
            return self.lockedParameterKeysForActiveStep().contains(ParameterLockKey(nodeId: nodeId, paramId: paramId))
        }

        // Launch the Python ACE-Step bridge server process.
        bridgeProcess.launchServer()

        // Start MIDI input -- routes CC to focus macro parameters
        setupMIDIRouting()

        // Defer health polling until bridge process reaches .running state.
        // This prevents "Connection refused" spam during the ~35s model loading window.
        bridgeProcess.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newState in
                guard let self = self else { return }
                self.objectWillChange.send()

                if newState == .running {
                    self.aceBridge.startHealthPolling()
                }
            }
            .store(in: &cancellables)

        // Forward aceBridge changes so Settings > Config device indicator updates
        aceBridge.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // Forward midiInput changes so Settings > MIDI activity LED updates
        midiInput.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // Forward oscInput changes so Settings > OSC Monitor updates
        oscInput.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // Forward sceneManager changes so sceneBank observers refresh
        sceneManager.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // Forward nodeGraph changes for global UI refresh
        nodeGraph.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // v2.0: Subscribe to topology changes for audio graph rebuilds.
        // Engineer P2 #7: hop to the main queue to match the sibling
        // `nodeGraph.$nodes` subscription pattern and avoid audio-thread
        // re-entry into `rebuildAudioGraphIfNeeded` (which allocates
        // BufferPools and adopts a plan on the running engine).
        nodeGraph.topologyDidChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.rebuildAudioGraphIfNeeded()
            }
            .store(in: &cancellables)

        // v2.0: Parameter changes propagate automatically — DSP nodes read
        // their parameters from the @Published store on the audio thread, so
        // a setParam(...) on the main thread becomes audible at the very
        // next render block. No mapper round-trip needed.

        // Initial lanes array sync
        updateLanesArray()

        controlGraphEvaluator.nodeGraph = nodeGraph
        controlGraphEvaluator.start()

        // P5 Slice 1 — `onEvaluationComplete` wiring REMOVED. The
        // evaluator still walks every MetaParameterNode and advances
        // its `phase` at 60Hz; `EnvelopeCurveView` now polls
        // `node.phase` directly inside its own TimelineView, so no
        // engine-side publisher is needed.
    }

    deinit {
        controlGraphEvaluator.stop()
        sequencerEngine.cancelStepTimer()
        savePerformanceState()
        midiInput.stop()
        oscInput.saveSettings()
        oscInput.stop()
        aceBridge.stopHealthPolling()
        bridgeProcess.terminateServer()
        if isProcessing {
            audioEngine.stop()
        }
        restoreDeviceSampleRate()
    }

    // MARK: - v2.0 Lanes Array Synchronization

    /// Updates the published `lanes` array from the current macroNodes.
    /// This maintains v1.x UI compatibility while using v2.0 graph-native storage.
    private func updateLanesArray() {
        lanes = macroNodes
    }

    // MARK: - Macro Internal Graph Topology Observation
    //
    // Engineer P2 #8: a collapsed MacroNode renders through its own
    // `internalPlan` (see `rebuildAudioGraphIfNeeded`). The macro's
    // `internalGraph` is a full `NodeGraph` with its own
    // `topologyDidChange` subject; without subscribing to it, a mutation
    // inside a collapsed macro (e.g. a node added/removed by a future
    // PATCH edit on the macro's subgraph) would go stale — the audio
    // plan would never rebuild until the macro was expanded or the
    // outer graph changed. Rebuilt by `observeMacroInternalGraphs()`
    // whenever the outer graph's node set changes (same lifecycle as
    // `observeFeedbackLoopNodes()`).
    private var macroInternalGraphObservers = Set<AnyCancellable>()

    /// (Re)subscribes to every macro's `internalGraph.topologyDidChange`
    /// so a collapsed macro's internal mutation triggers an audio plan
    /// rebuild. The rebuild is the same `rebuildAudioGraphIfNeeded()`
    /// path the outer `nodeGraph.topologyDidChange` uses — the plan
    /// builder walks both the outer graph and every macro's
    /// `internalGraph`, so a single rebuild covers both layers.
    private func observeMacroInternalGraphs() {
        macroInternalGraphObservers.removeAll()
        for macro in macroNodes {
            macro.internalGraph.topologyDidChange
                .receive(on: DispatchQueue.main)
                .sink { [weak self] in
                    self?.rebuildAudioGraphIfNeeded()
                }
                .store(in: &macroInternalGraphObservers)
        }
    }

    // MARK: - Audio Graph Rebuild

    /// v2.0: Build a new ExecutionPlan from the NodeGraph and atomically
    /// hand it to the running GraphAudioEngine. No AVAudioEngine restart —
    /// the audio thread picks up the new plan at its next render block.
    private func rebuildAudioGraphIfNeeded() {
        // TODO(future): P3.13 Slice 5 intentionally left this inline. It
        // orchestrates the `GraphAudioEngine` rebuild — calls
        // `ExecutionPlan.build(from:nodeGraph:frameCapacity:)` and
        // `engine.adopt(plan)`, then walks every macro's
        // `rebuildInternalPlanIfNeeded`. Couples to `graphAudioEngine`
        // ownership (a `GraphAudioEngine` instance that owns the root
        // `AVAudioSourceNode`). The pure plan-build step lives in
        // `ExecutionPlan.build` already; the orchestration here is the
        // system-coupled glue (allocates BufferPools, adopts the plan on
        // the running engine) and is not safely testable without the
        // engine instance.
        guard let engine = graphAudioEngine else {
            print(">> Neural Engine: rebuildAudioGraphIfNeeded skipped — graphAudioEngine is nil (init order bug?)")
            return
        }

        let plan = ExecutionPlan.build(
            from: nodeGraph,
            frameCapacity: LRConstants.bufferSize
        )

        engine.adopt(plan)

        // Fix 4a: rebuild every macro's cached internal ExecutionPlan so
        // collapsed macros render their internalGraph through their own
        // pull-render path. Main-thread only — allocates BufferPools.
        for macro in macroNodes {
            macro.rebuildInternalPlanIfNeeded(frameCapacity: LRConstants.bufferSize)
        }

        if let plan = plan {
            print(">> Neural Engine: Audio plan adopted: \(plan.steps.count) steps from \(nodeGraph.nodes.count) graph nodes")
        } else {
            print(">> Neural Engine: Audio plan empty — no DSP-participating nodes (graph will render silence)")
        }
    }

    // MARK: - Performance State Persistence

    /// Save the current performance state (scenes, step grids per macro, crossfader) to disk.
    func savePerformanceState() {
        // v2.0: Collect step grids from all sequencer nodes in all macros
        var stepGrids: [StepGrid] = []
        for macro in macroNodes {
            let sequencers = macro.internalGraph.nodes.values.compactMap { $0 as? SequencerNode }
            for sequencer in sequencers {
                stepGrids.append(sequencer.stepGrid)
            }
        }

        let snapshot = PerformanceStateSnapshot(
            sceneBank: sceneBank,
            stepGrids: stepGrids,
            crossfaderSceneAIndex: crossfaderSceneAIndex,
            crossfaderSceneBIndex: crossfaderSceneBIndex
        )
        do {
            try PerformanceStateStore.save(snapshot)
            print(">> Performance state saved")
        } catch {
            print(">> Performance state save failed: \(error.localizedDescription)")
        }
    }

    /// v2.0: Restore step grids to sequencer nodes.
    private func restoreStepGrids(from grids: [StepGrid]) {
        var gridIndex = 0
        for macro in macroNodes {
            let sequencers = macro.internalGraph.nodes.values.compactMap { $0 as? SequencerNode }
            for sequencer in sequencers {
                if gridIndex < grids.count {
                    sequencer.stepGrid = grids[gridIndex]
                    gridIndex += 1
                }
            }
        }
    }

    /// Cleanly shut down the entire engine -- audio, bridge, everything.
    func shutdownAll() {
        savePerformanceState()
        midiInput.stop()
        stopProcessing()
        aceBridge.stopHealthPolling()
        bridgeProcess.terminateServer()
        restoreDeviceSampleRate()
    }

    // MARK: - Setup

    private func setupProcessingFormat() {
        processingFormat = AVAudioFormat(
            standardFormatWithSampleRate: LRConstants.sampleRate,
            channels: AVAudioChannelCount(LRConstants.channelCount)
        )
    }

    /// Negotiate the output device's sample rate to match our processing format.
    //
    // TODO(future): P3.13 Slice 5 intentionally left this inline. It calls
    // `AudioObjectGetPropertyData` / `AudioObjectSetPropertyData` on the
    // CoreAudio HAL — pure system-API coupling, not safely testable
    // without an actual output device. Extraction would require injecting
    // a device-IO abstraction, which is out of scope for this slice
    // (pure-logic extraction only; do not destabilize the audio engine).
    private func configureOutputDevice() {
        // 1. Get default output device
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let getStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &outputDeviceID
        )
        guard getStatus == noErr else {
            print(">> Neural Engine: Cannot read default output device (err \(getStatus))")
            return
        }

        // 2. Read the device's current nominal sample rate
        var currentRate: Float64 = 0
        var rateSize = UInt32(MemoryLayout<Float64>.size)
        var rateAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(
            outputDeviceID, &rateAddress, 0, nil, &rateSize, &currentRate
        )

        let targetRate = LRConstants.sampleRate

        if currentRate == targetRate {
            print("[NeuralEngine] Output device already at \(Int(targetRate))Hz — no conversion needed")
            return
        }

        // 3. Save original rate to restore on exit
        originalDeviceSampleRate = currentRate

        // 4. Set the device to our processing rate
        var newRate = targetRate
        let setStatus = AudioObjectSetPropertyData(
            outputDeviceID, &rateAddress, 0, nil,
            UInt32(MemoryLayout<Float64>.size), &newRate
        )

        if setStatus == noErr {
            print("[NeuralEngine] Hardware \(Int(currentRate))Hz → internal \(Int(targetRate))Hz (LRConstants.sampleRate) — DSP tuned for 48k, resampling handled by AVAudioEngine")
        } else {
            print("[NeuralEngine] Failed to set device rate (err \(setStatus))")
            originalDeviceSampleRate = nil
        }
    }

    /// Restore the output device's original sample rate.
    //
    // TODO(future): P3.13 Slice 5 intentionally left this inline. Same
    // rationale as `configureOutputDevice` — calls
    // `AudioObjectSetPropertyData` on the CoreAudio HAL. Pure system-API
    // coupling, not testable without an actual output device.
    private func restoreDeviceSampleRate() {
        guard let originalRate = originalDeviceSampleRate,
              outputDeviceID != 0 else { return }

        var rate = originalRate
        var rateAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectSetPropertyData(
            outputDeviceID, &rateAddress, 0, nil,
            UInt32(MemoryLayout<Float64>.size), &rate
        )
        if status == noErr {
            print("[NeuralEngine] Device rate restored to \(Int(originalRate))Hz")
        }
        originalDeviceSampleRate = nil
    }

    private func setupMasterMixer() {
        // TODO(future): P3.13 Slice 5 intentionally left this inline. It
        // mutates the `AVAudioEngine` (attach + connect) and installs a tap
        // on `masterMixerNode` — real-time audio-thread invariants. Not
        // safely testable without an actual `AVAudioEngine` instance and
        // a live audio session. Extraction would require an
        // audio-engine abstraction, out of scope for this pure-logic slice.
        audioEngine.attach(masterMixerNode)
        audioEngine.connect(masterMixerNode, to: audioEngine.mainMixerNode, format: effectiveFormat)

        // CRITICAL: Verify output chain is complete
        // The mainMixerNode is implicitly connected to outputNode by AVAudioEngine
        // when the engine starts. We verify this chain at runtime.
        print("[AudioEngine] Master mixer chain: masterMixerNode → mainMixerNode → outputNode")
        print("[AudioEngine] Output node present: true (AVAudioOutputNode always exists)")

        // Tap on master for recording
        masterMixerNode.installTap(
            onBus: 0,
            bufferSize: AVAudioFrameCount(LRConstants.bufferSize),
            format: effectiveFormat
        ) { [weak self] buffer, _ in
            self?.processMasterTap(buffer)
        }
    }

    // MARK: - Audio Pipeline Verification (A.7)
    //
    // P3.13 Slice 5: the pure, graph-only half of this method (counting
    // DSP-participating nodes, sources, master outputs, source activity,
    // master volume) was extracted verbatim to
    // `AudioPipelineValidator.auditGraph(nodeGraph:)` (see
    // `Graph/AudioPipelineValidator.swift`). What stays inline here is the
    // system-API-coupled half: `audioEngine.isRunning`,
    // `graphAudioEngine.currentPlanStepCount`, and the `effectiveFormat`
    // print — none of which can be exercised without instantiating
    // NeuralEngine (which mutates the system output device sample rate and
    // spawns the Python bridge). See `TODO(future)` markers below for the
    // other lifecycle methods that were intentionally left inline.

    /// Comprehensive verification of the audio signal chain.
    /// Call this after graph changes or when debugging audio issues.
    func verifyAudioPipeline() -> PipelineStatus {
        print("=== AUDIO PIPELINE VERIFICATION ===")

        var status = PipelineStatus()

        // 1. Engine state — system-coupled, stays inline.
        status.engineRunning = audioEngine.isRunning
        print("[Pipeline] Engine running: \(status.engineRunning)")

        // 2-4. Graph composition, source verification, master output —
        // pure graph walk, delegated to AudioPipelineValidator.
        let audit = AudioPipelineValidator.auditGraph(nodeGraph: nodeGraph)
        status.audioNodeCount = audit.audioNodeCount
        status.sourceNodeCount = audit.sourceNodeCount
        status.masterOutputCount = audit.masterOutputCount
        status.sourceActive = audit.sourceActive
        status.masterVolume = audit.masterVolume

        print("[Pipeline] DSP-participating nodes: \(audit.audioNodeCount)")
        print("[Pipeline] Source nodes: \(audit.sourceNodeCount)")
        print("[Pipeline] Master outputs: \(audit.masterOutputCount)")

        // 5. Engine status — GraphAudioEngine-coupled, stays inline.
        if let engine = graphAudioEngine {
            status.attachedNodeCount = engine.currentPlanStepCount
            print("[Pipeline] Plan steps active: \(engine.currentPlanStepCount)")
        }

        // 6. System volume check (informational) — AVAudioFormat-coupled, stays inline.
        print("[Pipeline] Format: \(effectiveFormat.sampleRate)Hz, \(effectiveFormat.channelCount)ch")

        print("===================================")

        return status
    }

    /// A.8: Lifts every source node's amplitude back to
    /// `LRConstants.autoRestoreAmplitude` wherever it's at/near zero. Called
    /// exactly once from `startProcessing()` when `verifyAudioPipeline()`
    /// reports sources exist but none are active -- never from `render()`
    /// or any continuous/timed path, so a performer fading a source out
    /// live is never overridden.
    //
    // P3.13 Slice 5: implementation moved verbatim to
    // `AudioPipelineValidator.restoreSilentSources(nodeGraph:notify:)`.
    // This instance method is now a thin delegator; the `notify` closure
    // is passed for API symmetry with the other P3.13 controllers but is
    // intentionally unused by the helper (the original did not call
    // `objectWillChange.send()`; the caller re-runs `verifyAudioPipeline()`
    // immediately after, which writes `lastPipelineStatus` and refreshes
    // the UI through that path). See TODO(future) in
    // `AudioPipelineValidator.restoreSilentSources` for the rationale.
    private func restoreSilentSources() {
        AudioPipelineValidator.restoreSilentSources(
            nodeGraph: nodeGraph,
            notify: { self.objectWillChange.send() }
        )
    }

    struct PipelineStatus {
        var engineRunning: Bool = false
        var audioNodeCount: Int = 0
        var sourceNodeCount: Int = 0
        var masterOutputCount: Int = 0
        var attachedNodeCount: Int = 0
        var sourceActive: Bool = false
        var masterVolume: Float = 0.0

        var isHealthy: Bool {
            engineRunning &&
            audioNodeCount > 0 &&
            sourceNodeCount > 0 &&
            masterOutputCount == 1 &&
            attachedNodeCount > 0 &&
            sourceActive &&
            masterVolume > 0.01
        }

        /// Short, human-readable reason `isHealthy == false`, prioritized so
        /// the most actionable problem surfaces first. `nil` when healthy or
        /// when the engine simply hasn't been started -- callers should gate
        /// display on `engineRunning` themselves (a not-yet-started engine
        /// isn't "silent," it's just off).
        var silenceReason: String? {
            guard engineRunning else { return nil }
            if sourceNodeCount == 0 { return "no source" }
            if !sourceActive { return "amp=0" }
            if masterOutputCount == 0 { return "no master" }
            if masterVolume <= 0.01 { return "master=0" }
            if attachedNodeCount == 0 { return "plan empty" }
            return nil
        }
    }

    // MARK: - Macro Management (v2.0, was Lane Management)

    /// Add a new macro from a preset. Returns the new macro.
    /// v2.0: Creates a MacroNode with internal graph built from preset.
    @discardableResult
    func addMacro(preset: LanePreset) -> MacroNode {
        assert(Thread.isMainThread, "macros must be mutated on main thread")
        guard macroNodes.count < LRConstants.maxMacroNodes else {
            print(">> Neural Engine: Max macros (\(LRConstants.maxMacroNodes)) reached")
            return macroNodes.last ?? createFallbackMacro()
        }

        // Create macro from preset using MacroNode factory
        let macro = MacroNode.fromPreset(preset: preset)

        // Add to node graph
        nodeGraph.nodes[macro.id] = macro
        nodeGraph.objectWillChange.send()
        nodeGraph.topologyDidChange.send()

        // Auto-generate exposed controls for this macro (curated identity only).
        nodeGraph.autoGenerateExposedControls(for: macro)

        // Sync scene bank: add the new macro's snapshot to every existing scene
        // so recalled scenes don't drop the new macro's parameters.
        syncSceneBankForAddedMacro(macro)

        // Topology change after the engine is running — atomic plan swap.
        if isProcessing {
            rebuildAudioGraphIfNeeded()
        }

        print(">> Neural Engine: Added macro '\(macro.name)' (total: \(macroNodes.count))")

        return macro
    }

    /// v1.x compatibility: addLane calls addMacro.
    @discardableResult
    func addLane(preset: LanePreset) -> MacroNode {
        return addMacro(preset: preset)
    }

    /// Remove a macro by its ID.
    /// v2.0: Removes the MacroNode from the graph.
    func removeMacro(id: UUID) {
        assert(Thread.isMainThread, "macros must be mutated on main thread")
        guard macroNodes.firstIndex(where: { $0.id == id }) != nil else { return }

        // Remove from node graph (this also removes connected edges)
        nodeGraph.removeNode(id: id)

        // Sync scene bank: remove this macro's snapshots from all scenes so
        // recalled scenes don't reference a dead node ID.
        syncSceneBankForRemovedMacro(id: id)

        print(">> Neural Engine: Removed macro (total: \(macroNodes.count))")
        updateMacroMixerState()
    }

    // MARK: - Scene Bank Synchronization (Wave C C5)

    /// Add a snapshot of a newly added macro to every existing scene.
    private func syncSceneBankForAddedMacro(_ macro: MacroNode) {
        let snapshot = GraphSnapshot(from: macro)
        for i in sceneBank.scenes.indices {
            sceneManager.sceneBank.scenes[i].graphSnapshots[macro.id] = snapshot
        }
    }

    /// Remove a deleted macro's snapshots from all scenes.
    private func syncSceneBankForRemovedMacro(id: UUID) {
        for i in sceneBank.scenes.indices {
            sceneManager.sceneBank.scenes[i].graphSnapshots.removeValue(forKey: id)
        }
    }

    /// v1.x compatibility: removeLane calls removeMacro.
    func removeLane(id: UUID) {
        removeMacro(id: id)
    }

    /// Reorder macros (for UI drag).
    func moveMacro(from source: IndexSet, to destination: Int) {
        assert(Thread.isMainThread, "macros must be mutated on main thread")
        // v2.0: We need to maintain the order in the lanes array
        // Since macroNodes is computed, we update the underlying nodeGraph.nodes order
        // Note: Dictionary doesn't guarantee order, so we use the lanes array as ordering
        lanes.move(fromOffsets: source, toOffset: destination)
    }

    /// v1.x compatibility: moveLane calls moveMacro.
    func moveLane(from source: IndexSet, to destination: Int) {
        moveMacro(from: source, to: destination)
    }

    /// Create a fallback macro when max is reached but we need to return something.
    private func createFallbackMacro() -> MacroNode {
        let preset = LanePreset.allPresets.first ?? .buchlaPerc
        return MacroNode.fromPreset(preset: preset)
    }

    // MARK: - Mixer State

    /// Apply volume, mute, and solo logic to all macros.
    /// Called by the UI whenever a macro's volume/mute/solo state changes.
    ///
    /// v2.0 fix: `MacroNode.fromPreset` never populated
    /// `macro.parameters["mixerNodeId"]` (no code path writes that key), so
    /// the previous implementation was a silent no-op — mute/solo/volume
    /// knobs moved on screen but never reached the audio thread. The macro's
    /// internal graph (cloned from `seed-feedback-flat.json` by
    /// `ImplicitGraphBuilder.buildGraph`) DOES contain a `MixerNode`; we
    /// locate it by type and write its `masterGain` directly. If a future
    /// preset ships without an internal mixer, we fall back to scaling the
    /// source-node amplitudes (OscillatorNode / NoiseNode) so mute/solo still
    /// has an audible effect rather than silently dropping on the floor.
    ///
    /// P3.13 Slice 2: implementation moved to
    /// `MacroMixerController.updateMacroMixerState(macro:nodeGraph:notify:)`
    /// (stateless helper extracted from this god-class). This instance
    /// method is now a thin delegator that iterates all macros and calls the
    /// helper once per macro, so callers (RootView, PerformanceMotherbaseView,
    /// applyParameter, applyScene, applyCrossfader, removeMacro, etc.) keep
    /// the same signature; the `objectWillChange.send()` side effect is
    /// preserved via the `notify` closure passed to the controller.
    func updateMacroMixerState() {
        for macro in macroNodes {
            MacroMixerController.updateMacroMixerState(
                macro: macro,
                nodeGraph: nodeGraph,
                notify: { self.objectWillChange.send() }
            )
        }
    }

    /// v1.x compatibility: updateLaneMixerState calls updateMacroMixerState.
    func updateLaneMixerState() {
        updateMacroMixerState()
    }

    // MARK: - Performance (Scenes, Crossfade, Step Grid)

    /// Apply scene at index immediately (no crossfade).
    /// v2.0: Uses graph-native scene operations.
    func applyScene(at index: Int) {
        sceneManager.applyScene(at: index, to: nodeGraph)
        // Update mixer state after scene change
        updateMacroMixerState()
    }

    /// Capture focus macro's current parameters into step at index.
    /// v2.0: Routes to the SequencerNode in the focus macro's internal graph.
    func captureCurrentToStep(at index: Int) {
        guard let macro = focusMacro else { return }
        guard let sequencer = macro.internalGraph.nodes.values.compactMap({ $0 as? SequencerNode }).first else { return }
        guard index >= 0, index < sequencer.stepGrid.steps.count else { return }

        let existing = sequencer.stepGrid.step(at: index) ?? PerformanceStep()

        // Extract current parameter values from the macro
        let step = PerformanceStep(
            trigType: existing.trigType,
            probability: existing.probability,
            cfg: macro.parameters["guidanceScale"] as? Float,
            feedback: macro.parameters["feedbackAmount"] as? Float,
            promptPhase: macro.parameters["promptPhaseOverride"] as? Int,
            denoiseStrength: macro.parameters["denoiseStrengthDefault"] as? Float,
            texture: macro.parameters["texture"] as? Float,
            chaos: macro.parameters["chaos"] as? Float,
            warmth: macro.parameters["warmth"] as? Float,
            filterCutoff: macro.parameters["filterCutoff"] as? Float,
            filterResonance: macro.parameters["filterResonance"] as? Float,
            excitationMode: macro.parameters["excitationMode"] as? String,
            delayMix: macro.parameters["delayMix"] as? Float,
            bitCrushDepth: macro.parameters["bitCrushDepth"] as? Float,
            drumVoice: existing.drumVoice,
            microtiming: existing.microtiming
        )

        sequencer.stepGrid.setStep(step, at: index)
    }

    /// When entering Perform from Setup, sync current state into Scene A and B if they are empty.
    func syncSetupToScenesOnEnterPerform() {
        // v2.0: Capture current graph state to scenes if empty
        let sceneAIndex = crossfaderSceneAIndex
        let sceneBIndex = crossfaderSceneBIndex

        // Check if scenes are empty and capture if so
        if sceneAIndex < sceneBank.scenes.count {
            let sceneA = sceneBank.scenes[sceneAIndex]
            if sceneA.graphSnapshots.isEmpty && sceneA.laneSnapshots.isEmpty {
                sceneManager.captureScene(at: sceneAIndex, from: nodeGraph)
            }
        }

        if sceneBIndex < sceneBank.scenes.count {
            let sceneB = sceneBank.scenes[sceneBIndex]
            if sceneB.graphSnapshots.isEmpty && sceneB.laneSnapshots.isEmpty {
                sceneManager.captureScene(at: sceneBIndex, from: nodeGraph)
            }
        }
    }

    /// Capture current graph state into scene at index.
    func captureCurrentToScene(at index: Int) {
        sceneManager.captureScene(at: index, from: nodeGraph)
    }

    // MARK: - Step Grid Wiring (Delegated to SequencerEngine)

    /// Start or stop the step timer based on sequencer nodes.
    func syncStepTimer() {
        sequencerEngine.syncStepTimer()
    }

    /// Cancel the step timer.
    func cancelStepTimer() {
        sequencerEngine.cancelStepTimer()
    }

    /// Manual step advance for one macro (tap or keyboard).
    func advanceMacroManually(macro: MacroNode) {
        // Find the sequencer in this macro and advance it
        if let sequencer = macro.internalGraph.nodes.values.compactMap({ $0 as? SequencerNode }).first {
            sequencer.advance()
        }
    }

    /// v1.x compatibility: advanceLaneManually calls advanceMacroManually.
    func advanceLaneManually(lane: MacroNode) {
        advanceMacroManually(macro: lane)
    }

    /// Apply current step's parameter locks to one macro only.
    /// v2.0: Applies to the MacroNode's internal graph parameters.
    ///
    /// P3.13: implementation moved to `MacroLockController.applyMacroStepLocks`
    /// (stateless helper extracted from this god-class as the first surgical
    /// slice of the P3.13 split). This instance method is now a thin
    /// delegator so callers (RootView, PerformanceMotherbaseView, the
    /// sequencer engine, etc.) keep the same signature; the
    /// `objectWillChange.send()` side effect is preserved via the `notify`
    /// closure passed to the controller.
    func applyMacroStepLocks(macro: MacroNode) {
        MacroLockController.applyMacroStepLocks(macro: macro, nodeGraph: nodeGraph) { self.objectWillChange.send() }
    }

    /// v1.x compatibility: applyLaneStepLocks calls applyMacroStepLocks.
    func applyLaneStepLocks(lane: MacroNode) {
        applyMacroStepLocks(macro: lane)
    }

    // MARK: - Step Lock API (Sequencer v2)

    /// Set a single Float? lock on a step via KeyPath.
    func setStepLock(at index: Int, _ keyPath: WritableKeyPath<PerformanceStep, Float?>, value: Float?) {
        guard let macro = focusMacro else { return }
        guard let sequencer = macro.internalGraph.nodes.values.compactMap({ $0 as? SequencerNode }).first else { return }
        guard index >= 0, index < sequencer.stepGrid.steps.count else { return }
        sequencer.stepGrid.steps[index][keyPath: keyPath] = value
    }

    /// Set a Float? lock on all selected steps.
    func setStepLockForSelected(_ keyPath: WritableKeyPath<PerformanceStep, Float?>, value: Float?) {
        guard let macro = focusMacro else { return }
        guard let sequencer = macro.internalGraph.nodes.values.compactMap({ $0 as? SequencerNode }).first else { return }
        for idx in selectedStepIndices {
            guard idx >= 0, idx < sequencer.stepGrid.steps.count else { continue }
            sequencer.stepGrid.steps[idx][keyPath: keyPath] = value
        }
    }

    /// Set a generic per-control lock on a step (Wave C C2).
    func setStepLock(at index: Int, controlId: UUID, value: Float?) {
        guard let macro = focusMacro else { return }
        guard let sequencer = macro.internalGraph.nodes.values.compactMap({ $0 as? SequencerNode }).first else { return }
        guard index >= 0, index < sequencer.stepGrid.steps.count else { return }
        sequencer.stepGrid.steps[index].genericLocks[controlId] = value
    }

    /// Set a generic per-control lock on all selected steps.
    func setStepLockForSelected(controlId: UUID, value: Float?) {
        guard let macro = focusMacro else { return }
        guard let sequencer = macro.internalGraph.nodes.values.compactMap({ $0 as? SequencerNode }).first else { return }
        for idx in selectedStepIndices {
            guard idx >= 0, idx < sequencer.stepGrid.steps.count else { continue }
            sequencer.stepGrid.steps[idx].genericLocks[controlId] = value
        }
    }

    /// Returns the set of parameter keys currently locked by the active step
    /// of the focus macro. `SceneManager` uses this to skip locked parameters
    /// during scene recall and crossfade so p-locks hold their current value.
    func lockedParameterKeysForActiveStep() -> Set<ParameterLockKey> {
        guard let macro = focusMacro else { return [] }
        guard let sequencer = macro.internalGraph.nodes.values.compactMap({ $0 as? SequencerNode }).first else { return [] }
        guard let step = sequencer.stepGrid.step(at: sequencer.stepGrid.currentStepIndex) else { return [] }
        return MacroLockController.lockedParameterKeys(for: step, macro: macro, exposedControls: nodeGraph.exposedControls)
    }

    /// Set trig type for a step.
    func setStepTrigType(at index: Int, _ type: TrigType) {
        guard let macro = focusMacro else { return }
        guard let sequencer = macro.internalGraph.nodes.values.compactMap({ $0 as? SequencerNode }).first else { return }
        guard index >= 0, index < sequencer.stepGrid.steps.count else { return }
        sequencer.stepGrid.steps[index].trigType = type
    }

    /// C.1 — Toggle a step's "active" flag.
    ///
    /// In Elektron-style step sequencers a step is "active" when it triggers
    /// the voice and "inactive" when it is skipped. Internally that maps to
    /// `TrigType.note` (active) and `TrigType.skip` (inactive). All other
    /// trig types (`.lock`, `.oneShot`) are treated as active for the
    /// purposes of this toggle — tapping them flips to `.skip`, tapping
    /// `.skip` brings the step back to `.note`.
    func toggleStepActive(at index: Int) {
        guard let macro = focusMacro else { return }
        guard let sequencer = macro.internalGraph.nodes.values
            .compactMap({ $0 as? SequencerNode }).first else { return }
        guard index >= 0, index < sequencer.stepGrid.steps.count else { return }
        let current = sequencer.stepGrid.steps[index].trigType
        sequencer.stepGrid.steps[index].trigType = (current == .skip) ? .note : .skip
    }

    /// Set prompt phase lock for a step (Int?, not Float).
    func setStepPromptPhase(at index: Int, phase: Int?) {
        guard let macro = focusMacro else { return }
        guard let sequencer = macro.internalGraph.nodes.values.compactMap({ $0 as? SequencerNode }).first else { return }
        guard index >= 0, index < sequencer.stepGrid.steps.count else { return }
        sequencer.stepGrid.steps[index].promptPhase = phase
    }

    /// Set DrumVoice lock for a step.
    func setStepDrumVoice(at index: Int, voice: DrumVoice?) {
        guard let macro = focusMacro else { return }
        guard let sequencer = macro.internalGraph.nodes.values.compactMap({ $0 as? SequencerNode }).first else { return }
        guard index >= 0, index < sequencer.stepGrid.steps.count else { return }
        sequencer.stepGrid.steps[index].drumVoice = voice
    }

    /// Set probability gate for a step (nil = always fire).
    func setStepProbability(at index: Int, probability: Float?) {
        guard let macro = focusMacro else { return }
        guard let sequencer = macro.internalGraph.nodes.values.compactMap({ $0 as? SequencerNode }).first else { return }
        guard index >= 0, index < sequencer.stepGrid.steps.count else { return }
        sequencer.stepGrid.steps[index].probability = probability
    }

    /// Set per-step microtiming offset (-0.5...0.5).
    func setStepMicrotiming(at index: Int, microtiming: Double) {
        guard let macro = focusMacro else { return }
        guard let sequencer = macro.internalGraph.nodes.values.compactMap({ $0 as? SequencerNode }).first else { return }
        guard index >= 0, index < sequencer.stepGrid.steps.count else { return }
        var step = sequencer.stepGrid.step(at: index) ?? PerformanceStep()
        step.microtiming = microtiming
        sequencer.stepGrid.setStep(step, at: index)
    }

    /// Clear all locks on a step (reset to default note trig).
    func clearStep(at index: Int) {
        guard let macro = focusMacro else { return }
        guard let sequencer = macro.internalGraph.nodes.values.compactMap({ $0 as? SequencerNode }).first else { return }
        guard index >= 0, index < sequencer.stepGrid.steps.count else { return }
        sequencer.stepGrid.setStep(PerformanceStep(), at: index)
    }

    // MARK: - Multi-Select & Batch Operations (Shift+click)

    /// Handle step pad tap. Shift+click toggles multi-select; plain tap selects single.
    func handleStepTap(index: Int, shiftPressed: Bool, chainLength: Int) {
        guard index >= 0, index < chainLength else { return }
        if shiftPressed {
            if selectedStepIndices.contains(index) {
                selectedStepIndices.remove(index)
                pLockEditingStepIndex = selectedStepIndices.min()
            } else {
                selectedStepIndices.insert(index)
                pLockEditingStepIndex = index
            }
        } else {
            if selectedStepIndices == [index] {
                selectedStepIndices = []
                pLockEditingStepIndex = nil
            } else {
                selectedStepIndices = [index]
                pLockEditingStepIndex = index
            }
        }
    }

    /// Apply trig type to all selected steps.
    func applyTrigTypeToSelected(_ type: TrigType) {
        guard let macro = focusMacro else { return }
        guard let sequencer = macro.internalGraph.nodes.values.compactMap({ $0 as? SequencerNode }).first else { return }
        for idx in selectedStepIndices {
            guard idx >= 0, idx < sequencer.stepGrid.steps.count else { continue }
            sequencer.stepGrid.steps[idx].trigType = type
        }
    }

    /// Apply DrumVoice to all selected steps.
    func applyDrumVoiceToSelected(_ voice: DrumVoice?) {
        guard let macro = focusMacro else { return }
        guard let sequencer = macro.internalGraph.nodes.values.compactMap({ $0 as? SequencerNode }).first else { return }
        for idx in selectedStepIndices {
            guard idx >= 0, idx < sequencer.stepGrid.steps.count else { continue }
            sequencer.stepGrid.steps[idx].drumVoice = voice
        }
    }

    /// Clear all selected steps.
    func clearSelectedSteps() {
        guard let macro = focusMacro else { return }
        guard let sequencer = macro.internalGraph.nodes.values.compactMap({ $0 as? SequencerNode }).first else { return }
        for idx in selectedStepIndices {
            guard idx >= 0, idx < sequencer.stepGrid.steps.count else { continue }
            sequencer.stepGrid.setStep(PerformanceStep(), at: idx)
        }
    }

    /// Apply crossfader blend between scene A and B (position 0 = A, 1 = B).
    /// v2.0: Uses graph-native crossfade.
    func applyCrossfader() {
        sceneManager.applyCrossfader(
            t: crossfaderPosition,
            sceneAIndex: crossfaderSceneAIndex,
            sceneBIndex: crossfaderSceneBIndex,
            to: nodeGraph
        )
        updateMacroMixerState()
    }

    // MARK: - Processing Control

    /// - Parameter initiatedFromPerformMode: True when START was pressed in Perform view.
    func toggleProcessing(initiatedFromPerformMode: Bool = false) {
        if isProcessing {
            // Debounce: ignore stop for 3s after start
            if let t = lastStartTime, Date().timeIntervalSince(t) < startDebounceInterval {
                return
            }
            print(">> Neural Engine: STOP requested (toggle)")
            stopProcessing()
        } else {
            startProcessing(initiatedFromPerformMode: initiatedFromPerformMode)
        }
    }

    private func startProcessing(initiatedFromPerformMode: Bool = false) {
        // TODO(future): P3.13 Slice 5 intentionally left this inline. It
        // calls `audioEngine.prepare()` / `audioEngine.start()`, mutates
        // `isProcessing` / `lastStartTime` / `canAbort`, installs the
        // audio input tap, and orchestrates `rebuildAudioGraphIfNeeded()`
        // + `verifyAudioPipeline()` + `restoreSilentSources()`. Every
        // line touches real-time audio-thread invariants or
        // AVAudioEngine state — pure-logic extraction is not possible
        // without an audio-engine abstraction. The pure helpers it
        // calls (`AudioPipelineValidator.auditGraph` /
        // `restoreSilentSources`) ARE extracted and tested.
        print(">> Neural Engine: [SOUND DEBUG] startProcessing called")
        do {
            // Check if any macro needs audio input
            let needsAudioInput = macroNodes.contains { macro in
                macro.parameters["excitationMode"] as? String == ExcitationMode.audioInput.rawValue
            }
            if needsAudioInput {
                updateAudioInputTap()
            }

            // Refresh the ExecutionPlan from the current NodeGraph state
            // before starting the audio engine, so the very first render
            // block already has a valid plan adopted.
            if graphAudioEngine != nil {
                print(">> Neural Engine: [SOUND DEBUG] Rebuilding execution plan with \(nodeGraph.nodes.count) graph nodes")
                rebuildAudioGraphIfNeeded()
                print(">> Neural Engine: [SOUND DEBUG] Execution plan adopted")
            } else {
                print(">> Neural Engine: [SOUND DEBUG] WARNING: graphAudioEngine is nil!")
            }

            audioEngine.prepare()
            print(">> Neural Engine: [SOUND DEBUG] Audio engine prepared, attempting start...")
            try audioEngine.start()
            isProcessing = true
            print(">> Neural Engine: [SOUND DEBUG] Audio engine STARTED successfully 🎵")
            processingStartedInPerformMode = initiatedFromPerformMode

            // A.7: Verify the full pipeline is healthy once the engine is running.
            // This runs ON start, not before — the status checks engine.isRunning.
            var status = verifyAudioPipeline()

            // A.8: Auto-restore silent sources. A performer who hits START with
            // every source amplitude at (or near) zero -- a bad preset, a stray
            // knob drag, whatever the cause -- would otherwise hear nothing with
            // zero recovery path (the diagnostic below only ever reached the
            // Xcode console). Fires once, here, on START only -- never
            // continuously from `render()` -- so it can never fight a
            // performer's live fade-out.
            if status.engineRunning && status.sourceNodeCount > 0 && !status.sourceActive {
                restoreSilentSources()
                status = verifyAudioPipeline()
            }

            lastPipelineStatus = status

            if !status.isHealthy {
                print(">> Neural Engine: ⚠️ PIPELINE UNHEALTHY — expect silence or broken audio:")
                print(">>   engineRunning: \(status.engineRunning)")
                print(">>   audioNodes: \(status.audioNodeCount) (need >0)")
                print(">>   sources: \(status.sourceNodeCount) (need >0)")
                print(">>   masterOutputs: \(status.masterOutputCount) (need =1)")
                print(">>   attachedNodes: \(status.attachedNodeCount) (need >0)")
                print(">>   sourceActive: \(status.sourceActive) (need true: amp>0 & freq>0)")
                print(">>   masterVolume: \(status.masterVolume) (need >0.01)")
                print(">>   reason: \(status.silenceReason ?? "unknown")")
            } else {
                print(">> Neural Engine: ✓ Pipeline verified healthy — audio should be audible")
            }

            // Start sequencer subscriptions
            sequencerEngine.subscribeSequencerIterations()

            lastStartTime = Date()
            canAbort = false
            DispatchQueue.main.asyncAfter(deadline: .now() + startDebounceInterval) { [weak self] in
                self?.canAbort = true
            }
            syncStepTimer()

            // Apply initial step locks
            for macro in macroNodes {
                applyMacroStepLocks(macro: macro)
            }

            let macroNames = macroNodes.map { $0.name }.joined(separator: ", ")
            print(">> Neural Engine: Multi-macro loop INITIATED -- macros: [\(macroNames)]")

        } catch {
            print(">> Neural Engine: [SOUND DEBUG] FAILED to start audio -- \(error.localizedDescription)")
            print(">> Neural Engine: [SOUND DEBUG] Error details: \(error)")
        }
    }

    /// Stop all processing -- audio, sequencers, engine.
    ///
    /// INVARIANT: this stops the local `AVAudioEngine` only. It must NEVER
    /// call `bridgeProcess.terminateServer()` / kill the Python bridge.
    /// The bridge is a separate, expensive-to-relaunch process (venv +
    /// model load, tens of seconds); STOP is a fast, frequent, reversible
    /// UI action (Space bar) and killing the bridge on every STOP would
    /// (a) throw away a loaded model for no reason and (b) abort any
    /// `FeedbackLoopNode` inference `Task` still in flight mid-request
    /// instead of letting it complete and land in `feedbackBuffer` (dead
    /// code until the next START, but not wasted work). Bridge lifecycle
    /// is owned exclusively by `shutdownAll()` (app quit) and explicit
    /// profile/mode-switch restarts -- see BridgeProcessManager.
    func stopProcessing() {
        // TODO(future): P3.13 Slice 5 intentionally left this inline. It
        // calls `audioEngine.stop()` and `removeAudioInputTap()` — both
        // mutate the AVAudioEngine / CoreAudio tap state. Real-time
        // audio-thread invariants; not safely testable without a live
        // audio engine. Pure-logic extraction not possible here.
        guard isProcessing else { return }

        processingStartedInPerformMode = false

        // 1. Cancel sequencer subscriptions
        sequencerEngine.stop()

        // 2. Stop engine first
        audioEngine.stop()

        // 3. Remove audio input tap
        removeAudioInputTap()

        isProcessing = false
        lastPipelineStatus = PipelineStatus()
        print(">> Neural Engine: All macros ABORTED -- state reset (bridge process untouched)")
    }

    // MARK: - Koenig Seed Manual Trigger (Manifesto: "Listen before you adjust")
    //
    // START no longer auto-injects the Koenig seed — the onboarding
    // manifesto says "listen before you adjust", but pressing SPACE used
    // to fire the Euclidean rhythm immediately (the seed's `render` was
    // called by the audio thread the moment `audioEngine.start()` ran).
    // This method is the manual injection path: it toggles the arm state
    // on every `KoenigSeedNode` and every `OscillatorNode` currently in
    // `.koenigSeed` mode. Bound to the K key, the SEED button in the
    // status bar, and MIDI/OSC. Returns true if any seed is now armed.
    @discardableResult
    func triggerKoenigSeed() -> Bool {
        var anyArmed = false
        for node in nodeGraph.nodes.values {
            if let koenig = node as? KoenigSeedNode {
                if koenig.triggerSeed() { anyArmed = true }
            } else if let osc = node as? OscillatorNode, osc.waveform == .koenigSeed {
                if osc.triggerSeed() { anyArmed = true }
            }
        }
        objectWillChange.send()
        return anyArmed
    }

    /// True if any Koenig seed source is currently armed (UI introspection
    /// for the SEED button state). Walks the same node set as
    /// `triggerKoenigSeed()` so the button reflects exactly what the
    /// performer would hear on the next render block.
    var anySeedArmed: Bool {
        for node in nodeGraph.nodes.values {
            if let koenig = node as? KoenigSeedNode, koenig.isSeedArmed { return true }
            if let osc = node as? OscillatorNode, osc.waveform == .koenigSeed, osc.isSeedArmed { return true }
        }
        return false
    }

    // MARK: - Audio Input Tap (Shared Buffer for .audioInput Excitation)

    private func updateAudioInputTap() {
        // TODO(future): P3.13 Slice 5 intentionally left this inline. It
        // calls `audioEngine.inputNode.installTap(...)` — CoreAudio tap
        // installation on the hardware input node. Real-time audio
        // thread + system-API coupling; not safely testable without a
        // live audio engine and input device.
        guard !inputTapInstalled else { return }
        let inputNode = audioEngine.inputNode
        let hwFormat = inputNode.inputFormat(forBus: 0)
        guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else { return }
        let buf = audioInputBuffer
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { buffer, _ in
            guard let channelData = buffer.floatChannelData else { return }
            let frameCount = Int(buffer.frameLength)
            buf.write(channelData[0], count: frameCount)
        }
        inputTapInstalled = true
    }

    private func removeAudioInputTap() {
        // TODO(future): P3.13 Slice 5 intentionally left this inline.
        // Calls `audioEngine.inputNode.removeTap(onBus: 0)` — CoreAudio
        // tap teardown. System-API coupling; not safely testable without
        // a live audio engine.
        guard inputTapInstalled else { return }
        audioEngine.inputNode.removeTap(onBus: 0)
        inputTapInstalled = false
    }

    // MARK: - Graph Bootstrap (v2.0 Factory Topology)

    /// Loads saved graph or bootstraps with the default factory topology for immediate sound.
    /// Priority: 1) User's saved graph, 2) Factory topology, 3) Emergency graph (A.6).
    /// The emergency graph (220 Hz saw → MasterOutput) guarantees that audio
    /// pipeline health can always be verified even if every JSON asset is broken.
    private func loadGraphOrBootstrap() {
        print(">> NeuralEngine: Attempting to load saved graph...")

        // Try to load user's saved graph first
        if let saved = NodeGraphStore.load() {
            do {
                try nodeGraph.deserialize(saved)
                print(">> NeuralEngine: Loaded saved graph with \(nodeGraph.nodes.count) nodes, \(nodeGraph.edges.count) edges")

                // Auto-generate controls if no macros exist (legacy graph)
                if macroNodes.isEmpty {
                    print(">> NeuralEngine: No macros found; manual opt-in required for exposure")
                    nodeGraph.autoGenerateExposedControlsForMainGraph()
                }

                return
            } catch {
                print(">> NeuralEngine: Failed to load saved graph: \(error)")
                // Fall through to factory topology
            }
        }

        print(">> NeuralEngine: No saved graph. Loading factory topology '\(LRConstants.defaultFactoryTopologyFileName)'...")

        do {
            try loadDefaultFactoryTopologyThrowing()

            print(">> NeuralEngine: Loaded factory topology with \(nodeGraph.nodes.count) nodes, \(nodeGraph.edges.count) edges")

            // Auto-generate controls for flat factory topology (no macros)
            nodeGraph.autoGenerateExposedControlsForMainGraph()
            print(">> NeuralEngine: Auto-generated \(nodeGraph.exposedControls.count) exposed controls")

            print(">> NeuralEngine: ═══════════════════════════════════════════════════")
            print(">> NeuralEngine: 🎹 FACTORY TOPOLOGY LOADED!")
            print(">> NeuralEngine:    Chain: Seed → FeedbackLoop → ACE → Mix → Master")
            print(">> NeuralEngine:    Controls: \(nodeGraph.exposedControls.count) parameters exposed")
            print(">> NeuralEngine: ⏯️  PRESS [SPACEBAR] TO START AUDIO ENGINE")
            print(">> NeuralEngine: ═══════════════════════════════════════════════════")

        } catch {
            print(">> NeuralEngine: ✗ Factory topology failed: \(error.localizedDescription)")
            print(">> NeuralEngine: Falling back to emergency graph (220 Hz saw → MasterOutput)")

            // A.6: NEVER leave the user with a dead app. Emergency graph guarantees
            // the audio pipeline can always prove itself — even if every JSON asset
            // is broken. Previous behavior was `fatalError`, which crashed the app
            // and left zero diagnostic surface for the user.
            loadEmergencyGraph()
        }
    }

    /// A.6: Minimal guaranteed-audible graph. Used when every other load path fails.
    /// Creates a 220 Hz saw oscillator → MasterOutputNode chain directly in the
    /// existing nodeGraph (we mutate in place rather than replacing the instance
    /// because the rest of NeuralEngine holds the reference).
    private func loadEmergencyGraph() {
        // Clear any partial state from failed load attempts
        nodeGraph.nodes.removeAll()
        nodeGraph.edges.removeAll()
        nodeGraph.exposedControls.removeAll()

        let osc = OscillatorNode(params: [
            "frequency": Float(220.0),
            "amplitude": Float(0.5),
            "waveform": "saw"
        ])
        osc.x = 100
        osc.y = 200
        nodeGraph.nodes[osc.id] = osc

        let master = MasterOutputNode(name: "Master Out", x: 400, y: 200)
        nodeGraph.nodes[master.id] = master

        let edge = GraphEdge(
            id: UUID(),
            sourceNodeId: osc.id,
            sourcePortId: "out",
            targetNodeId: master.id,
            targetPortId: "in",
            signalType: .audio
        )
        nodeGraph.edges[edge.id] = edge

        nodeGraph.autoGenerateExposedControlsForMainGraph()

        print(">> NeuralEngine: ═══════════════════════════════════════════════════")
        print(">> NeuralEngine: 🚨 EMERGENCY GRAPH ACTIVE")
        print(">> NeuralEngine:    220 Hz saw → MasterOutput")
        print(">> NeuralEngine:    If you hear this, the audio engine is healthy.")
        print(">> NeuralEngine:    The factory topology or saved graph is broken.")
        print(">> NeuralEngine: ═══════════════════════════════════════════════════")

        nodeGraph.objectWillChange.send()
        nodeGraph.topologyDidChange.send()
    }

    // MARK: - Topology Reservoir (Envion §3.2)

    enum TopologyLoadSource: Equatable {
        case bundled(fileName: String)
        case savedSession
        case userSaved(fileName: String)
    }

    /// Replace the live graph with a bundled factory topology or the user's
    /// last saved session. Stops audio first; persists the result to App Support.
    func loadTopology(from source: TopologyLoadSource) throws {
        if isProcessing { stopProcessing() }

        let serialized: SerializedGraph
        switch source {
        case .bundled(let fileName):
            serialized = try TopologyTemplates.loadSerialized(fileName)
        case .savedSession:
            guard let saved = NodeGraphStore.load() else {
                throw TopologyTemplates.TopologyError.notFound("saved session")
            }
            serialized = saved
        case .userSaved(let fileName):
            serialized = try NodeGraphStore.loadUserTopology(fileName: fileName)
        }

        try nodeGraph.deserialize(serialized)

        if nodeGraph.exposedControls.isEmpty, macroNodes.isEmpty {
            nodeGraph.autoGenerateExposedControlsForMainGraph()
        }

        focusMacroId = macroNodes.first?.id
        pLockEditingStepIndex = nil
        selectedStepIndices = []
        updateLanesArray()
        NodeGraphStore.save(nodeGraph)
        nodeGraph.topologyDidChange.send()

        print(">> NeuralEngine: Loaded topology (\(source)) — \(nodeGraph.nodes.count) nodes, \(nodeGraph.exposedControls.count) controls")
    }

    /// Loads the default factory topology from `Resources/Topologies/`.
    /// Throws on failure with detailed error information.
    private func loadDefaultFactoryTopologyThrowing() throws {
        let template = try TopologyTemplates.loadSerialized(LRConstants.defaultFactoryTopologyFileName)
        try nodeGraph.deserialize(template)
    }

    // MARK: - Cross-Lane Feedback Routing (v2.0)

    /// v2.0: Cross-macro feedback routing via graph edges.
    func updateFeedbackRouting() {
        // v2.0: Feedback routing is handled by the graph itself via FeedbackLoopNode edges
        // This method is kept for v1.x compatibility but is now a no-op
        // The graph's topology determines the feedback paths
    }

    // MARK: - Master Recording Control (§5)

    func toggleMasterRecording() {
        if isMasterRecording {
            stopMasterRecording()
        } else {
            startMasterRecording()
        }
    }

    private func startMasterRecording() {
        let format = effectiveFormat
        do {
            _ = try masterRecorder.startRecording(name: "MASTER", format: format)
            isMasterRecording = true
            print(">> Neural Engine: Recording started -> \(AudioRecorder.outputDirectory.path)")
        } catch {
            print(">> Neural Engine: Master recording failed -- \(error.localizedDescription)")
        }
    }

    private func stopMasterRecording() {
        if let url = masterRecorder.stopRecording() {
            isMasterRecording = false
            let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            let mb = String(format: "%.1f", Double(bytes) / 1_048_576)
            print(">> Neural Engine: Recording saved -> \(url.path) (\(mb) MB)")
            // Export metadata
            let totalCycles = feedbackLoopNodes.reduce(0) { $0 + $1.iterationCount }
            let macroNames = macroNodes.map { $0.name }
            AudioRecorder.exportMetadata(
                recordingURL: url,
                iterationCount: totalCycles,
                macroName: "MASTER",
                parameters: [
                    "activeMacros": macroNames,
                    "macroCount": macroNodes.count
                ],
                featureLog: [] // v2.0: Feature logs come from telemetry
            )
        } else {
            isMasterRecording = false
        }
    }

    // MARK: - Master Audio Tap (Recording)

    private func processMasterTap(_ buffer: AVAudioPCMBuffer) {
        masterRecorder.writeBuffer(buffer)
    }

    // MARK: - SwiftUI Preview Support

    /// Preview instance for SwiftUI canvas.
    /// Creates a minimal engine with default macros for previewing UI components.
    static var preview: NeuralEngine {
        let engine = NeuralEngine()
        // Pre-configure for preview (no audio engine start)
        return engine
    }

}
