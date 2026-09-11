import Foundation

// MARK: - DSPNode

/// The audio-thread interface every render-participating graph node
/// implements.
///
/// `DSPNode` is intentionally small and AVFoundation-free. It is invoked
/// from inside the `GraphAudioEngine` root `AVAudioSourceNode` callback, so
/// implementations MUST honor the standard real-time contract:
///
/// 1. **No allocations.** No `Array`/`Dictionary`/`String` creation, no
///    `.allocate`/`.deallocate`, no Foundation collection mutation.
/// 2. **No locks that can be held from the main thread.** Use
///    `os_unfair_lock_trylock` for parameter snapshots; never block.
/// 3. **No blocking I/O, no `print`, no `os_log` at info level.**
/// 4. **Bounded work.** Render must complete well within the IO buffer
///    deadline (typically 5 ms at 256 frames @ 48 kHz; 21 ms at 1024
///    frames @ 48 kHz).
///
/// In return, the engine guarantees:
///
/// - `inputs[k].left`/`right` and `output.left`/`right` point to at least
///   `frameCount` valid floats and never alias each other across nodes
///   within a single render pass.
/// - `inputs.count` matches the audio-input port count of this node, in
///   stable port-id order (so `MixerNode`'s `in0`, `in1`, … indices line
///   up with the `inputs` buffer).
/// The single control-rate contract is `ControlGraphEvaluator` →
/// `setParameter` → `getParam` per render block, eventual-consistent by
/// design. A second `controls: [String: Float]` path was trialed in
/// `ExecutionPlan.Step` but was always initialized `[:]` and therefore
/// never used; it was removed on 2026-07-27 perimeter closure to keep
/// one unambiguous control path.
protocol DSPNode: AnyObject {

    /// Stable identity matching the owning `GraphNode.id`. Used by the
    /// engine's plan builder when it walks the topology and assigns buffer
    /// slots.
    var nodeId: UUID { get }

    /// Render `frameCount` samples, reading from `inputs` and writing into
    /// `output`. RT-safe.
    ///
    /// - Parameters:
    ///   - inputs: zero-or-more stereo input buffers. Order matches the
    ///     node's audio-input ports sorted by `NodePort.id`.
    ///   - output: stereo destination. Already valid memory; the node MUST
    ///     fill exactly the first `frameCount` samples on both channels
    ///     (no leftover garbage from previous renders).
    ///   - frameCount: number of samples to process.
    ///   - sampleRate: the engine's sample rate (typically 48 000).
    func render(
        inputs: UnsafeBufferPointer<AudioBuffer>,
        output: AudioBuffer,
        frameCount: Int,
        sampleRate: Double
    )

    /// Clears any internal DSP state (filter accumulators, delay lines,
    /// oscillator phase, etc.). Called when the engine resets — e.g. on
    /// start, stop, or topology rebuild.
    func reset()
}

extension DSPNode {
    /// Default reset is a no-op — pure-function nodes (gain, copy, simple
    /// arithmetic) need nothing here. Stateful nodes override.
    func reset() { /* no-op */ }
}
