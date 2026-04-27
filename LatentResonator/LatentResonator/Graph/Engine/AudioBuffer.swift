import Foundation

// MARK: - AudioBuffer

/// A non-owning view of a single stereo audio block. Two parallel mono
/// channels (L/R) plus the maximum number of frames the underlying memory
/// can hold.
///
/// The struct itself is a 24-byte POD: it does NOT manage memory. The
/// pointers are owned by whatever produced the view (typically a
/// `BufferPool` or, for the terminal node, the AVAudioEngine ABL). Copying
/// `AudioBuffer` is cheap and safe — it never duplicates samples.
///
/// Stereo throughout matches the rest of the codebase: `SignalGenerator`,
/// `SpectralProcessor`, and the AVAudioEngine output chain all speak in
/// (left, right) channel pairs.
struct AudioBuffer {
    let left: UnsafeMutablePointer<Float>
    let right: UnsafeMutablePointer<Float>
    let frameCapacity: Int
}
