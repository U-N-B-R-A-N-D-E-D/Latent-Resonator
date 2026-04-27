import Foundation

// MARK: - BufferPool

/// Pre-allocated pool of stereo audio buffers used by the `GraphAudioEngine`
/// to route signal between `DSPNode`s.
///
/// One contiguous heap allocation, carved into `count` parallel L/R channel
/// pairs of `frameCapacity` floats each. The audio thread reuses the same
/// memory across every render callback — it never asks the allocator for
/// more, eliminating priority-inversion risk on the RT thread.
///
/// Memory layout (count = N, frameCapacity = F):
/// ```
///   slot 0:   [L L L … L]  [R R R … R]      (2·F floats)
///   slot 1:   [L L L … L]  [R R R … R]
///   …
///   slot N-1: [L L L … L]  [R R R … R]
/// ```
///
/// A new pool is allocated when topology changes; the old pool is released
/// after the audio thread has observed the plan swap (ARC manages this
/// because `ExecutionPlan` holds a strong reference to its pool).
final class BufferPool {

    /// Number of stereo slots in the pool.
    let count: Int

    /// Maximum number of sample frames each slot can hold per channel.
    let frameCapacity: Int

    /// Backing storage. `count * 2 * frameCapacity` floats, contiguous.
    private let storage: UnsafeMutablePointer<Float>

    /// Number of floats per channel within a slot. Equal to `frameCapacity`
    /// for now; kept as a separate field in case we ever want per-channel
    /// alignment slack.
    private let channelStride: Int

    init(count: Int, frameCapacity: Int) {
        precondition(count > 0, "BufferPool: count must be > 0")
        precondition(frameCapacity > 0, "BufferPool: frameCapacity must be > 0")
        self.count = count
        self.frameCapacity = frameCapacity
        self.channelStride = frameCapacity
        let totalFloats = count * 2 * channelStride
        self.storage = .allocate(capacity: totalFloats)
        self.storage.initialize(repeating: 0, count: totalFloats)
    }

    deinit {
        let totalFloats = count * 2 * channelStride
        storage.deinitialize(count: totalFloats)
        storage.deallocate()
    }

    // MARK: - Slot access

    /// Returns the L/R pointer pair for slot `index`.
    /// - Parameter index: 0 ..< count.
    /// - Returns: A non-owning `AudioBuffer` view into the pool's storage.
    @inline(__always)
    func buffer(at index: Int) -> AudioBuffer {
        precondition(index >= 0 && index < count, "BufferPool: slot \(index) out of range [0, \(count))")
        let base = storage.advanced(by: index * 2 * channelStride)
        return AudioBuffer(
            left: base,
            right: base.advanced(by: channelStride),
            frameCapacity: frameCapacity
        )
    }

    /// Zeroes one slot's first `frameCount` samples (both channels).
    /// Sumators (mixer-style nodes) call this before accumulating into a slot.
    @inline(__always)
    func zero(_ index: Int, frameCount: Int) {
        let buf = buffer(at: index)
        let bytes = frameCount * MemoryLayout<Float>.stride
        memset(buf.left, 0, bytes)
        memset(buf.right, 0, bytes)
    }
}
