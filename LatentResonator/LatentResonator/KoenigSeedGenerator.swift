import Foundation
import AVFoundation

// MARK: - Koenig Seed Generator (Whitepaper §4.1)
// Generates Dirac impulses arranged in a Euclidean rhythm E(5,13).
// Each impulse is followed by a 20ms Gaussian noise tail to provide
// nucleation sites for the diffusion model's denoiser.

final class KoenigSeedGenerator {

    // MARK: - Euclidean Rhythm (Bjorklund's Algorithm)

    /// Compute a Euclidean rhythm distributing `k` pulses over `n` steps.
    ///
    /// E(5,13) -> [true, false, false, true, false, true, false, false, true, false, true, false, false]
    ///
    /// Uses Bjorklund's algorithm for maximal evenness.
    /// Prime step counts (like 13) avoid Western metric symmetry.
    static func euclideanRhythm(pulses k: Int, steps n: Int) -> [Bool] {
        guard k > 0, n > 0, k <= n else {
            return Array(repeating: false, count: max(n, 0))
        }

        var pattern: [[Bool]] = Array(repeating: [true], count: k)
        var remainder: [[Bool]] = Array(repeating: [false], count: n - k)

        while remainder.count > 1 {
            let take = min(pattern.count, remainder.count)
            var merged: [[Bool]] = []

            for i in 0..<take {
                merged.append(pattern[i] + remainder[i])
            }

            let leftoverPattern = Array(pattern.dropFirst(take))
            let leftoverRemainder = Array(remainder.dropFirst(take))

            pattern = merged
            remainder = leftoverPattern + leftoverRemainder
        }

        return (pattern + remainder).flatMap { $0 }
    }

}
