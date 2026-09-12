import Foundation
import Combine
import SwiftUI

// MARK: - Step Output

/// Output from a sequencer step advance, containing gate and parameter-lock values.
struct StepOutput {
    let gate: Float
    let parameterLocks: [String: Float]
    let stepIndex: Int
    let didTrigger: Bool
}

// MARK: - Sequencer Node

/// Control-rate sequencer node that emits gate signals and parameter-lock values.
/// Drives step sequencing independent of lanes — the v2.0 graph-native replacement
/// for the v1.x per-lane step grid.
///
/// Whitepaper reference: §4.2.2 — recursive drift as performable arc
final class SequencerNode: BaseGraphNode {

    // MARK: - Parameters

    var chainLength: Int {
        get { getParam("chainLength", default: LRConstants.chainLengthDefault) }
        set { setParam("chainLength", value: newValue) }
    }

    var stepTimeBPM: Int {
        get { getParam("stepTimeBPM", default: LRConstants.stepTimeBPMDefault) }
        set { setParam("stepTimeBPM", value: newValue) }
    }

    var advanceMode: StepGrid.StepAdvanceMode {
        get {
            let raw = getParam("advanceMode", default: StepGrid.StepAdvanceMode.iteration.rawValue)
            if let mode = StepGrid.StepAdvanceMode(rawValue: raw) {
                return mode
            }
            return .iteration
        }
        set { setParam("advanceMode", value: newValue.rawValue) }
    }

    var swing: Float {
        get { getParam("swing", default: 0.0) }
        set { setParam("swing", value: newValue) }
    }

    var stepAdvanceDivisor: Int {
        get { getParam("stepAdvanceDivisor", default: LRConstants.stepAdvanceDivisor) }
        set { setParam("stepAdvanceDivisor", value: newValue) }
    }

    // MARK: - State

    /// Current step index (0..<chainLength)
    @Published var currentStepIndex: Int = 0

    /// The step grid data — migrated from PerformanceState.swift
    @Published var stepGrid: StepGrid

    /// Tracks which one-shot steps have fired in the current pattern pass
    private var oneShotFired: Set<Int> = []

    /// Subscription to FeedbackLoopNode iteration count (for .iteration advance mode)
    private var iterationSubscription: AnyCancellable?

    /// Output publishers for gate and parameter locks
    let gatePublisher = CurrentValueSubject<Float, Never>(0.0)
    let stepTriggeredPublisher = PassthroughSubject<Int, Never>()

    // MARK: - Init

    init(id: UUID = UUID(), params: [String: Any] = [:]) {
        // Initialize step grid from params or defaults
        if let gridData = params["stepGrid"] as? Data,
           let decoded = try? JSONDecoder().decode(StepGrid.self, from: gridData) {
            self.stepGrid = decoded
        } else {
            self.stepGrid = StepGrid()
        }

        super.init(
            id: id,
            nodeType: "step_sequencer",
            category: .control,
            displayName: "STEP SEQUENCER"
        )

        // Apply any additional params
        for (key, value) in params {
            if key != "stepGrid" {
                self.parameters[key] = value
            }
        }

        // Sync currentStepIndex with stepGrid
        self.currentStepIndex = stepGrid.currentStepIndex
    }

    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // Decode step grid if present
        if let gridData = try container.decodeIfPresent(Data.self, forKey: .stepGrid),
           let decoded = try? JSONDecoder().decode(StepGrid.self, from: gridData) {
            self.stepGrid = decoded
        } else {
            self.stepGrid = StepGrid()
        }

        try super.init(from: decoder)

        self.currentStepIndex = stepGrid.currentStepIndex
    }

    override func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        let gridData = try JSONEncoder().encode(stepGrid)
        try container.encode(gridData, forKey: .stepGrid)
        try super.encode(to: encoder)
    }

    private enum CodingKeys: String, CodingKey {
        case stepGrid
    }

    // MARK: - Ports

    override var ports: [NodePort] {
        [
            NodePort(id: "clock", label: "CLK", signalType: .gate, direction: .input),
            NodePort(id: "reset", label: "RST", signalType: .trigger, direction: .input),
            NodePort(id: "gate", label: "GATE", signalType: .gate, direction: .output),
            NodePort(id: "p_lock_0", label: "PL 0", signalType: .control, direction: .output),
            NodePort(id: "p_lock_1", label: "PL 1", signalType: .control, direction: .output),
            NodePort(id: "p_lock_2", label: "PL 2", signalType: .control, direction: .output),
            NodePort(id: "p_lock_3", label: "PL 3", signalType: .control, direction: .output)
        ]
    }

    // MARK: - Telemetry

    override var telemetry: NodeTelemetry {
        NodeTelemetry(
            level: Float(currentStepIndex) / Float(chainLength),
            isActive: true
        )
    }

    // MARK: - Iteration Subscription

    /// Subscribe to a FeedbackLoopNode's iteration count for .iteration advance mode.
    /// The sequencer advances when the feedback loop completes an iteration.
    func subscribeToIterations(of feedbackNode: FeedbackLoopNode) {
        iterationSubscription?.cancel()

        // Subscribe to FeedbackLoopNode's iteration count
        iterationSubscription = feedbackNode.$iterationCount
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newCount in
                guard let self = self,
                      self.advanceMode == .iteration,
                      newCount > 0 else { return }

                // Check step advance divisor
                let divisor = self.stepAdvanceDivisor
                guard divisor > 0 else { return }

                // Only advance every N iterations
                if newCount % divisor == 0 {
                    self.advance()
                }
            }
    }

    /// Unsubscribe from iteration notifications.
    func unsubscribeFromIterations() {
        iterationSubscription?.cancel()
        iterationSubscription = nil
    }

    // MARK: - Advance Logic

    /// Advance to the next step based on current mode and configuration.
    /// Returns StepOutput with gate and parameter-lock values.
    @discardableResult
    func advance() -> StepOutput {
        let chain = chainLength
        guard chain > 0 else {
            return StepOutput(gate: 0.0, parameterLocks: [:], stepIndex: currentStepIndex, didTrigger: false)
        }

        let next = (currentStepIndex + 1) % chain

        // Wrap detection — clear one-shot tracking
        if next < currentStepIndex {
            oneShotFired.removeAll()
        }

        return advanceToStep(candidateIndex: next)
    }

    /// Advance to a specific step index (manual or iteration-driven).
    @discardableResult
    func advanceToStep(candidateIndex: Int) -> StepOutput {
        let chain = chainLength
        guard chain > 0,
              candidateIndex >= 0,
              candidateIndex < chain,
              candidateIndex != currentStepIndex else {
            return StepOutput(gate: 0.0, parameterLocks: [:], stepIndex: currentStepIndex, didTrigger: false)
        }

        let previousIndex = currentStepIndex
        currentStepIndex = candidateIndex

        // Update stepGrid to stay in sync
        stepGrid.currentStepIndex = candidateIndex

        // Clear one-shot tracking on wrap
        if candidateIndex < previousIndex {
            oneShotFired.removeAll()
        }

        // Get the step data
        guard let step = stepGrid.step(at: candidateIndex) else {
            return StepOutput(gate: 0.0, parameterLocks: [:], stepIndex: candidateIndex, didTrigger: false)
        }

        // Handle trig type
        if step.trigType == .skip {
            gatePublisher.send(0.0)
            return StepOutput(gate: 0.0, parameterLocks: [:], stepIndex: candidateIndex, didTrigger: false)
        }

        if step.trigType == .oneShot && oneShotFired.contains(candidateIndex) {
            gatePublisher.send(0.0)
            return StepOutput(gate: 0.0, parameterLocks: [:], stepIndex: candidateIndex, didTrigger: false)
        }

        // Handle probability
        if let prob = step.probability, prob < 1.0 {
            if Float.random(in: 0...1) > prob {
                gatePublisher.send(0.0)
                return StepOutput(gate: 0.0, parameterLocks: [:], stepIndex: candidateIndex, didTrigger: false)
            }
        }

        // Step triggers — collect parameter locks
        var locks: [String: Float] = [:]

        // Map PerformanceStep fields to parameter lock outputs
        if let cfg = step.cfg { locks["p_lock_0"] = cfg }
        if let feedback = step.feedback { locks["p_lock_1"] = feedback }
        if let texture = step.texture { locks["p_lock_2"] = texture }
        if let chaos = step.chaos { locks["p_lock_3"] = chaos }

        // Send gate
        gatePublisher.send(1.0)
        stepTriggeredPublisher.send(candidateIndex)

        // Track one-shot
        if step.trigType == .oneShot {
            oneShotFired.insert(candidateIndex)
        }

        // Reset gate after short duration (simulated one-shot trigger)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.gatePublisher.send(0.0)
        }

        return StepOutput(gate: 1.0, parameterLocks: locks, stepIndex: candidateIndex, didTrigger: true)
    }

    /// Reset to step 0.
    func reset() {
        currentStepIndex = 0
        stepGrid.currentStepIndex = 0
        oneShotFired.removeAll()
    }

    /// Manual step advance (for tap/keyboard control).
    func advanceManually() {
        let chain = chainLength
        guard chain > 0 else { return }
        let next = (currentStepIndex + 1) % chain
        _ = advanceToStep(candidateIndex: next)
    }

    // MARK: - Step Grid Access

    /// Get the step at the current index.
    var currentStep: PerformanceStep? {
        stepGrid.step(at: currentStepIndex)
    }

    /// Update a step in the grid.
    func setStep(_ step: PerformanceStep, at index: Int) {
        stepGrid.setStep(step, at: index)
    }

    /// Get the active step count.
    var activeStepCount: Int {
        min(chainLength, stepGrid.steps.count)
    }
}

// MARK: - Step Sequencer Array Extension

extension Array where Element == SequencerNode {
    /// All sequencers in iteration advance mode.
    var iterationBased: [SequencerNode] {
        filter { $0.advanceMode == .iteration }
    }

    /// All sequencers in time advance mode.
    var timeBased: [SequencerNode] {
        filter { $0.advanceMode == .time }
    }
}
