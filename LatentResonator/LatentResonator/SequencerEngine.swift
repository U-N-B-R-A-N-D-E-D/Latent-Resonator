import Foundation
import Combine
import SwiftUI

// MARK: - Sequencer Engine
//
// Owns step timing and advance logic. Extracted from NeuralEngine to reduce
// its scope and separate "when to step" from "what to apply."
//
// NeuralEngine passes closures for lanes, focusStepGrid, isProcessing, and
// applyLaneStepLocks so SequencerEngine stays pure about timing.
//
// White paper reference: §4.2.2 — recursive drift as performable arc; §7 — CFG at hand.

final class SequencerEngine {

    // MARK: - Dependencies

    private let lanesGetter: () -> [ResonatorLane]
    private let focusStepGridGetter: () -> StepGrid?
    private let isProcessingGetter: () -> Bool
    private let applyLocks: (ResonatorLane) -> Void

    // MARK: - Step Timer

    private var stepTimer: DispatchSourceTimer?
    let stepTimerQueue = DispatchQueue(label: "com.latentresonator.stepTimer", qos: .userInteractive)
    private var laneIterationCancellables = Set<AnyCancellable>()

    // MARK: - Init

    init(
        lanesGetter: @escaping () -> [ResonatorLane],
        focusStepGridGetter: @escaping () -> StepGrid?,
        isProcessingGetter: @escaping () -> Bool,
        applyLocks: @escaping (ResonatorLane) -> Void
    ) {
        self.lanesGetter = lanesGetter
        self.focusStepGridGetter = focusStepGridGetter
        self.isProcessingGetter = isProcessingGetter
        self.applyLocks = applyLocks
    }

    deinit {
        stepTimer?.cancel()
    }

    // MARK: - Public API

    /// Subscribe to each active lane's iteration count so step advance fires per-lane.
    func subscribeLaneIterations() {
        laneIterationCancellables.removeAll()
        for lane in lanesGetter() {
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
    func syncStepTimer() {
        stepTimer?.cancel()
        stepTimer = nil

        guard let grid = focusStepGridGetter(), grid.advanceMode == .time else { return }

        let bpm = Double(grid.stepTimeBPM)
        let intervalNs = UInt64((60.0 / bpm) * 1_000_000_000)
        print(">> StepTimer: Starting at \(bpm) BPM (interval: \(String(format: "%.2f", 60.0 / bpm))s)")

        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: stepTimerQueue)
        timer.schedule(deadline: .now() + .nanoseconds(Int(intervalNs)),
                       repeating: .nanoseconds(Int(intervalNs)),
                       leeway: .microseconds(500))
        timer.setEventHandler { [weak self] in
            guard let self = self, self.isProcessingGetter() else { return }
            DispatchQueue.main.async {
                self.advanceAllLanesSteps()
            }
        }
        timer.resume()
        stepTimer = timer
    }

    /// Manual step advance for one lane (tap or keyboard).
    func advanceLaneManually(lane: ResonatorLane) {
        let chain = lane.stepGrid.chainLength
        guard chain > 0 else { return }
        let next = (lane.stepGrid.currentStepIndex + 1) % chain
        advanceLaneToStep(lane: lane, candidateIndex: next)
    }

    /// Cancel the step timer. Call when stopping the engine.
    func cancelStepTimer() {
        stepTimer?.cancel()
        stepTimer = nil
    }

    // MARK: - Advance Logic

    private func advanceLaneStep(lane: ResonatorLane) {
        let grid = lane.stepGrid
        guard grid.advanceMode == .iteration else { return }
        let total = lane.iterationCount
        let chain = grid.chainLength
        guard chain > 0 else { return }

        let candidateIndex = (total / grid.stepAdvanceDivisor) % chain
        guard candidateIndex != grid.currentStepIndex else { return }

        advanceLaneToStep(lane: lane, candidateIndex: candidateIndex)
    }

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

        applyLocks(lane)

        if step.trigType == .oneShot {
            var g = lane.stepGrid
            g.oneShotFired.insert(candidateIndex)
            lane.stepGrid = g
        }
    }

    private func advanceAllLanesSteps() {
        let lanes = lanesGetter()
        let focusGrid = focusStepGridGetter()

        for lane in lanes {
            let grid = lane.stepGrid
            let chain = grid.chainLength
            guard chain > 0 else { continue }
            let next = (grid.currentStepIndex + 1) % chain

            if let step = grid.step(at: next), abs(step.microtiming) > 0.001,
               let fg = focusGrid, fg.advanceMode == .time {
                let bpm = Double(fg.stepTimeBPM)
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
}
