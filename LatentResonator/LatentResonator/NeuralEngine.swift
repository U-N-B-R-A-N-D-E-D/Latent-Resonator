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

    // MARK: - Global State

    @Published var isProcessing: Bool = false

    /// False for 3s after start so Abort button is disabled (avoids accidental tap killing first inference).
    @Published var canAbort: Bool = true

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

    // MARK: - Core ML (Shared Across Macros)

    private var coreMLInference: CoreMLInference?

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

    // MARK: - v2.0 Sequencer Engine

    /// Owns step timer and advance logic for all SequencerNodes in the graph.
    /// v2.0: Graph-native, no lane dependencies.
    private lazy var sequencerEngine: SequencerEngine = SequencerEngine(
        nodeGraph: nodeGraph,
        isProcessingGetter: { [weak self] in self?.isProcessing ?? false }
    )

    // MARK: - Lifecycle

    private var cancellables = Set<AnyCancellable>()

    // MARK: - MIDI Routing Setup

    /// Shared routing logic for both MIDI CC and OSC input.
    private func applyParameter(_ param: ControlParameter, value: Float) {
        // #region agent log
        fputs("[\(ISO8601DateFormatter().string(from: Date()))] [NeuralEngine:applyParameter] param=\(param.rawValue) value=\(value)\n", stderr)
        fflush(stderr)
        // #endregion
        
        switch param {
        case .crossfader:
            crossfaderPosition = value
            applyCrossfader()
            return
        default:
            guard let macro = focusMacro else {
                // #region agent log
                fputs("[\(ISO8601DateFormatter().string(from: Date()))] [NeuralEngine:applyParameter] ✗ No focusMacro available, cannot apply parameter\n", stderr)
                fflush(stderr)
                // #endregion
                return
            }
            // #region agent log
            fputs("[\(ISO8601DateFormatter().string(from: Date()))] [NeuralEngine:applyParameter] ✓ Applying to macro: \(macro.name)\n", stderr)
            fflush(stderr)
            // #endregion

            // Apply to the macro's internal graph parameters
            // This routes control changes to the appropriate internal nodes
            switch param {
            case .volume:
                macro.parameters["volume"] = value
            case .guidanceScale:
                macro.parameters["guidanceScale"] = value
            case .feedback:
                macro.parameters["feedbackAmount"] = value
            case .texture:
                macro.parameters["texture"] = value
            case .chaos:
                macro.parameters["chaos"] = value
            case .warmth:
                macro.parameters["warmth"] = value
            case .filterCutoff:
                macro.parameters["filterCutoff"] = value
                // Also update internal ladder filter if present
                if let nodeId = macro.parameters["ladderFilterNodeId"] as? String,
                   let uuid = UUID(uuidString: nodeId) {
                    nodeGraph.setParameter(nodeId: uuid, key: "cutoff", value: value)
                }
            case .filterResonance:
                macro.parameters["filterResonance"] = value
            case .delayMix:
                macro.parameters["delayMix"] = value
            case .delayTime:
                macro.parameters["delayTime"] = value
            case .delayFeedback:
                macro.parameters["delayFeedback"] = value
            case .bitCrushDepth:
                macro.parameters["bitCrushDepth"] = value
            case .resonatorNote:
                macro.parameters["resonatorNote"] = value
            case .resonatorDecay:
                macro.parameters["resonatorDecay"] = value
            case .entropy:
                let cappedValue = value
                macro.parameters["entropyLevel"] = cappedValue
            case .granularity:
                let cappedValue = value
                macro.parameters["granularity"] = cappedValue
            case .shift:
                macro.parameters["shift"] = value
            case .inputStrength:
                macro.parameters["inputStrength"] = value
            case .inferenceSteps:
                macro.parameters["inferenceSteps"] = Int(value.rounded())
            case .sineFrequency:
                macro.parameters["sineFrequency"] = value
            case .pulseWidth:
                macro.parameters["pulseWidth"] = value
            case .lfoRate:
                macro.parameters["lfoRate"] = value
            case .lfoDepth:
                macro.parameters["lfoDepth"] = value
            case .mute:
                macro.parameters["isMuted"] = value >= 0.5
                updateMacroMixerState()
            case .solo:
                macro.parameters["isSoloed"] = value >= 0.5
                updateMacroMixerState()
            case .spectralMorphActive:
                macro.parameters["spectralFreezeActive"] = value >= 0.5
            case .autoDecayToggle:
                macro.parameters["autoDecayEnabled"] = value >= 0.5
            case .promptEvolution:
                macro.parameters["promptEvolutionEnabled"] = value >= 0.5
            case .inferMethodSDE:
                macro.parameters["inferMethod"] = value >= 0.5 ? "sde" : "ode"
            case .laneRecord:
                // TODO: Implement recording for v2.0 (track which macro is recording)
                break
            case .archiveRecall:
                _ = Int(value.rounded())
                // TODO: Implement archive recall for v2.0
                break
            default:
                break
            }

            // Publish change for UI observers
            objectWillChange.send()
        }
    }

    /// Connect MIDI CC and OSC input to the focus macro and engine-global parameters.
    private func setupMIDIRouting() {
        // #region agent log
        fputs("[\(ISO8601DateFormatter().string(from: Date()))] [NeuralEngine:setupMIDIRouting] Setting up MIDI/OSC routing\n", stderr)
        fflush(stderr)
        // #endregion
        
        midiInput.onParameterChange = { [weak self] param, value in
            // #region agent log
            fputs("[\(ISO8601DateFormatter().string(from: Date()))] [NeuralEngine:midiInput.onParameterChange] param=\(param.rawValue) value=\(value)\n", stderr)
            fflush(stderr)
            // #endregion
            self?.applyParameter(param, value: value)
        }
        midiInput.start()
        // #region agent log
        fputs("[\(ISO8601DateFormatter().string(from: Date()))] [NeuralEngine:setupMIDIRouting] MIDI input started\n", stderr)
        fflush(stderr)
        // #endregion

        oscInput.onParameterChange = { [weak self] param, value in
            self?.applyParameter(param, value: value)
        }
        if oscInput.isEnabled { oscInput.start() }
    }

    init() {
        NSLog("[LR-FATAL] NeuralEngine init STARTING")
        
        coreMLInference = CoreMLInference()
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

        // v2.0: Load saved graph or bootstrap with kickstart template
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

        // v2.0: Subscribe to node graph changes for lane array updates
        nodeGraph.$nodes
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateLanesArray()
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

        // v2.0: Subscribe to topology changes for audio graph rebuilds
        nodeGraph.topologyDidChange
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
    }

    deinit {
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

    // MARK: - Audio Graph Rebuild

    /// v2.0: Build a new ExecutionPlan from the NodeGraph and atomically
    /// hand it to the running GraphAudioEngine. No AVAudioEngine restart —
    /// the audio thread picks up the new plan at its next render block.
    private func rebuildAudioGraphIfNeeded() {
        guard let engine = graphAudioEngine else {
            print(">> Neural Engine: rebuildAudioGraphIfNeeded skipped — graphAudioEngine is nil (init order bug?)")
            return
        }

        let plan = ExecutionPlan.build(
            from: nodeGraph,
            frameCapacity: LRConstants.bufferSize
        )

        engine.adopt(plan)

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
            print(">> Neural Engine: Output device already at \(Int(targetRate))Hz")
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
            print(">> Neural Engine: Device rate \(Int(currentRate))Hz -> \(Int(targetRate))Hz")
        } else {
            print(">> Neural Engine: Failed to set device rate (err \(setStatus))")
            originalDeviceSampleRate = nil
        }
    }

    /// Restore the output device's original sample rate.
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
            print(">> Neural Engine: Device rate restored to \(Int(originalRate))Hz")
        }
        originalDeviceSampleRate = nil
    }

    private func setupMasterMixer() {
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

    /// Comprehensive verification of the audio signal chain.
    /// Call this after graph changes or when debugging audio issues.
    func verifyAudioPipeline() -> PipelineStatus {
        print("=== AUDIO PIPELINE VERIFICATION ===")

        var status = PipelineStatus()

        // 1. Engine state
        status.engineRunning = audioEngine.isRunning
        print("[Pipeline] Engine running: \(status.engineRunning)")

        // 2. Graph composition — count DSP-participating nodes (anything
        //    that publishes a non-nil dspNode()).
        let dspParticipating = nodeGraph.nodes.values.compactMap { node -> (any GraphNode)? in
            guard let provider = node as? GraphNodeDSPProvider, provider.dspNode() != nil else { return nil }
            return node
        }
        let sources = dspParticipating.filter { node in
            !nodeGraph.edges.values.contains { $0.targetNodeId == node.id && $0.signalType == .audio }
        }
        let masterOutputs = nodeGraph.nodes.values.compactMap { $0 as? MasterOutputNode }

        status.audioNodeCount = dspParticipating.count
        status.sourceNodeCount = sources.count
        status.masterOutputCount = masterOutputs.count

        print("[Pipeline] DSP-participating nodes: \(dspParticipating.count)")
        print("[Pipeline] Source nodes: \(sources.count)")
        print("[Pipeline] Master outputs: \(masterOutputs.count)")

        // 3. Source verification
        for source in sources {
            if let osc = source as? OscillatorNode {
                print("[Pipeline] Source '\(source.name)': freq=\(osc.frequency)Hz, amp=\(osc.amplitude), wave=\(osc.waveform)")
                status.sourceActive = status.sourceActive || (osc.amplitude > 0.01 && osc.frequency > 0)
            }
        }

        // 4. Master output verification
        if let master = masterOutputs.first {
            print("[Pipeline] Master volume: \(master.volume)")
            status.masterVolume = master.volume
        }

        // 5. Engine status
        if let engine = graphAudioEngine {
            status.attachedNodeCount = engine.currentPlanStepCount
            print("[Pipeline] Plan steps active: \(engine.currentPlanStepCount)")
        }

        // 6. System volume check (informational)
        print("[Pipeline] Format: \(effectiveFormat.sampleRate)Hz, \(effectiveFormat.channelCount)ch")

        print("===================================")

        return status
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

        // Auto-generate exposed controls for this macro
        nodeGraph.autoGenerateExposedControls(for: macro)

        // Sync scene bank: new macro gets its own fresh snapshot
        sceneManager.captureScene(at: macroNodes.count - 1, from: nodeGraph)

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

        // Sync scene bank: remove this macro's snapshot so indices stay aligned
        // Note: v2.0 uses graph-based scenes, this is a no-op for now
        // TODO: Implement scene synchronization for v2.0

        print(">> Neural Engine: Removed macro (total: \(macroNodes.count))")
        updateMacroMixerState()
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
    func updateMacroMixerState() {
        let anySoloed = macroNodes.contains(where: { $0.parameters["isSoloed"] as? Bool ?? false })

        for macro in macroNodes {
            let isMuted = macro.parameters["isMuted"] as? Bool ?? false
            let isSoloed = macro.parameters["isSoloed"] as? Bool ?? false
            let volume = macro.parameters["volume"] as? Float ?? 1.0

            // v2.0: Volume is applied via the internal graph's mixer node
            if let mixerNodeId = macro.parameters["mixerNodeId"] as? String,
               let uuid = UUID(uuidString: mixerNodeId) {
                let effectiveVolume: Float
                if isMuted {
                    effectiveVolume = 0.0
                } else if anySoloed {
                    effectiveVolume = isSoloed ? volume : 0.0
                } else {
                    effectiveVolume = volume
                }
                nodeGraph.setParameter(nodeId: uuid, key: "volume", value: effectiveVolume)
            }
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
    func applyMacroStepLocks(macro: MacroNode) {
        guard let sequencer = macro.internalGraph.nodes.values.compactMap({ $0 as? SequencerNode }).first else { return }
        let grid = sequencer.stepGrid
        guard let step = grid.step(at: grid.currentStepIndex) else { return }

        // Apply parameter locks to the macro
        if let v = step.cfg {
            macro.parameters["guidanceScale"] = min(max(v, LRConstants.cfgScaleRange.lowerBound), LRConstants.cfgScaleRange.upperBound)
        }
        if let v = step.feedback {
            macro.parameters["feedbackAmount"] = min(max(v, 0), 1)
        }
        if let phase = step.promptPhase {
            macro.parameters["promptPhaseOverride"] = min(max(phase, 1), 3)
        }

        // DSP / macro locks
        if let v = step.texture { macro.parameters["texture"] = min(max(v, 0), 1) }
        if let v = step.chaos { macro.parameters["chaos"] = min(max(v, 0), 1) }
        if let v = step.warmth { macro.parameters["warmth"] = min(max(v, 0), 1) }
        if let v = step.filterCutoff {
            macro.parameters["filterCutoff"] = min(max(v, LRConstants.filterCutoffRange.lowerBound),
                                                  LRConstants.filterCutoffRange.upperBound)
        }
        if let v = step.filterResonance {
            macro.parameters["filterResonance"] = min(max(v, LRConstants.filterResonanceRange.lowerBound),
                                                     LRConstants.filterResonanceRange.upperBound)
        }
        if let v = step.excitationMode {
            macro.parameters["excitationMode"] = v
        }
        if let v = step.delayMix { macro.parameters["delayMix"] = min(max(v, 0), 1) }
        if let v = step.bitCrushDepth {
            macro.parameters["bitCrushDepth"] = min(max(v, LRConstants.bitCrushRange.lowerBound),
                                                    LRConstants.bitCrushRange.upperBound)
        }

        // Trig behavior
        if step.trigType == .lock {
            // DSP-only mode for next cycle
            macro.parameters["dspOnlyForNextCycle"] = true
        }

        // Publish changes
        objectWillChange.send()
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
        // #region agent log - H7 Audio start
        debugLogSync("NeuralEngine:startProcessing", "startProcessing called")
        // #endregion
        
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
                debugLogSync("NeuralEngine:startProcessing", "Rebuilding execution plan", ["nodes": String(nodeGraph.nodes.count)])
                print(">> Neural Engine: [SOUND DEBUG] Rebuilding execution plan with \(nodeGraph.nodes.count) graph nodes")
                rebuildAudioGraphIfNeeded()
                debugLogSync("NeuralEngine:startProcessing", "Execution plan adopted")
                print(">> Neural Engine: [SOUND DEBUG] Execution plan adopted")
            } else {
                debugLogSync("NeuralEngine:startProcessing", "WARNING: graphAudioEngine is nil")
                print(">> Neural Engine: [SOUND DEBUG] WARNING: graphAudioEngine is nil!")
            }

            audioEngine.prepare()
            // #region agent log - H7 Engine prepared
            debugLogSync("NeuralEngine:startProcessing", "Audio engine prepared")
            // #endregion
            print(">> Neural Engine: [SOUND DEBUG] Audio engine prepared, attempting start...")
            try audioEngine.start()
            isProcessing = true
            // #region agent log - H7 Engine started
            debugLogSync("NeuralEngine:startProcessing", "Audio engine STARTED")
            // #endregion
            print(">> Neural Engine: [SOUND DEBUG] Audio engine STARTED successfully 🎵")
            processingStartedInPerformMode = initiatedFromPerformMode

            // A.7: Verify the full pipeline is healthy once the engine is running.
            // This runs ON start, not before — the status checks engine.isRunning.
            let status = verifyAudioPipeline()
            if !status.isHealthy {
                print(">> Neural Engine: ⚠️ PIPELINE UNHEALTHY — expect silence or broken audio:")
                print(">>   engineRunning: \(status.engineRunning)")
                print(">>   audioNodes: \(status.audioNodeCount) (need >0)")
                print(">>   sources: \(status.sourceNodeCount) (need >0)")
                print(">>   masterOutputs: \(status.masterOutputCount) (need =1)")
                print(">>   attachedNodes: \(status.attachedNodeCount) (need >0)")
                print(">>   sourceActive: \(status.sourceActive) (need true: amp>0 & freq>0)")
                print(">>   masterVolume: \(status.masterVolume) (need >0.01)")
                debugLogSync("NeuralEngine:startProcessing", "Pipeline unhealthy", [
                    "engineRunning": String(status.engineRunning),
                    "audioNodes": String(status.audioNodeCount),
                    "sources": String(status.sourceNodeCount),
                    "masterOutputs": String(status.masterOutputCount),
                    "attached": String(status.attachedNodeCount),
                    "sourceActive": String(status.sourceActive),
                    "masterVolume": String(status.masterVolume)
                ])
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
            // #region agent log - H7 Start failed
            debugLogSync("NeuralEngine:startProcessing", "FAILED to start audio", ["error": String(describing: error)])
            // #endregion
            print(">> Neural Engine: [SOUND DEBUG] FAILED to start audio -- \(error.localizedDescription)")
            print(">> Neural Engine: [SOUND DEBUG] Error details: \(error)")
        }
    }

    /// Stop all processing -- audio, sequencers, engine.
    func stopProcessing() {
        guard isProcessing else { return }

        processingStartedInPerformMode = false

        // 1. Cancel sequencer subscriptions
        sequencerEngine.stop()

        // 2. Stop engine first
        audioEngine.stop()

        // 3. Remove audio input tap
        removeAudioInputTap()

        isProcessing = false
        print(">> Neural Engine: All macros ABORTED -- state reset")
    }

    // MARK: - Audio Input Tap (Shared Buffer for .audioInput Excitation)

    private func updateAudioInputTap() {
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
        guard inputTapInstalled else { return }
        audioEngine.inputNode.removeTap(onBus: 0)
        inputTapInstalled = false
    }

    // MARK: - Debug Logging (File-based for reliability)
    
    static var logFileHandle: FileHandle?
    
    /// File-based logging that persists even if app crashes
    private func debugLogSync(_ location: String, _ message: String, _ data: [String: String] = [:]) {
        let dataStr = data.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let logMessage = "[\(timestamp)] [\(location)] \(message) \(dataStr)\n"
        
        // Lazy init file handle
        if NeuralEngine.logFileHandle == nil {
            let logPath = ("~/Library/Application Support/LatentResonator/debug.log" as NSString).expandingTildeInPath
            if !FileManager.default.fileExists(atPath: logPath) {
                FileManager.default.createFile(atPath: logPath, contents: nil, attributes: nil)
            }
            NeuralEngine.logFileHandle = FileHandle(forWritingAtPath: logPath)
        }
        
        if let handle = NeuralEngine.logFileHandle,
           let data = logMessage.data(using: .utf8) {
            handle.seekToEndOfFile()
            handle.write(data)
        }
        
        // Also print to stderr
        fputs(logMessage, stderr)
        fflush(stderr)
    }

    // MARK: - Graph Bootstrap (v2.0 Kickstart)

    /// Loads saved graph or bootstraps with kickstart template for immediate sound.
    /// Priority: 1) User's saved graph, 2) Kickstart template, 3) Emergency graph (A.6).
    /// The emergency graph (220 Hz saw → MasterOutput) guarantees that audio
    /// pipeline health can always be verified even if every JSON asset is broken.
    private func loadGraphOrBootstrap() {
        print(">> NeuralEngine: Attempting to load saved graph...")

        // #region agent log - H4 Bootstrap trace
        debugLogSync("NeuralEngine:loadGraphOrBootstrap", "Bootstrap starting")
        // #endregion

        // Try to load user's saved graph first
        if let saved = NodeGraphStore.load() {
            do {
                try nodeGraph.deserialize(saved)
                print(">> NeuralEngine: Loaded saved graph with \(nodeGraph.nodes.count) nodes, \(nodeGraph.edges.count) edges")

                // #region agent log - H4 Bootstrap saved graph
                debugLogSync("NeuralEngine:loadGraphOrBootstrap", "Loaded saved graph", [
                    "nodeCount": String(nodeGraph.nodes.count),
                    "edgeCount": String(nodeGraph.edges.count)
                ])
                // #endregion

                // Auto-generate controls if no macros exist (legacy graph)
                if macroNodes.isEmpty {
                    print(">> NeuralEngine: No macros found, auto-generating controls for main graph")
                    nodeGraph.autoGenerateExposedControlsForMainGraph()
                }

                return
            } catch {
                print(">> NeuralEngine: Failed to load saved graph: \(error)")

                // #region agent log - H4 Bootstrap saved graph failed
                debugLogSync("NeuralEngine:loadGraphOrBootstrap", "Saved graph load failed", [
                    "error": error.localizedDescription
                ])
                // #endregion

                // Fall through to kickstart
            }
        }

        print(">> NeuralEngine: No saved graph. Loading KickstartTemplate...")
        
        // #region agent log - H5 Before template load
        debugLogSync("NeuralEngine:loadGraphOrBootstrap", "Before kickstart load")
        // #endregion
        
        do {
            try loadKickstartTemplateThrowing()
            
            // #region agent log - H5 After template load
            debugLogSync("NeuralEngine:loadGraphOrBootstrap", "After kickstart load", [
                "nodeCount": String(nodeGraph.nodes.count),
                "edgeCount": String(nodeGraph.edges.count)
            ])
            // #endregion
            
            print(">> NeuralEngine: Loaded Kickstart with \(nodeGraph.nodes.count) nodes, \(nodeGraph.edges.count) edges")

            // Auto-generate controls for kickstart template (no macros)
            nodeGraph.autoGenerateExposedControlsForMainGraph()
            print(">> NeuralEngine: Auto-generated \(nodeGraph.exposedControls.count) exposed controls")

            print(">> NeuralEngine: ═══════════════════════════════════════════════════")
            print(">> NeuralEngine: 🎹 KICKSTART TEMPLATE LOADED!")
            print(">> NeuralEngine:    Chain: Oscillator → Filter → Mixer → Master")
            print(">> NeuralEngine:    Controls: \(nodeGraph.exposedControls.count) parameters exposed")
            print(">> NeuralEngine: ⏯️  PRESS [SPACEBAR] TO START AUDIO ENGINE")
            print(">> NeuralEngine: ═══════════════════════════════════════════════════")

            // #region agent log - H4 Bootstrap kickstart loaded
            debugLogSync("NeuralEngine:loadGraphOrBootstrap", "Kickstart template loaded", [
                "nodeCount": String(nodeGraph.nodes.count),
                "edgeCount": String(nodeGraph.edges.count),
                "exposedControls": String(nodeGraph.exposedControls.count)
            ])
            // #endregion

        } catch {
            // #region agent log - CATCH THE ERROR
            debugLogSync("NeuralEngine:loadGraphOrBootstrap", "Kickstart FAILED, falling back to emergency graph", [
                "error": String(describing: error)
            ])
            // #endregion

            print(">> NeuralEngine: ✗ KickstartTemplate failed: \(error.localizedDescription)")
            print(">> NeuralEngine: Falling back to emergency graph (220 Hz saw → MasterOutput)")

            // A.6: NEVER leave the user with a dead app. Emergency graph guarantees
            // the audio pipeline can always prove itself — even if every JSON asset
            // is broken. Previous behavior was `fatalError`, which crashed the app
            // and left zero diagnostic surface for the user.
            loadEmergencyGraph()

            debugLogSync("NeuralEngine:loadGraphOrBootstrap", "Emergency graph installed", [
                "nodeCount": String(nodeGraph.nodes.count),
                "edgeCount": String(nodeGraph.edges.count)
            ])
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
        print(">> NeuralEngine:    The KickstartTemplate or saved graph is broken.")
        print(">> NeuralEngine: ═══════════════════════════════════════════════════")

        nodeGraph.objectWillChange.send()
        nodeGraph.topologyDidChange.send()
    }

    /// Loads the kickstart template from app bundle.
    /// Throws on failure with detailed error information.
    private func loadKickstartTemplateThrowing() throws {
        // #region agent log - H6 Finding bundle
        debugLogSync("NeuralEngine:loadKickstartTemplateThrowing", "Looking for bundle")
        // #endregion
        
        guard let url = Bundle.main.url(forResource: "KickstartTemplate", withExtension: "json") else {
            // #region agent log - H6 Bundle not found
            debugLogSync("NeuralEngine:loadKickstartTemplateThrowing", "Bundle not found")
            // #endregion
            throw NSError(domain: "NeuralEngine", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "KickstartTemplate.json not found in bundle"
            ])
        }

        // #region agent log - H6 Reading data
        debugLogSync("NeuralEngine:loadKickstartTemplateThrowing", "Reading data", ["url": url.path])
        // #endregion
        
        let data = try Data(contentsOf: url)
        
        // #region agent log - H6 Decoding JSON
        debugLogSync("NeuralEngine:loadKickstartTemplateThrowing", "Decoding JSON", ["size": String(data.count)])
        // #endregion
        
        do {
            let template = try JSONDecoder().decode(SerializedGraph.self, from: data)
            
            // #region agent log - H6 Deserializing
            debugLogSync("NeuralEngine:loadKickstartTemplateThrowing", "Deserializing template", [
                "nodes": String(template.nodes.count),
                "edges": String(template.edges.count)
            ])
            // #endregion
            
            try nodeGraph.deserialize(template)
            
            // #region agent log - H6 Complete
            debugLogSync("NeuralEngine:loadKickstartTemplateThrowing", "Deserialization complete")
            // #endregion
        } catch {
            // #region agent log - H6 Decode/Deserialize ERROR
            debugLogSync("NeuralEngine:loadKickstartTemplateThrowing", "Decode or deserialize FAILED", [
                "error": String(describing: error),
                "errorType": String(describing: type(of: error))
            ])
            // #endregion
            throw error
        }
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
