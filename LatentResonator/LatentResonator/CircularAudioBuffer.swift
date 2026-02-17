import Foundation
import os

// MARK: - Lock-Free Circular Audio Buffer (Whitepaper §5.2)
// Single-Producer / Single-Consumer ring buffer for real-time audio.
//
// Producer: audio capture thread -> captureBuffer
// Consumer: inference thread reads from captureBuffer
//
// Producer: inference thread -> feedbackBuffer
// Consumer: audio render callback reads from feedbackBuffer
//
// Position variables are protected by os_unfair_lock to guarantee
// cross-thread visibility (memory barrier). The lock is only held
// for a single Int read/write (~1ns), so it is safe on audio threads.
// The data copy itself happens OUTSIDE the lock.

final class CircularAudioBuffer: @unchecked Sendable {

    private let capacity: Int
    private let mask: Int
    private let storage: UnsafeMutablePointer<Float>

    // Write position -- only modified by the producer thread
    private var _writePos: Int = 0

    // Read position -- only modified by the consumer thread
    private var _readPos: Int = 0

    // Lock for cross-thread visibility of position variables.
    // Critical section is 1 word read/write -- sub-nanosecond.
    private var _lock = os_unfair_lock_s()

    /// Capacity is rounded up to the next power of 2 for efficient masking.
    init(capacity: Int = LRConstants.ringBufferCapacity) {
        let cap = 1 << Int(ceil(log2(Double(max(capacity, 2)))))
        self.capacity = cap
        self.mask = cap - 1
        self.storage = .allocate(capacity: cap)
        self.storage.initialize(repeating: 0.0, count: cap)
    }

    deinit {
        storage.deinitialize(count: capacity)
        storage.deallocate()
    }

    // MARK: - Synchronized Position Access

    /// Load both positions atomically with memory barrier.
    @inline(__always)
    private func loadPositions() -> (write: Int, read: Int) {
        os_unfair_lock_lock(&_lock)
        let w = _writePos
        let r = _readPos
        os_unfair_lock_unlock(&_lock)
        return (w, r)
    }

    /// Store write position with memory barrier (after data is written).
    @inline(__always)
    private func storeWritePos(_ wp: Int) {
        os_unfair_lock_lock(&_lock)
        _writePos = wp
        os_unfair_lock_unlock(&_lock)
    }

    /// Store read position with memory barrier (after data is read).
    @inline(__always)
    private func storeReadPos(_ rp: Int) {
        os_unfair_lock_lock(&_lock)
        _readPos = rp
        os_unfair_lock_unlock(&_lock)
    }

    // MARK: - State

    var availableToRead: Int {
        let (w, r) = loadPositions()
        return (w &- r) & mask
    }

    var availableToWrite: Int {
        let (w, r) = loadPositions()
        return capacity - 1 - ((w &- r) & mask)
    }

    // MARK: - Write (Producer Thread Only)

    /// Write samples into the buffer. Returns the number of samples actually written.
    @discardableResult
    func write(_ source: UnsafePointer<Float>, count: Int) -> Int {
        let (w, r) = loadPositions()
        let avail = capacity - 1 - ((w &- r) & mask)
        let toWrite = min(count, avail)
        var wp = w
        for i in 0..<toWrite {
            storage[wp & mask] = source[i]
            wp &+= 1
        }
        storeWritePos(wp)
        return toWrite
    }

    /// Write from a Swift array.
    @discardableResult
    func write(_ samples: [Float]) -> Int {
        return samples.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return 0 }
            return write(base, count: samples.count)
        }
    }

    // MARK: - Read (Consumer Thread Only)

    /// Read samples from the buffer into a destination pointer.
    /// Returns the number of samples actually read.
    @discardableResult
    func read(into dest: UnsafeMutablePointer<Float>, count: Int) -> Int {
        let (w, r) = loadPositions()
        let avail = (w &- r) & mask
        let toRead = min(count, avail)
        var rp = r
        for i in 0..<toRead {
            dest[i] = storage[rp & mask]
            rp &+= 1
        }
        storeReadPos(rp)
        return toRead
    }

    /// Read into a new Swift array.
    func read(count: Int) -> [Float] {
        var output = [Float](repeating: 0.0, count: count)
        let actual = output.withUnsafeMutableBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return 0 }
            return read(into: base, count: count)
        }
        return actual < count ? Array(output.prefix(actual)) : output
    }

    // MARK: - Reset

    func reset() {
        os_unfair_lock_lock(&_lock)
        _writePos = 0
        _readPos = 0
        os_unfair_lock_unlock(&_lock)
    }
}
