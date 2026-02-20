import Foundation
import SwiftUI
import AVFoundation
import CoreAudio
import Combine
import Accelerate

// MARK: - Neural Engine (Lane Orchestrator)
//
// Manages N independent ResonatorLane instances, each running its own
// recursive feedback loop through the shared ACE-Step bridge.
//
// Architecture (multi-lane):
//
//   +-------------+  +-------------+       +-------------+
//   |  Lane 0     |  |  Lane 1     |  ...  |  Lane N     |
//   |  (DRUMS)    |  |  (BASS)     |       |  (NOISE)    |
//   |  excitation |  |  excitation |       |  excitation |
//   |  + feedback |  |  + feedback |       |  + feedback |
//   |  -> mixer    |  |  -> mixer    |       |  -> mixer    |
//   +------+------+  +------+------+       +------+------+
//          |                |                      |
//          +--------+-------+----------------------+
//                   v
//            masterMixerNode (volume, solo logic)
//                   |
//            mainMixerNode -> output
//                   |
//                 +-+-+
//                 |TAP| -> master recording
//                 +---+
//
// Each lane has its own inference queue but shares the single
// ACEStepBridge (HTTP requests are serialized by Flask).
// The "infinite game" runs at ~20s per lane cycle x N lanes.
//
// White paper reference:
//   §3.3 -- Recursive formula per lane
//   §6.1 -- Black Box Resonator (each lane is one resonator)
//   §1.2 -- The Lucier Chamber (delay per lane)

final class NeuralEngine: ObservableObject {

    // MARK: - Published Lane Array

    /// All active lanes. UI observes this for the mixer layout.
    @Published var lanes: [ResonatorLane] = []

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

    /// Master bus recorder -- captures mixed output of all lanes.
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
    /// Shift+click selection for batch operations. Cleared when focus lane changes.
    @Published var selectedStepIndices: Set<Int> = []
    @Published var focusLaneId: UUID?

    /// Step grid for the focused lane (Focus Lane UX). Each lane has its own stepGrid;
    /// this exposes the focused lane's grid for UI binding. Nil when no lanes exist.
    var focusStepGrid: StepGrid? { focusLane?.stepGrid }


    /// Total iteration count across all lanes (for step advance).
    var globalCycleCount: Int {
        lanes.reduce(0) { $0 + $1.iterationCount }
    }

    /// Focus lane (first lane whose id matches focusLaneId, or first lane).
    var focusLane: ResonatorLane? {
        if let id = focusLaneId, let lane = lanes.first(where: { $0.id == id }) {
            return lane
        }
        return lanes.first
    }

    /// Crossfader position 0...1 (A = 0, B = 1). Blends between sceneAIndex and sceneBIndex.
    @Published var crossfaderPosition: Float = 0
    @Published var crossfaderSceneAIndex: Int = 0
    @Published var crossfaderSceneBIndex: Int = 1

    // MARK: - Audio Engine

    private let audioEngine = AVAudioEngine()
    private let masterMixerNode = AVAudioMixerNode()

    // MARK: - Audio Input (Shared Ring Buffer for .audioInput Excitation)

    /// Shared ring buffer fed by the hardware input tap. Lanes configured
    /// as .audioInput read from this buffer instead of their oscillator.
    let audioInputBuffer = CircularAudioBuffer(capacity: LRConstants.audioInputBufferCapacity)
    /// Whether an input tap is currently installed on the audio engine.
    private var inputTapInstalled: Bool = false

    /// H19: Pre-allocated lane slots. All nodes attached to the graph at init.
    /// No audioEngine.attach/connect/stop calls ever happen after engine.start().
    private var laneSlots: [ResonatorLane] = []

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

    // MARK: - Core ML (Shared Across Lanes)

    private var coreMLInference: CoreMLInference?

    // MARK: - MIDI Input (§6 -- Controller Mapping)

    /// CoreMIDI input manager -- routes CC messages through ParameterRouter
    /// into the focus lane's parameters and engine-global controls.
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

    // MARK: - Sequencer Engine (Step Timing)

    /// Owns step timer and advance logic. NeuralEngine delegates timing to it.
    /// Lazy so init can complete before closures capture self.
    private lazy var sequencerEngine: SequencerEngine = SequencerEngine(
        lanesGetter: { [weak self] in self?.lanes ?? [] },
        focusStepGridGetter: { [weak self] in self?.focusStepGrid },
        isProcessingGetter: { [weak self] in self?.isProcessing ?? false },
        applyLocks: { [weak self] lane in self?.applyLaneStepLocks(lane: lane) }
    )

    // MARK: - Lifecycle

    private var cancellables = Set<AnyCancellable>()

    // MARK: - MIDI Routing Setup

    /// Shared routing logic for both MIDI CC and OSC input.
    private func applyParameter(_ param: ControlParameter, value: Float) {
        switch param {
        case .crossfader:
            crossfaderPosition = value
            applyCrossfader()
            return
        default:
            guard let lane = focusLane else { return }
            switch param {
            case .volume:              lane.volume = value
            case .guidanceScale:       lane.guidanceScale = value
            case .feedback:            lane.feedbackAmount = value
            case .texture:             lane.texture = value
            case .chaos:               lane.chaos = value
            case .warmth:              lane.warmth = value
            case .filterCutoff:        lane.filterCutoff = value
            case .filterResonance:     lane.filterResonance = value
            case .delayMix:            lane.delayMix = value
            case .delayTime:           lane.delayTime = value
            case .delayFeedback:       lane.delayFeedback = value
            case .bitCrushDepth:       lane.bitCrushDepth = value
            case .resonatorNote:       lane.resonatorNote = value
            case .resonatorDecay:      lane.resonatorDecay = value
            case .entropy:             lane.entropyLevel = value
            case .granularity:         lane.granularity = value
            case .shift:               lane.shift = value
            case .inputStrength:       lane.inputStrength = value
            case .inferenceSteps:      lane.inferenceSteps = Int(value.rounded())
            case .sineFrequency:       lane.sineFrequency = value
            case .pulseWidth:          lane.pulseWidth = value
            case .lfoRate:             lane.lfoRate = value
            case .lfoDepth:            lane.lfoDepth = value
            case .mute:
                lane.isMuted = value >= 0.5
                updateLaneMixerState()
            case .solo:
                lane.isSoloed = value >= 0.5
                updateLaneMixerState()
            case .spectralMorphActive: lane.spectralFreezeActive = value >= 0.5
            case .autoDecayToggle:     lane.autoDecayEnabled = value >= 0.5
            case .promptEvolution:     lane.promptEvolutionEnabled = value >= 0.5
            case .inferMethodSDE:      lane.inferMethod = value >= 0.5 ? "sde" : "ode"
            case .laneRecord:
                if value >= 0.5 && !lane.isLaneRecording {
                    lane.toggleLaneRecording()
                } else if value < 0.5 && lane.isLaneRecording {
                    lane.toggleLaneRecording()
                }
            case .archiveRecall:
                let idx = Int(value.rounded())
                lane.archiveRecallIndex = idx < lane.iterationArchive.count ? idx : nil
            default:
                break
            }
        }
    }

    /// Connect MIDI CC and OSC input to the focus lane and engine-global parameters.
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
        coreMLInference = CoreMLInference()
        configureOutputDevice()   // Set device to 48kHz BEFORE building graph
        setupProcessingFormat()
        setupMasterMixer()

        // H19: Pre-allocate ALL lane slots and attach to graph BEFORE engine starts.
        // This avoids any audioEngine.attach/connect calls after engine.start().
        // The audio graph is STATIC after this point.
        let defaultPreset = LanePreset.allPresets.first ?? .buchlaPerc
        for _ in 0..<LRConstants.maxLanes {
            let slot = ResonatorLane(preset: defaultPreset, bridge: aceBridge)
            slot.coreMLInference = coreMLInference
            slot.audioInputBuffer = audioInputBuffer
            slot.isMuted = true
            laneSlots.append(slot)

            // Attach to graph (STATIC -- never modified after this).
            // combinedSourceNode is set in ResonatorLane.init via setupCombinedSourceNode().
            guard let node = slot.combinedSourceNode else {
                fatalError("NeuralEngine: slot.combinedSourceNode nil before attach")
            }
            audioEngine.attach(node)
            audioEngine.attach(slot.laneMixer)
            audioEngine.connect(node, to: slot.laneMixer, format: effectiveFormat)
            audioEngine.connect(slot.laneMixer, to: masterMixerNode, format: effectiveFormat)
        }

        // IMPORTANT: Set volumes AFTER attach/connect. The connect() call resets
        // AVAudioMixerNode.outputVolume to 1.0, so we must set it after.
        for slot in laneSlots {
            slot.laneMixer.outputVolume = 0.0
        }

        // Activate the default lanes from the pool
        for i in 0..<LRConstants.defaultLaneCount {
            let slot = laneSlots[i]
            let preset = (i < LanePreset.allPresets.count)
                ? LanePreset.allPresets[i] : defaultPreset
            slot.reconfigure(with: preset)
            slot.isMuted = false
            slot.laneMixer.outputVolume = slot.volume
            lanes.append(slot)
        }

        // Performance state (Motherbase) -- load saved state or initialize defaults
        if let saved = PerformanceStateStore.load() {
            var bank = saved.sceneBank
            bank.ensureCapacity()
            sceneManager.sceneBank = bank
            for (i, lane) in lanes.enumerated() {
                if i < saved.stepGrids.count {
                    lane.stepGrid = saved.stepGrids[i]
                } else if !saved.stepGrids.isEmpty {
                    // Migration: legacy single grid -> copy to extra lanes
                    lane.stepGrid = saved.stepGrids[0]
                }
            }
            crossfaderSceneAIndex = saved.crossfaderSceneAIndex
            crossfaderSceneBIndex = saved.crossfaderSceneBIndex
        } else {
            var bank = sceneManager.sceneBank
            bank.ensureCapacity()
            sceneManager.sceneBank = bank
        }

        // Launch the Python ACE-Step bridge server process.
        bridgeProcess.launchServer()

        // Start MIDI input -- routes CC to focus lane parameters
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

        // Wire step grid advance to lane iteration changes (not SwiftUI onChange)
        sequencerEngine.subscribeLaneIterations()
        sequencerEngine.syncStepTimer()
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

    // MARK: - Performance State Persistence

    /// Save the current performance state (scenes, step grids per lane, crossfader) to disk.
    func savePerformanceState() {
        let snapshot = PerformanceStateSnapshot(
            sceneBank: sceneBank,
            stepGrids: lanes.map { $0.stepGrid },
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
    ///
    /// This is the standard approach used by professional DAWs. Without it,
    /// USB interfaces running at high rates (e.g. MOTU M2 @ 192kHz) may fail
    /// to activate their HAL IOProc when AVAudioEngine uses a lower internal
    /// rate -- resulting in silence even though the render graph runs correctly.
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

        // H21: Device rate is now set to 48kHz by configureOutputDevice(),
        // so the implicit mainMixerNode -> outputNode connection runs at
        // native 48kHz with ZERO sample-rate conversion. This eliminates
        // the HAL activation failure that plagued H6-H20 on the MOTU M2.
        _ = audioEngine.outputNode.outputFormat(forBus: 0)

        // Tap on master for recording
        masterMixerNode.installTap(
            onBus: 0,
            bufferSize: AVAudioFrameCount(LRConstants.bufferSize),
            format: effectiveFormat
        ) { [weak self] buffer, _ in
            self?.processMasterTap(buffer)
        }
    }

    // MARK: - Lane Management

    /// Add a new lane from a preset. Returns the new lane.
    ///
    /// H19: No graph modifications. Reuses a pre-allocated slot from the pool.
    /// Just reconfigures parameters and unmutes the slot.
    @discardableResult
    func addLane(preset: LanePreset) -> ResonatorLane {
        assert(Thread.isMainThread, "lanes must be mutated on main thread")
        guard lanes.count < LRConstants.maxLanes else {
            print(">> Neural Engine: Max lanes (\(LRConstants.maxLanes)) reached")
            return lanes.last ?? laneSlots[0]
        }

        // Find next available slot (one that's not in the active lanes array)
        let activeIDs = Set(lanes.map { $0.id })
        guard let slot = laneSlots.first(where: { !activeIDs.contains($0.id) }) else {
            print(">> Neural Engine: No available slots")
            return lanes.last ?? laneSlots[0]
        }

        // Reconfigure the slot with the new preset
        slot.reconfigure(with: preset)
        slot.isMuted = false
        slot.laneMixer.outputVolume = slot.volume
        lanes.append(slot)

        // Sync scene bank: new lane gets its own fresh snapshot, not another lane's (Ley 4)
        sceneManager.appendLaneSnapshotToAllScenes(slot.makeSnapshot())

        // If engine is already running, start the lane's inference loop
        if isProcessing {
            if slot.excitationMode == .audioInput && !inputTapInstalled {
                audioEngine.stop()
                updateAudioInputTap()
                audioEngine.prepare()
                try? audioEngine.start()
            }
            slot.installCaptureTap()
            slot.startInferenceLoop()
        }

        print(">> Neural Engine: Added lane '\(slot.name)' (total: \(lanes.count))")
        sequencerEngine.subscribeLaneIterations()

        return slot
    }

    /// Remove a lane by its ID.
    ///
    /// H19: No graph modifications. Just mutes the slot and returns it to the pool.
    func removeLane(id: UUID) {
        assert(Thread.isMainThread, "lanes must be mutated on main thread")
        guard let index = lanes.firstIndex(where: { $0.id == id }) else { return }
        let lane = lanes[index]

        // Stop lane inference and mute
        lane.stopInferenceLoop()
        lane.removeCaptureTap()
        lane.isMuted = true
        lane.laneMixer.outputVolume = 0.0
        lane.resetState()

        lanes.remove(at: index)

        // Sync scene bank: remove this lane's snapshot so indices stay aligned (Ley 4)
        sceneManager.removeLaneSnapshotFromAllScenes(at: index)

        print(">> Neural Engine: Removed lane '\(lane.name)' (total: \(lanes.count))")
        sequencerEngine.subscribeLaneIterations()
        updateLaneMixerState()
    }

    /// Reorder lanes (for UI drag).
    func moveLane(from source: IndexSet, to destination: Int) {
        assert(Thread.isMainThread, "lanes must be mutated on main thread")
        lanes.move(fromOffsets: source, toOffset: destination)
    }

    // MARK: - Audio Graph
    //
    // H19: The audio graph is STATIC. All lane slots are pre-allocated and
    // connected in init(). No attach/connect/stop/start calls ever happen
    // after the initial engine.start(). "Adding" a lane just unmutes a slot.
    // "Removing" a lane just mutes it. This prevents HAL disruption on
    // 192kHz hardware (MOTU M2).

    /// Apply volume, mute, and solo logic to all lane mixers.
    /// Called by the UI whenever a lane's volume/mute/solo state changes.
    func updateLaneMixerState() {
        let anySoloed = lanes.contains(where: { $0.isSoloed })

        for lane in lanes {
            if lane.isMuted {
                lane.laneMixer.outputVolume = 0.0
            } else if anySoloed {
                // When any lane is soloed, only soloed lanes play
                lane.laneMixer.outputVolume = lane.isSoloed ? lane.volume : 0.0
            } else {
                lane.laneMixer.outputVolume = lane.volume
            }
        }
    }

    // MARK: - Performance (Scenes, Crossfade, Step Grid)

    /// Apply scene at index immediately (no crossfade).
    func applyScene(at index: Int) {
        sceneManager.applyScene(at: index, lanes: lanes)
        updateFeedbackRouting()
        updateLaneMixerState()
    }

    /// Capture focus lane's current parameters into step at index.
    /// Lets you record live tweaks (XY pad, knobs) into the sequencer.
    /// Per-lane: only the focused lane's step grid is modified.
    func captureCurrentToStep(at index: Int) {
        guard let lane = focusLane else { return }
        guard index >= 0, index < lane.stepGrid.steps.count else { return }
        let existing = lane.stepGrid.step(at: index) ?? PerformanceStep()
        let step = PerformanceStep(
            trigType: existing.trigType,
            probability: existing.probability,
            cfg: lane.guidanceScale,
            feedback: lane.feedbackAmount,
            promptPhase: lane.promptPhaseOverride,
            denoiseStrength: lane.denoiseStrengthDefault,
            texture: lane.texture,
            chaos: lane.chaos,
            warmth: lane.warmth,
            filterCutoff: lane.filterCutoff,
            filterResonance: lane.filterResonance,
            excitationMode: lane.excitationMode.rawValue,
            delayMix: lane.delayMix,
            bitCrushDepth: lane.bitCrushDepth,
            drumVoice: existing.drumVoice,
            microtiming: existing.microtiming
        )
        lane.stepGrid.setStep(step, at: index)
    }

    /// When entering Perform from Setup, sync current lane state into Scene A and B
    /// if they are empty. Ensures Setup tweaks (volume, effects, etc.) carry to live.
    func syncSetupToScenesOnEnterPerform() {
        sceneManager.syncSetupToScenesOnEnterPerform(
            sceneAIndex: crossfaderSceneAIndex,
            sceneBIndex: crossfaderSceneBIndex,
            lanes: lanes
        )
    }

    /// Capture current lane state into scene at index.
    func captureCurrentToScene(at index: Int) {
        sceneManager.captureCurrentToScene(at: index, lanes: lanes)
    }

    // MARK: - Step Grid Wiring (Delegated to SequencerEngine)

    /// Start or stop the step timer based on the focus lane's advance mode.
    func syncStepTimer() {
        sequencerEngine.syncStepTimer()
    }

    /// Manual step advance for one lane (tap or keyboard).
    func advanceLaneManually(lane: ResonatorLane) {
        sequencerEngine.advanceLaneManually(lane: lane)
    }

    /// Apply current step's parameter locks to one lane only (per-lane independence).
    func applyLaneStepLocks(lane: ResonatorLane) {
        let grid = lane.stepGrid
        guard let step = grid.step(at: grid.currentStepIndex) else { return }

        // -- Inference locks --
        if let v = step.cfg {
            lane.guidanceScale = min(max(v, LRConstants.cfgScaleRange.lowerBound), LRConstants.cfgScaleRange.upperBound)
        }
        if let v = step.feedback {
            lane.feedbackAmount = min(max(v, 0), 1)
        }
        if let phase = step.promptPhase {
            lane.promptPhaseOverride = min(max(phase, 1), 3)
        }
        if let dv = step.drumVoice {
            lane.promptOverride = dv.prompt
        } else {
            lane.promptOverride = nil
        }

        // -- DSP / macro locks (clamped to each parameter's native range) --
        if let v = step.texture       { lane.texture = min(max(v, 0), 1) }
        if let v = step.chaos         { lane.chaos = min(max(v, 0), 1) }
        if let v = step.warmth        { lane.warmth = min(max(v, 0), 1) }
        if let v = step.filterCutoff  {
            lane.filterCutoff = min(max(v, LRConstants.filterCutoffRange.lowerBound),
                                    LRConstants.filterCutoffRange.upperBound)
        }
        if let v = step.filterResonance {
            lane.filterResonance = min(max(v, LRConstants.filterResonanceRange.lowerBound),
                                       LRConstants.filterResonanceRange.upperBound)
        }
        if let v = step.excitationMode,
           let mode = ExcitationMode(rawValue: v) {
            lane.excitationMode = mode
        }
        if let v = step.delayMix      { lane.delayMix = min(max(v, 0), 1) }
        if let v = step.bitCrushDepth {
            lane.bitCrushDepth = min(max(v, LRConstants.bitCrushRange.lowerBound),
                                     LRConstants.bitCrushRange.upperBound)
        }

        // -- Trig behavior --
        if step.trigType == .lock {
            lane.dspOnlyForNextCycle = true
        }

        let effectiveDenoise: Float = {
            if step.trigType == .lock { return 0 }
            if let s = step.denoiseStrength { return min(max(s, 0), 1) }
            return min(max(lane.denoiseStrengthDefault, 0), 1)
        }()
        lane.denoiseStrengthForInference = effectiveDenoise
    }

    // MARK: - Step Lock API (Sequencer v2)
    //
    // All step mutations operate on the focus lane's step grid only.

    /// Set a single Float? lock on a step via KeyPath.
    func setStepLock(at index: Int, _ keyPath: WritableKeyPath<PerformanceStep, Float?>, value: Float?) {
        guard let lane = focusLane else { return }
        guard index >= 0, index < lane.stepGrid.steps.count else { return }
        lane.stepGrid.steps[index][keyPath: keyPath] = value
    }

    /// Set a Float? lock on all selected steps. Used when drift pad is moved with 2+ steps selected.
    func setStepLockForSelected(_ keyPath: WritableKeyPath<PerformanceStep, Float?>, value: Float?) {
        guard let lane = focusLane else { return }
        for idx in selectedStepIndices {
            guard idx >= 0, idx < lane.stepGrid.steps.count else { continue }
            lane.stepGrid.steps[idx][keyPath: keyPath] = value
        }
    }

    /// Set trig type for a step.
    func setStepTrigType(at index: Int, _ type: TrigType) {
        guard let lane = focusLane else { return }
        guard index >= 0, index < lane.stepGrid.steps.count else { return }
        lane.stepGrid.steps[index].trigType = type
    }

    /// Set prompt phase lock for a step (Int?, not Float).
    func setStepPromptPhase(at index: Int, phase: Int?) {
        guard let lane = focusLane else { return }
        guard index >= 0, index < lane.stepGrid.steps.count else { return }
        lane.stepGrid.steps[index].promptPhase = phase
    }

    /// Set DrumVoice lock for a step (Drum Lane P-Lock §0).
    func setStepDrumVoice(at index: Int, voice: DrumVoice?) {
        guard let lane = focusLane else { return }
        guard index >= 0, index < lane.stepGrid.steps.count else { return }
        var grid = lane.stepGrid
        grid.steps[index].drumVoice = voice
        lane.stepGrid = grid
    }

    /// Set probability gate for a step (nil = always fire).
    func setStepProbability(at index: Int, probability: Float?) {
        guard let lane = focusLane else { return }
        guard index >= 0, index < lane.stepGrid.steps.count else { return }
        lane.stepGrid.steps[index].probability = probability
    }

    /// Set per-step microtiming offset (-0.5...0.5). Negative = early, positive = late.
    func setStepMicrotiming(at index: Int, microtiming: Double) {
        guard let lane = focusLane else { return }
        guard index >= 0, index < lane.stepGrid.steps.count else { return }
        var step = lane.stepGrid.step(at: index) ?? PerformanceStep()
        step.microtiming = microtiming
        var grid = lane.stepGrid
        grid.setStep(step, at: index)
        lane.stepGrid = grid
    }

    /// Clear all locks on a step (reset to default note trig).
    func clearStep(at index: Int) {
        guard let lane = focusLane else { return }
        guard index >= 0, index < lane.stepGrid.steps.count else { return }
        var grid = lane.stepGrid
        grid.steps[index] = PerformanceStep()
        lane.stepGrid = grid
    }

    // MARK: - Multi-Select & Batch Operations (Shift+click)

    /// Handle step pad tap. Shift+click toggles multi-select; plain tap selects single. Tap same step again to close.
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
        guard let lane = focusLane else { return }
        for idx in selectedStepIndices {
            guard idx >= 0, idx < lane.stepGrid.steps.count else { continue }
            setStepTrigType(at: idx, type)
        }
    }

    /// Apply DrumVoice to all selected steps.
    func applyDrumVoiceToSelected(_ voice: DrumVoice?) {
        guard let lane = focusLane else { return }
        for idx in selectedStepIndices {
            guard idx >= 0, idx < lane.stepGrid.steps.count else { continue }
            setStepDrumVoice(at: idx, voice: voice)
        }
    }

    /// Clear all selected steps.
    func clearSelectedSteps() {
        guard let lane = focusLane else { return }
        for idx in selectedStepIndices {
            guard idx >= 0, idx < lane.stepGrid.steps.count else { continue }
            clearStep(at: idx)
        }
    }

    /// Apply crossfader blend between scene A and B (position 0 = A, 1 = B).
    func applyCrossfader() {
        sceneManager.applyCrossfader(
            sceneAIndex: crossfaderSceneAIndex,
            sceneBIndex: crossfaderSceneBIndex,
            t: crossfaderPosition,
            lanes: lanes
        )
        updateLaneMixerState()
    }

    // MARK: - Processing Control

    /// - Parameter initiatedFromPerformMode: True when START was pressed in Perform view.
    ///   Used so returning from Setup to Perform doesn't stop (no warning).
    func toggleProcessing(initiatedFromPerformMode: Bool = false) {
        if isProcessing {
            // Debounce: ignore stop for 3s after start so first inference isn't killed by accidental tap
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
        do {
            let needsAudioInput = lanes.contains { $0.excitationMode == .audioInput }
            if needsAudioInput {
                updateAudioInputTap()
            }

            audioEngine.prepare()
            try audioEngine.start()
            isProcessing = true
            processingStartedInPerformMode = initiatedFromPerformMode

            // Start all lane inference loops + taps
            for lane in lanes {
                lane.installCaptureTap()
                lane.startInferenceLoop()
            }

            lastStartTime = Date()
            canAbort = false
            DispatchQueue.main.asyncAfter(deadline: .now() + startDebounceInterval) { [weak self] in
                self?.canAbort = true
            }
            sequencerEngine.syncStepTimer()
            for lane in lanes {
                applyLaneStepLocks(lane: lane)
            }
            let laneNames = lanes.map { $0.name }.joined(separator: ", ")
            print(">> Neural Engine: Multi-lane loop INITIATED -- lanes: [\(laneNames)]")

        } catch {
            print(">> Neural Engine: Failed to start -- \(error.localizedDescription)")
        }
    }

    /// Stop all processing -- inference loops, capture taps, audio engine.
    ///
    /// Teardown order avoids double free (malloc crash when STOP during inference):
    /// 1. Cancel inference tasks.
    /// 2. Stop audio engine first — halts tap callbacks before removal.
    /// 3. Remove taps (engine stopped → no in-flight callback).
    /// 4. Reset lane state.
    func stopProcessing() {
        guard isProcessing else { return }

        processingStartedInPerformMode = false

        // 1. Cancel inference loops
        for lane in lanes {
            lane.stopInferenceLoop()
        }
        sequencerEngine.cancelStepTimer()

        // 2. Stop engine first — prevents tap callback from racing with tap removal
        audioEngine.stop()

        // 3. Remove taps
        for lane in lanes {
            lane.removeCaptureTap()
        }
        removeAudioInputTap()

        // 4. Reset lane state
        for lane in lanes {
            lane.resetState()
        }

        isProcessing = false
        print(">> Neural Engine: All lanes ABORTED -- state reset")
    }

    // MARK: - Audio Input Tap (Shared Buffer for .audioInput Excitation)

    /// Install an input tap on the audio engine's input node to feed
    /// the shared audioInputBuffer. The tap writes mono samples into
    /// the ring buffer; lanes configured as .audioInput read from it.
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

    // MARK: - Cross-Lane Feedback Routing

    /// Resolve each lane's feedbackSourceLaneId to a concrete buffer pointer.
    /// Called after scene recall or whenever the user changes routing.
    func updateFeedbackRouting() {
        for lane in lanes {
            if let srcId = lane.feedbackSourceLaneId,
               let srcLane = lanes.first(where: { $0.id == srcId }), srcLane.id != lane.id {
                lane.externalFeedbackBuffer = srcLane.feedbackBuffer
            } else {
                lane.externalFeedbackBuffer = nil
            }
        }
    }

    // MARK: - Master Recording Control (§5)

    /// Toggle master bus recording on/off.
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
            // Export metadata sidecar with aggregate state
            let totalCycles = lanes.reduce(0) { $0 + $1.iterationCount }
            let laneNames = lanes.map { $0.name }
            let allFeatures = lanes.flatMap { $0.featureLog }
            AudioRecorder.exportMetadata(
                recordingURL: url,
                iterationCount: totalCycles,
                laneName: "MASTER",
                parameters: [
                    "activeLanes": laneNames,
                    "laneCount": lanes.count
                ],
                featureLog: allFeatures
            )
        } else {
            isMasterRecording = false
        }
    }

    // MARK: - Master Audio Tap (Recording)

    private func processMasterTap(_ buffer: AVAudioPCMBuffer) {
        masterRecorder.writeBuffer(buffer)
    }

}
