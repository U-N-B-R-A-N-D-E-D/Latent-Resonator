import Foundation
import AVFoundation
import os.lock

// MARK: - GraphAudioEngine

/// Renders the entire `NodeGraph` from a single `AVAudioSourceNode` root.
///
/// AVAudioEngine handles only I/O (sample-rate conversion, hardware
/// scheduling, output device routing). Everything else — mixing,
/// filtering, every node in the patch — runs inside our render callback
/// by walking an `ExecutionPlan`.
///
/// This is the standard "pull-render graph" model used by Reaktor,
/// Max-MSP, SuperCollider, and VCV Rack: the only AVFoundation primitives
/// in the audio chain are the source node we own here and the engine's
/// built-in main mixer + output.
///
/// ## Threading
///
/// - Main thread: `init`, `adopt(_:)`. Builds plans, allocates `BufferPool`s,
///   configures the source node.
/// - Audio thread: render callback invoked by AVAudioEngine inside the
///   source node's closure. Reads `currentPlan` under
///   `os_unfair_lock_trylock` — never blocks. If the lock is held by the
///   main thread (during a plan swap), the audio thread renders silence
///   for one buffer, which is inaudible at the typical 5–20 ms render
///   quantum.
///
/// ## Lifecycle
///
/// - The `rootSourceNode` is created once at init and kept for the lifetime
///   of the engine. AVAudioEngine never re-attaches it.
/// - `BufferPool`s are owned by their `ExecutionPlan`; ARC releases them
///   after the audio thread observes a plan swap and lets go of its
///   strong reference.
/// - On `adopt(nil)` the engine renders silence indefinitely. This is the
///   safe state during topology rebuilds.
final class GraphAudioEngine {

    // MARK: - State

    let format: AVAudioFormat
    let frameCapacity: Int

    /// The root audio node attached to AVAudioEngine. Created once at init,
    /// never replaced. IUO so the init closure can reference `self`
    /// after all other stored properties are assigned.
    private(set) var rootSourceNode: AVAudioSourceNode!

    private var currentPlan: ExecutionPlan?
    private var planLock = os_unfair_lock_s()

    /// Pre-allocated scratch space for gathering input buffer pointers per
    /// step. Sized to a generous upper bound on per-node input ports
    /// (Mixer is widest at 4 audio inputs in the current node set;
    /// 16 leaves headroom for future fan-in nodes). Allocated once,
    /// reused on every callback — never touches the allocator.
    private static let maxInputsPerNode = 16
    private let inputsScratch: UnsafeMutablePointer<AudioBuffer>

    /// Single-float sentinel buffers backing the placeholder `AudioBuffer`
    /// used to initialize `inputsScratch`. The placeholder is never read —
    /// every render block overwrites the slots that will actually be
    /// consumed before passing them to a `DSPNode`.
    private let placeholderL: UnsafeMutablePointer<Float>
    private let placeholderR: UnsafeMutablePointer<Float>

    // MARK: - Init

    init(format: AVAudioFormat, frameCapacity: Int) {
        precondition(frameCapacity > 0, "GraphAudioEngine: frameCapacity must be > 0")
        self.format = format
        self.frameCapacity = frameCapacity

        self.placeholderL = .allocate(capacity: 1)
        self.placeholderL.initialize(to: 0)
        self.placeholderR = .allocate(capacity: 1)
        self.placeholderR.initialize(to: 0)
        let placeholder = AudioBuffer(left: placeholderL, right: placeholderR, frameCapacity: 0)

        self.inputsScratch = .allocate(capacity: GraphAudioEngine.maxInputsPerNode)
        self.inputsScratch.initialize(repeating: placeholder, count: GraphAudioEngine.maxInputsPerNode)

        // Every stored property is now initialized; safe to capture `self`.
        // We defer rootSourceNode assignment to here so the closure can
        // call `self.render(...)`.
        self.rootSourceNode = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, abl in
            guard let self = self else {
                GraphAudioEngine.zeroABL(abl, frameCount: Int(frameCount))
                return noErr
            }
            return self.render(frameCount: Int(frameCount), into: abl)
        }
    }

    deinit {
        inputsScratch.deinitialize(count: GraphAudioEngine.maxInputsPerNode)
        inputsScratch.deallocate()
        placeholderL.deinitialize(count: 1)
        placeholderL.deallocate()
        placeholderR.deinitialize(count: 1)
        placeholderR.deallocate()
    }

    // MARK: - Plan management

    /// Replace the currently-rendered plan. The audio thread picks up the
    /// swap at the start of its next render block; afterwards the previous
    /// plan's `BufferPool` becomes unreachable and ARC reclaims it.
    ///
    /// Pass `nil` to render silence (used during teardown / between
    /// rebuilds).
    func adopt(_ plan: ExecutionPlan?) {
        os_unfair_lock_lock(&planLock)
        currentPlan = plan
        os_unfair_lock_unlock(&planLock)
    }

    /// Reset every node in the current plan (clears filter state, etc.).
    /// Safe to call from any thread.
    func resetAllNodes() {
        os_unfair_lock_lock(&planLock)
        let plan = currentPlan
        os_unfair_lock_unlock(&planLock)
        plan?.steps.forEach { $0.dspNode.reset() }
    }

    /// Number of render steps in the currently-adopted plan. Used by the
    /// pipeline-verification logging in NeuralEngine. Safe to call from
    /// any thread.
    var currentPlanStepCount: Int {
        os_unfair_lock_lock(&planLock)
        let count = currentPlan?.steps.count ?? 0
        os_unfair_lock_unlock(&planLock)
        return count
    }

    // MARK: - Render

    private func render(
        frameCount: Int,
        into abl: UnsafeMutablePointer<AudioBufferList>
    ) -> OSStatus {
        // Snapshot the plan under trylock — never block the audio thread.
        var planSnapshot: ExecutionPlan?
        if os_unfair_lock_trylock(&planLock) {
            planSnapshot = currentPlan
            os_unfair_lock_unlock(&planLock)
        }

        guard let plan = planSnapshot else {
            GraphAudioEngine.zeroABL(abl, frameCount: frameCount)
            return noErr
        }

        guard frameCount <= plan.frameCapacity else {
            // Render quantum exceeds the pool; degrade to silence so the
            // next topology rebuild can grow the pool to fit.
            GraphAudioEngine.zeroABL(abl, frameCount: frameCount)
            return noErr
        }

        let pool = plan.bufferPool
        let sampleRate = format.sampleRate
        let scratch = self.inputsScratch
        let scratchCap = GraphAudioEngine.maxInputsPerNode

        var wroteToTerminal = false

        for step in plan.steps {
            let inputCount = min(step.inputBufferIndices.count, scratchCap)

            for k in 0..<inputCount {
                scratch[k] = pool.buffer(at: step.inputBufferIndices[k])
            }
            let inputs = UnsafeBufferPointer(start: scratch, count: inputCount)

            if step.outputBufferIndex == ExecutionPlan.terminalSlot {
                // Terminal: render directly into the ABL provided by AVAudioEngine.
                let ablPtr = UnsafeMutableAudioBufferListPointer(abl)
                guard ablPtr.count >= 2,
                      let leftRaw = ablPtr[0].mData,
                      let rightRaw = ablPtr[1].mData else {
                    GraphAudioEngine.zeroABL(abl, frameCount: frameCount)
                    return noErr
                }
                let outputBuf = AudioBuffer(
                    left: leftRaw.assumingMemoryBound(to: Float.self),
                    right: rightRaw.assumingMemoryBound(to: Float.self),
                    frameCapacity: frameCount
                )
                step.dspNode.render(
                    inputs: inputs,
                    output: outputBuf,
                    frameCount: frameCount,
                    sampleRate: sampleRate
                )
                wroteToTerminal = true
            } else {
                // Internal: render into the assigned BufferPool slot.
                let outputBuf = pool.buffer(at: step.outputBufferIndex)
                step.dspNode.render(
                    inputs: inputs,
                    output: outputBuf,
                    frameCount: frameCount,
                    sampleRate: sampleRate
                )
            }
        }

        if !wroteToTerminal {
            // The plan had no terminal step (no MasterOutputNode). Don't leak
            // whatever was in the ABL from the previous callback.
            GraphAudioEngine.zeroABL(abl, frameCount: frameCount)
        }

        return noErr
    }

    // MARK: - Helpers

    @inline(__always)
    private static func zeroABL(_ abl: UnsafeMutablePointer<AudioBufferList>, frameCount: Int) {
        let ptr = UnsafeMutableAudioBufferListPointer(abl)
        for buf in ptr {
            if let data = buf.mData {
                memset(data, 0, Int(buf.mDataByteSize))
            }
        }
    }
}
