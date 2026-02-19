import Foundation
import SwiftUI
import AVFoundation
import CoreAudio
import Combine
import Accelerate

// MARK: - Audio Recorder
//
// Writes AVAudioPCMBuffer data to a WAV file on disk.
// Used at two levels:
//   1. Per-lane: captures the isolated output of a single ResonatorLane
//      (for studying one latent trajectory in isolation -- §5.1-5.4).
//   2. Master bus: captures the mixed output (final performance artifact).
//
// Thread safety: writeBuffer() dispatches writes to a serial queue
// so it can be called from audio tap callbacks or inference threads.

final class AudioRecorder {

    private var audioFile: AVAudioFile?
    private(set) var isRecording: Bool = false
    private(set) var recordingURL: URL?
    private let recordingQueue = DispatchQueue(
        label: "com.latentresonator.recorder",
        qos: .utility
    )

    /// Output directory for all Latent Resonator recordings.
    static var outputDirectory: URL {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            fatalError("Could not locate user Documents directory")
        }
        return docs.appendingPathComponent(LRConstants.recordingDirectoryName, isDirectory: true)
    }

    /// Start recording to a WAV file.
    ///
    /// - Parameters:
    ///   - name: Identifier for the recording (e.g. lane name or "MASTER")
    ///   - format: Audio format matching the tap output
    /// - Returns: File URL of the new recording
    func startRecording(name: String, format: AVAudioFormat) throws -> URL {
        let dir = Self.outputDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let filename = "\(LRConstants.recordingFilePrefix)\(name)_\(timestamp).wav"
        let url = dir.appendingPathComponent(filename)

        audioFile = try AVAudioFile(forWriting: url, settings: format.settings)
        recordingURL = url
        isRecording = true
        print(">> AudioRecorder: Recording started -> \(filename)")
        return url
    }

    /// Append a buffer to the active recording. Thread-safe.
    func writeBuffer(_ buffer: AVAudioPCMBuffer) {
        guard isRecording, let file = audioFile else { return }
        recordingQueue.async {
            do {
                try file.write(from: buffer)
            } catch {
                print(">> AudioRecorder: write error -- \(error.localizedDescription)")
            }
        }
    }

    /// Stop recording and return the file URL.
    @discardableResult
    func stopRecording() -> URL? {
        guard isRecording else { return nil }
        isRecording = false
        let url = recordingURL
        audioFile = nil
        recordingURL = nil
        if let url = url {
            print(">> AudioRecorder: Recording stopped -> \(url.lastPathComponent)")
        }
        return url
    }

    /// Export a metadata sidecar JSON alongside a recording file.
    ///
    /// Enables Section 5 analysis: maps iteration N to sonic characteristics.
    static func exportMetadata(
        recordingURL: URL,
        iterationCount: Int,
        laneName: String,
        parameters: [String: Any],
        featureLog: [SpectralFeatureSnapshot] = []
    ) {
        let meta: [String: Any] = [
            "lane": laneName,
            "iterationCount": iterationCount,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "sampleRate": LRConstants.sampleRate,
            "parameters": parameters
        ]

        let sidecarURL = recordingURL
            .deletingPathExtension()
            .appendingPathExtension("json")

        if let data = try? JSONSerialization.data(withJSONObject: meta, options: .prettyPrinted) {
            try? data.write(to: sidecarURL)
            print(">> AudioRecorder: Metadata exported -> \(sidecarURL.lastPathComponent)")
        }

        // Export spectral feature telemetry as a separate CSV for analysis tools
        if !featureLog.isEmpty {
            let csvURL = recordingURL
                .deletingPathExtension()
                .appendingPathExtension("features.csv")
            var csv = "iteration,centroid,flatness,flux,promptPhase,inputStrength,timestamp\n"
            for s in featureLog {
                csv += "\(s.iteration),\(s.centroid),\(s.flatness),\(s.flux),\(s.promptPhase),\(s.inputStrength),\(s.timestamp)\n"
            }
            try? csv.write(to: csvURL, atomically: true, encoding: .utf8)
            print(">> AudioRecorder: Feature log exported -> \(csvURL.lastPathComponent)")
        }
    }
}

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

    @Published var sceneBank: SceneBank = SceneBank()
    @Published var pLockEditingStepIndex: Int? = nil
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

    private var processingFormat: AVAudioFormat!

    // MARK: - Lifecycle

    private var cancellables = Set<AnyCancellable>()
    private var laneIterationCancellables = Set<AnyCancellable>()

    // MARK: - MIDI Routing Setup

    /// Shared routing logic for both MIDI CC and OSC input.
    private func applyParameter(_ param: ControlParameter, value: Float) {
        let lane: ResonatorLane? = (param == .crossfader) ? nil : focusLane
        guard param == .crossfader || lane != nil else { return }

        switch param {
        case .volume:              lane!.volume = value
        case .guidanceScale:       lane!.guidanceScale = value
        case .feedback:            lane!.feedbackAmount = value
        case .texture:             lane!.texture = value
        case .chaos:               lane!.chaos = value
        case .warmth:              lane!.warmth = value
        case .filterCutoff:        lane!.filterCutoff = value
        case .filterResonance:     lane!.filterResonance = value
        case .delayMix:            lane!.delayMix = value
        case .delayTime:           lane!.delayTime = value
        case .delayFeedback:       lane!.delayFeedback = value
        case .bitCrushDepth:       lane!.bitCrushDepth = value
        case .resonatorNote:       lane!.resonatorNote = value
        case .resonatorDecay:      lane!.resonatorDecay = value
        case .entropy:             lane!.entropyLevel = value
        case .granularity:         lane!.granularity = value
        case .shift:               lane!.shift = value
        case .inputStrength:       lane!.inputStrength = value
        case .inferenceSteps:      lane!.inferenceSteps = Int(value.rounded())
        case .sineFrequency:       lane!.sineFrequency = value
        case .pulseWidth:          lane!.pulseWidth = value
        case .lfoRate:             lane!.lfoRate = value
        case .lfoDepth:            lane!.lfoDepth = value
        case .crossfader:
            crossfaderPosition = value
            applyCrossfader()
        case .mute:
            lane!.isMuted = value >= 0.5
            updateLaneMixerState()
        case .solo:
            lane!.isSoloed = value >= 0.5
            updateLaneMixerState()
        case .spectralMorphActive: lane!.spectralFreezeActive = value >= 0.5
        case .autoDecayToggle:     lane!.autoDecayEnabled = value >= 0.5
        case .promptEvolution:     lane!.promptEvolutionEnabled = value >= 0.5
        case .inferMethodSDE:      lane!.inferMethod = value >= 0.5 ? "sde" : "ode"
        case .laneRecord:
            if value >= 0.5 && !lane!.isLaneRecording { lane!.toggleLaneRecording() }
            else if value < 0.5 && lane!.isLaneRecording { lane!.toggleLaneRecording() }
        case .archiveRecall:
            let idx = Int(value.rounded())
            lane!.archiveRecallIndex = idx < lane!.iterationArchive.count ? idx : nil
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

            // Attach to graph (STATIC -- never modified after this)
            audioEngine.attach(slot.combinedSourceNode)
            audioEngine.attach(slot.laneMixer)
            audioEngine.connect(slot.combinedSourceNode, to: slot.laneMixer, format: processingFormat)
            audioEngine.connect(slot.laneMixer, to: masterMixerNode, format: processingFormat)
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
            sceneBank = saved.sceneBank
            sceneBank.ensureCapacity()
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
            var bank = sceneBank
            bank.ensureCapacity()
            sceneBank = bank
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

        // Wire step grid advance to lane iteration changes (not SwiftUI onChange)
        subscribeLaneIterations()
        syncStepTimer()
    }

    deinit {
        stepTimer?.cancel()
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
        audioEngine.connect(masterMixerNode, to: audioEngine.mainMixerNode, format: processingFormat)

        // H21: Device rate is now set to 48kHz by configureOutputDevice(),
        // so the implicit mainMixerNode -> outputNode connection runs at
        // native 48kHz with ZERO sample-rate conversion. This eliminates
        // the HAL activation failure that plagued H6-H20 on the MOTU M2.
        _ = audioEngine.outputNode.outputFormat(forBus: 0)

        // Tap on master for recording
        masterMixerNode.installTap(
            onBus: 0,
            bufferSize: AVAudioFrameCount(LRConstants.bufferSize),
            format: processingFormat
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
        guard lanes.count < LRConstants.maxLanes else {
            print(">> Neural Engine: Max lanes (\(LRConstants.maxLanes)) reached")
            guard let last = lanes.last else {
                fatalError("Invariant violation: lanes array is empty after addLane guard")
            }
            return last
        }

        // Find next available slot (one that's not in the active lanes array)
        let activeIDs = Set(lanes.map { $0.id })
        guard let slot = laneSlots.first(where: { !activeIDs.contains($0.id) }) else {
            print(">> Neural Engine: No available slots")
            guard let last = lanes.last else {
                fatalError("Invariant violation: lanes array is empty with no available slots")
            }
            return last
        }

        // Reconfigure the slot with the new preset
        slot.reconfigure(with: preset)
        slot.isMuted = false
        slot.laneMixer.outputVolume = slot.volume
        lanes.append(slot)

        // Sync scene bank: new lane gets its own fresh snapshot, not another lane's (Ley 4)
        var bank = sceneBank
        let freshSnapshot = slot.makeSnapshot()
        for i in bank.scenes.indices {
            while bank.scenes[i].laneSnapshots.count < lanes.count {
                bank.scenes[i].laneSnapshots.append(freshSnapshot)
            }
        }
        sceneBank = bank

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
        subscribeLaneIterations()

        return slot
    }

    /// Remove a lane by its ID.
    ///
    /// H19: No graph modifications. Just mutes the slot and returns it to the pool.
    func removeLane(id: UUID) {
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
        var bank = sceneBank
        for i in bank.scenes.indices {
            if index < bank.scenes[i].laneSnapshots.count {
                bank.scenes[i].laneSnapshots.remove(at: index)
            }
            // Clear or decrement feedbackSourceLaneIndex pointing to removed lane
            for j in bank.scenes[i].laneSnapshots.indices {
                var snap = bank.scenes[i].laneSnapshots[j]
                if let src = snap.feedbackSourceLaneIndex {
                    if src == index {
                        snap.feedbackSourceLaneIndex = nil
                    } else if src > index {
                        snap.feedbackSourceLaneIndex = src - 1
                    }
                    bank.scenes[i].laneSnapshots[j] = snap
                }
            }
        }
        sceneBank = bank

        print(">> Neural Engine: Removed lane '\(lane.name)' (total: \(lanes.count))")
        subscribeLaneIterations()
        updateLaneMixerState()
    }

    /// Reorder lanes (for UI drag).
    func moveLane(from source: IndexSet, to destination: Int) {
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
        guard index >= 0, index < sceneBank.scenes.count else { return }
        let scene = sceneBank.scenes[index]
        for (i, lane) in lanes.enumerated() {
            if i < scene.laneSnapshots.count {
                lane.applySnapshot(scene.laneSnapshots[i])
                // Restore cross-lane feedback from stored index
                if let srcIdx = scene.laneSnapshots[i].feedbackSourceLaneIndex,
                   srcIdx >= 0, srcIdx < lanes.count {
                    lane.feedbackSourceLaneId = lanes[srcIdx].id
                } else {
                    lane.feedbackSourceLaneId = nil
                }
            }
        }
        updateFeedbackRouting()
        sceneBank.currentSceneIndex = index
        updateLaneMixerState()
    }

    private func blendLaneSnapshot(start: LaneSnapshot, end: LaneSnapshot, t: Float) -> LaneSnapshot {
        func lerp(_ a: Float, _ b: Float) -> Float { a + (b - a) * t }
        return LaneSnapshot(
            volume: lerp(start.volume, end.volume),
            isMuted: t < 0.5 ? start.isMuted : end.isMuted,
            isSoloed: t < 0.5 ? start.isSoloed : end.isSoloed,
            texture: lerp(start.texture, end.texture),
            chaos: lerp(start.chaos, end.chaos),
            warmth: lerp(start.warmth, end.warmth),
            guidanceScale: lerp(start.guidanceScale, end.guidanceScale),
            feedbackAmount: lerp(start.feedbackAmount, end.feedbackAmount),
            inputStrength: lerp(start.inputStrength, end.inputStrength),
            promptPhaseIndex: t < 0.5 ? start.promptPhaseIndex : end.promptPhaseIndex,
            excitationModeRaw: t < 0.5 ? start.excitationModeRaw : end.excitationModeRaw,
            entropyLevel: lerp(start.entropyLevel, end.entropyLevel),
            granularity: lerp(start.granularity, end.granularity),
            delayTime: lerp(start.delayTime, end.delayTime),
            delayFeedback: lerp(start.delayFeedback, end.delayFeedback),
            delayMix: lerp(start.delayMix, end.delayMix),
            bitCrushDepth: lerp(start.bitCrushDepth, end.bitCrushDepth),
            resonatorNote: lerp(start.resonatorNote, end.resonatorNote),
            resonatorDecay: lerp(start.resonatorDecay, end.resonatorDecay),
            filterCutoff: lerp(start.filterCutoff, end.filterCutoff),
            filterResonance: lerp(start.filterResonance, end.filterResonance),
            filterModeRaw: t < 0.5 ? start.filterModeRaw : end.filterModeRaw,
            saturationModeRaw: t < 0.5 ? start.saturationModeRaw : end.saturationModeRaw,
            spectralFreezeActive: t < 0.5 ? start.spectralFreezeActive : end.spectralFreezeActive,
            denoiseStrength: lerp(start.denoiseStrength ?? 1.0, end.denoiseStrength ?? 1.0),
            autoDecayEnabled: t < 0.5 ? start.autoDecayEnabled : end.autoDecayEnabled,
            feedbackSourceLaneIndex: t < 0.5 ? start.feedbackSourceLaneIndex : end.feedbackSourceLaneIndex,
            archiveRecallIndex: t < 0.5 ? start.archiveRecallIndex : end.archiveRecallIndex,
            saturationMorph: lerp(start.saturationMorph ?? 0.0, end.saturationMorph ?? 0.0)
        )
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
            microtiming: existing.microtiming
        )
        lane.stepGrid.setStep(step, at: index)
    }

    /// Capture current lane state into scene at index.
    func captureCurrentToScene(at index: Int) {
        guard index >= 0, index < sceneBank.scenes.count else { return }
        var snapshots: [LaneSnapshot] = []
        for (_, lane) in lanes.enumerated() {
            var snap = lane.makeSnapshot()
            // Resolve cross-lane feedback UUID -> index for serialization
            if let srcId = lane.feedbackSourceLaneId,
               let srcIdx = lanes.firstIndex(where: { $0.id == srcId }) {
                snap.feedbackSourceLaneIndex = srcIdx
            }
            snapshots.append(snap)
        }
        var bank = sceneBank
        while bank.scenes.count <= index {
            bank.scenes.append(PerformanceScene(name: "Scene \(bank.scenes.count + 1)", laneSnapshots: []))
        }
        bank.scenes[index] = PerformanceScene(name: bank.scenes[index].name, laneSnapshots: snapshots)
        bank.currentSceneIndex = index
        sceneBank = bank
    }

    // MARK: - Step Grid Wiring

    /// High-priority timer for `.time` advance mode (beat-clock driven).
    /// Uses DispatchSourceTimer instead of RunLoop Timer for sub-ms jitter.
    private var stepTimer: DispatchSourceTimer?
    private let stepTimerQueue = DispatchQueue(label: "com.latentresonator.stepTimer", qos: .userInteractive)

    /// Subscribe to each active lane's iteration count so step advance fires
    /// per-lane. Each lane advances its own step grid independently (polirhythm).
    func subscribeLaneIterations() {
        laneIterationCancellables.removeAll()
        for lane in lanes {
            lane.$iterationCount
                .dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] newCount in
                    guard newCount > 0 else { return }
                    self?.advanceLaneStep(lane: lane)
                }
                .store(in: &laneIterationCancellables)
        }
    }

    /// Start or stop the step timer based on the focus lane's advance mode.
    /// Uses focus lane's BPM; when timer fires, advances all lanes.
    func syncStepTimer() {
        stepTimer?.cancel()
        stepTimer = nil

        guard let grid = focusStepGrid, grid.advanceMode == .time else { return }

        let bpm = Double(grid.stepTimeBPM)
        let intervalNs = UInt64((60.0 / bpm) * 1_000_000_000)
        print(">> StepTimer: Starting at \(bpm) BPM (interval: \(String(format: "%.2f", 60.0 / bpm))s)")

        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: stepTimerQueue)
        timer.schedule(deadline: .now() + .nanoseconds(Int(intervalNs)),
                       repeating: .nanoseconds(Int(intervalNs)),
                       leeway: .microseconds(500))
        timer.setEventHandler { [weak self] in
            guard let self = self, self.isProcessing else { return }
            DispatchQueue.main.async {
                self.advanceAllLanesSteps()
            }
        }
        timer.resume()
        stepTimer = timer
    }

    /// Advance one lane's step grid (iteration-based). Per-lane: each lane advances
    /// based on its own iteration count, enabling polirhythm.
    func advanceLaneStep(lane: ResonatorLane) {
        let grid = lane.stepGrid
        guard grid.advanceMode == .iteration else { return }
        let total = lane.iterationCount
        let chain = grid.chainLength
        guard chain > 0 else { return }

        let candidateIndex = (total / grid.stepAdvanceDivisor) % chain
        guard candidateIndex != grid.currentStepIndex else { return }

        advanceLaneToStep(lane: lane, candidateIndex: candidateIndex)
    }

    /// Common step-advance logic for one lane. Applies that lane's step locks to that lane only.
    private func advanceLaneToStep(lane: ResonatorLane, candidateIndex: Int) {
        var grid = lane.stepGrid
        let chain = grid.chainLength
        guard chain > 0, candidateIndex >= 0, candidateIndex < chain else { return }
        guard candidateIndex != grid.currentStepIndex else { return }

        let previousIndex = grid.currentStepIndex

        grid.currentStepIndex = candidateIndex

        if candidateIndex < previousIndex {
            grid.oneShotFired.removeAll()
        }

        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            lane.stepGrid = grid
        }

        guard let step = grid.step(at: candidateIndex) else { return }

        if step.trigType == .skip { return }
        if step.trigType == .oneShot && grid.oneShotFired.contains(candidateIndex) { return }

        if let prob = step.probability, prob < 1.0 {
            if Float.random(in: 0...1) > prob { return }
        }

        applyLaneStepLocks(lane: lane)

        if step.trigType == .oneShot {
            var g = lane.stepGrid
            g.oneShotFired.insert(candidateIndex)
            lane.stepGrid = g
        }
    }

    /// Step advance for `.time` mode -- advances all lanes to next step.
    private func advanceAllLanesSteps() {
        for lane in lanes {
            let grid = lane.stepGrid
            let chain = grid.chainLength
            guard chain > 0 else { continue }
            let next = (grid.currentStepIndex + 1) % chain

            if let step = grid.step(at: next), abs(step.microtiming) > 0.001,
               let focusGrid = focusStepGrid, focusGrid.advanceMode == .time {
                let bpm = Double(focusGrid.stepTimeBPM)
                let stepInterval = 60.0 / bpm
                let offsetSeconds = step.microtiming * stepInterval
                let delayNs = max(0, Int(offsetSeconds * 1_000_000_000))
                stepTimerQueue.asyncAfter(deadline: .now() + .nanoseconds(delayNs)) { [weak self] in
                    DispatchQueue.main.async {
                        self?.advanceLaneToStep(lane: lane, candidateIndex: next)
                    }
                }
            } else {
                advanceLaneToStep(lane: lane, candidateIndex: next)
            }
        }
    }

    /// Manual step advance for one lane (tap or keyboard). Advances to next step and applies locks.
    func advanceLaneManually(lane: ResonatorLane) {
        let chain = lane.stepGrid.chainLength
        guard chain > 0 else { return }
        let next = (lane.stepGrid.currentStepIndex + 1) % chain
        advanceLaneToStep(lane: lane, candidateIndex: next)
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

    /// Set probability gate for a step (nil = always fire).
    func setStepProbability(at index: Int, probability: Float?) {
        guard let lane = focusLane else { return }
        guard index >= 0, index < lane.stepGrid.steps.count else { return }
        lane.stepGrid.steps[index].probability = probability
    }

    /// Clear all locks on a step (reset to default note trig).
    func clearStep(at index: Int) {
        guard let lane = focusLane else { return }
        guard index >= 0, index < lane.stepGrid.steps.count else { return }
        lane.stepGrid.steps[index] = PerformanceStep()
    }

    /// Apply crossfader blend between scene A and B (position 0 = A, 1 = B).
    func applyCrossfader() {
        let a = crossfaderSceneAIndex
        let b = crossfaderSceneBIndex
        guard a >= 0, a < sceneBank.scenes.count, b >= 0, b < sceneBank.scenes.count else { return }
        let t = min(max(crossfaderPosition, 0), 1)
        let sceneA = sceneBank.scenes[a]
        let sceneB = sceneBank.scenes[b]
        for (i, lane) in lanes.enumerated() {
            let startSnap = i < sceneA.laneSnapshots.count ? sceneA.laneSnapshots[i] : lane.makeSnapshot()
            let endSnap = i < sceneB.laneSnapshots.count ? sceneB.laneSnapshots[i] : startSnap
            lane.applySnapshot(blendLaneSnapshot(start: startSnap, end: endSnap, t: t))
        }
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
            syncStepTimer()
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
    func stopProcessing() {
        guard isProcessing else { return }

        processingStartedInPerformMode = false

        // Stop all lane inference loops
        for lane in lanes {
            lane.stopInferenceLoop()
            lane.removeCaptureTap()
            lane.resetState()
        }

        removeAudioInputTap()
        audioEngine.stop()
        isProcessing = false
        stepTimer?.cancel()
        stepTimer = nil
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
        guard let format = processingFormat else { return }
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
