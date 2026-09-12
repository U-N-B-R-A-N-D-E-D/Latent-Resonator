import Foundation
import Combine
import SwiftUI

// MARK: - Sequencer Engine

/// Owns step timing and advance logic for all SequencerNodes in the graph.
/// v2.0: Graph-native implementation — no lane dependencies.
///
/// White paper reference: §4.2.2 — recursive drift as performable arc; §7 — CFG at hand.
final class SequencerEngine {

    // MARK: - Dependencies

    private weak var nodeGraph: NodeGraph?
    private let isProcessingGetter: () -> Bool

    // MARK: - Step Timer

    private var stepTimer: DispatchSourceTimer?
    let stepTimerQueue = DispatchQueue(label: "com.latentresonator.stepTimer", qos: .userInteractive)
    private var iterationSubscriptions = Set<AnyCancellable>()
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init

    init(
        nodeGraph: NodeGraph,
        isProcessingGetter: @escaping () -> Bool
    ) {
        self.nodeGraph = nodeGraph
        self.isProcessingGetter = isProcessingGetter

        // Subscribe to node graph changes to detect new sequencers
        setupNodeGraphSubscription()
    }

    deinit {
        stepTimer?.cancel()
        iterationSubscriptions.removeAll()
        cancellables.removeAll()
    }

    // MARK: - Node Graph Subscription

    private func setupNodeGraphSubscription() {
        nodeGraph?.$nodes
            .sink { [weak self] _ in
                self?.resubscribeToSequencers()
            }
            .store(in: &cancellables)
    }

    /// Resubscribe to all sequencers in the graph.
    private func resubscribeToSequencers() {
        iterationSubscriptions.removeAll()

        guard let graph = nodeGraph else { return }

        let sequencers = graph.nodes.values.compactMap { $0 as? SequencerNode }

        for sequencer in sequencers {
            // Subscribe to iteration-based advance
            if sequencer.advanceMode == .iteration {
                if let feedbackNode = findConnectedFeedbackLoop(for: sequencer) {
                    setupIterationSubscription(sequencer: sequencer, feedbackNode: feedbackNode)
                }
            }
        }
    }

    /// Get all sequencer nodes in the graph.
    private var sequencers: [SequencerNode] {
        nodeGraph?.nodes.values.compactMap { $0 as? SequencerNode } ?? []
    }

    // MARK: - Public API

    /// Subscribe to each active sequencer's iteration requirements.
    /// Called when the engine starts processing.
    func subscribeSequencerIterations() {
        iterationSubscriptions.removeAll()

        // For each iteration-based sequencer, set up subscription
        for sequencer in sequencers where sequencer.advanceMode == .iteration {
            // Find connected FeedbackLoopNode
            if let feedbackNode = findConnectedFeedbackLoop(for: sequencer) {
                setupIterationSubscription(sequencer: sequencer, feedbackNode: feedbackNode)
            }
        }
    }

    /// Find the FeedbackLoopNode connected to a sequencer (if any).
    private func findConnectedFeedbackLoop(for sequencer: SequencerNode) -> FeedbackLoopNode? {
        guard let graph = nodeGraph else { return nil }

        // Look for edges where sequencer is the source and target is a feedback loop
        for edge in graph.edges.values where edge.sourceNodeId == sequencer.id {
            if let targetNode = graph.nodes[edge.targetNodeId] as? FeedbackLoopNode {
                return targetNode
            }
        }

        return nil
    }

    /// Set up iteration subscription between sequencer and feedback loop.
    private func setupIterationSubscription(sequencer: SequencerNode, feedbackNode: FeedbackLoopNode) {
        sequencer.subscribeToIterations(of: feedbackNode)
    }

    /// Start or stop the step timer for time-based sequencers.
    func syncStepTimer() {
        stepTimer?.cancel()
        stepTimer = nil

        // Find any sequencer with time advance mode to determine BPM
        guard let timeSequencer = sequencers.first(where: { $0.advanceMode == .time }) else {
            return
        }

        let bpm = Double(timeSequencer.stepTimeBPM)
        let intervalNs = UInt64((60.0 / bpm) * 1_000_000_000)

        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: stepTimerQueue)
        timer.schedule(
            deadline: .now() + .nanoseconds(Int(intervalNs)),
            repeating: .nanoseconds(Int(intervalNs)),
            leeway: .microseconds(500)
        )

        timer.setEventHandler { [weak self] in
            guard let self = self, self.isProcessingGetter() else { return }
            DispatchQueue.main.async {
                self.advanceTimeBasedSteps()
            }
        }

        timer.resume()
        stepTimer = timer
    }

    /// Cancel the step timer.
    func cancelStepTimer() {
        stepTimer?.cancel()
        stepTimer = nil
    }

    /// Stop all sequencer subscriptions and timers.
    func stop() {
        cancelStepTimer()
        iterationSubscriptions.removeAll()
    }

    // MARK: - Advance Logic

    /// Advance all iteration-based sequencers.
    /// Called from an external iteration trigger (e.g., FeedbackLoopNode completion).
    func advanceIterationBasedSteps() {
        guard isProcessingGetter() else { return }

        for sequencer in sequencers where sequencer.advanceMode == .iteration {
            // Check step advance divisor
            // In full implementation, track iteration count per sequencer
            sequencer.advance()
        }
    }

    /// Advance time-based sequencers on timer tick.
    private func advanceTimeBasedSteps() {
        guard isProcessingGetter() else { return }

        // Get reference BPM from first time-based sequencer (used for timing calculations)
        _ = sequencers.first { $0.advanceMode == .time }?.stepTimeBPM ?? 120

        for sequencer in sequencers where sequencer.advanceMode == .time {
            let bpm = Double(sequencer.stepTimeBPM)
            let stepInterval = 60.0 / bpm

            // Check for microtiming on the next step
            _ = (sequencer.currentStepIndex + 1) % sequencer.chainLength

            if let step = sequencer.currentStep,
               abs(step.microtiming) > 0.001 {
                // Apply microtiming offset
                let offsetSeconds = step.microtiming * stepInterval
                let delayNs = max(0, Int(offsetSeconds * 1_000_000_000))

                stepTimerQueue.asyncAfter(deadline: .now() + .nanoseconds(delayNs)) { [weak self] in
                    DispatchQueue.main.async {
                        self?.advanceSequencer(sequencer)
                    }
                }
            } else {
                advanceSequencer(sequencer)
            }
        }
    }

    /// Advance a single sequencer to its next step.
    private func advanceSequencer(_ sequencer: SequencerNode) {
        let chain = sequencer.chainLength
        guard chain > 0 else { return }

        let next = (sequencer.currentStepIndex + 1) % chain
        _ = sequencer.advanceToStep(candidateIndex: next)
    }

    /// Manual step advance for a specific sequencer (tap or keyboard).
    func advanceSequencerManually(_ sequencer: SequencerNode) {
        let chain = sequencer.chainLength
        guard chain > 0 else { return }
        let next = (sequencer.currentStepIndex + 1) % chain
        _ = sequencer.advanceToStep(candidateIndex: next)
    }

    /// Reset a specific sequencer to step 0.
    func resetSequencer(_ sequencer: SequencerNode) {
        sequencer.reset()
    }

    /// Reset all sequencers.
    func resetAll() {
        for sequencer in sequencers {
            sequencer.reset()
        }
    }

    // MARK: - Parameter Lock Application

    /// Apply parameter locks for a triggered step to connected nodes.
    /// This would be called after a step triggers to update downstream parameters.
    func applyParameterLocks(for sequencer: SequencerNode) {
        guard let step = sequencer.currentStep else { return }

        // Find connected target nodes (typically a MacroNode)
        guard let graph = nodeGraph else { return }

        // Get edges where sequencer is the source
        let outgoingEdges = graph.edges.values.filter { $0.sourceNodeId == sequencer.id }

        for edge in outgoingEdges {
            guard let targetNode = graph.nodes[edge.targetNodeId] else { continue }

            // Apply parameter locks based on port
            // v2.0: Need to cast to BaseGraphNode to use setParam
            guard let target = targetNode as? BaseGraphNode else { continue }
            switch edge.sourcePortId {
            case "p_lock_0":
                if let cfg = step.cfg {
                    target.setParam("guidanceScale", value: cfg)
                }
            case "p_lock_1":
                if let feedback = step.feedback {
                    target.setParam("feedback", value: feedback)
                }
            case "p_lock_2":
                if let texture = step.texture {
                    target.setParam("texture", value: texture)
                }
            case "p_lock_3":
                if let chaos = step.chaos {
                    target.setParam("chaos", value: chaos)
                }
            default:
                break
            }
        }
    }
}

// MARK: - SequencerEngine Extensions

extension SequencerEngine {
    /// Convenience method to get the focused sequencer (for UI binding).
    func focusedSequencer(in graph: NodeGraph, focusNodeId: UUID?) -> SequencerNode? {
        guard let id = focusNodeId else { return nil }
        return graph.nodes[id] as? SequencerNode
    }

    /// Get all sequencers sorted by position (for UI display).
    func sortedSequencers() -> [SequencerNode] {
        sequencers.sorted { $0.name < $1.name }
    }
}
