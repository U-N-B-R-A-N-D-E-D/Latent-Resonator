import SwiftUI

// MARK: - Macro VU Meter (P4 — PERFORM mixer telemetry)
//
// Stereo VU meter for a `MacroNode`. Reads `macro.telemetrySnapshot`
// (a `MacroTelemetry { peakL, peakR, rmsL, rmsR: Float }` written by
// the audio thread under `os_unfair_lock_trylock` — never blocks the
// UI). Two thin vertical bars (L, R) carry the signal: RMS as a solid
// amber fill, peak as a 1pt tick at the peak position. No labels, no
// grid, no numbers. Envion restraint: the bars ARE the meter.
//
// Refresh: `TimelineView(.periodic(from: .now, by: 1/30))` — 30 Hz poll.
// This is the lowest-overhead SwiftUI-native approach (no Timer.publish
// subscription, no Combine, no @State thrash): the schedule simply
// re-evaluates the body closure 30×/sec and the closure reads the
// snapshot inline. Capped at 30 Hz so the audio thread is never
// starved and the battery is never drained.

private typealias DS = LRConstants.DS

/// dBFS span mapped to the bar's full height. Below `dbMin` the bar is
/// empty; at 0 dBFS the bar is full. Linear amplitude [0,1] maps to
/// (-inf, 0] dB — we clamp the bottom at -60 dB so silence reads as
/// silence without forcing the meter to render an infinitely tall
/// logarithmic scale.
private let kDBMin: Float = -60.0
private let kDBMax: Float = 0.0

struct MacroVUMeter: View {

    /// The macro whose audio-thread telemetry drives the bars. Held
    /// weakly by reference (MacroNode is a class) — the view does not
    /// own or retain the macro, it just polls it.
    let macro: MacroNode

    /// Musician P1.4 — when audio is stopped, the audio thread no longer
    /// calls `render()`, so `telemetrySnapshot` holds its last value
    /// forever and the bars freeze at a non-zero level (false "signal").
    /// The engine passes `isProcessing` here; when false we zero the
    /// bars and dim the fill so "stopped" reads as "silent". We do NOT
    /// touch `telemetry` itself in `NeuralEngine.stopProcessing()` —
    /// that would couple UI state to audio-thread state.
    var isProcessing: Bool = true

    /// Bar width (each). Thin — the meter is a glance, not a focus.
    private let barWidth: CGFloat = 6

    /// Bar height (each). Tall enough to read -60..0 dB at a glance,
    /// short enough to sit beside a mute/solo row without dominating.
    private let barHeight: CGFloat = 64

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { _ in
            let snap = macro.telemetrySnapshot
            // Musician P1.4: when stopped, force the bars to zero and
            // dim the fill so the meter reads "silent" instead of
            // freezing at its last live value.
            let rmsL = isProcessing ? snap.rmsL : 0
            let rmsR = isProcessing ? snap.rmsR : 0
            let peakL = isProcessing ? snap.peakL : 0
            let peakR = isProcessing ? snap.peakR : 0
            HStack(spacing: DS.spacingXS) {
                channelBar(rms: rmsL, peak: peakL, dimmed: !isProcessing)
                channelBar(rms: rmsR, peak: peakR, dimmed: !isProcessing)
            }
        }
        .frame(width: barWidth * 2 + DS.spacingXS, height: barHeight)
    }

    // MARK: - Channel bar

    /// One stereo channel: a thin vertical track with an RMS fill from
    /// the bottom up to the RMS dB position, and a 1pt peak tick at the
    /// peak dB position. The track is `DS.surfaceSubtle` with a
    /// `DS.border` hairline — sunken, like the envelope channel.
    private func channelBar(rms: Float, peak: Float, dimmed: Bool) -> some View {
        GeometryReader { geo in
            let full = geo.size.height
            let rmsH = dBToHeight(amplitudeToDB(rms), full: full)
            let peakH = dBToHeight(amplitudeToDB(peak), full: full)
            ZStack(alignment: .bottom) {
                // Track (sunken channel)
                RoundedRectangle(cornerRadius: DS.radiusSM)
                    .fill(DS.surfaceSubtle)

                // RMS fill — solid amber, no gradient. Grows from bottom.
                // Dimmed to `DS.textTertiary` opacity when audio is stopped
                // (Musician P1.4) so the "no signal" state reads as
                // visually de-emphasized, not just zero-height.
                RoundedRectangle(cornerRadius: DS.radiusSM)
                    .fill(DS.neonAmbar.opacity(dimmed ? 0.25 : 1.0))
                    .frame(height: max(rmsH, 0))

                // Peak tick — 1pt horizontal line at the peak position.
                // Drawn last so it sits on top of the fill. Clamped to
                // the track so a peak exactly at 0 dBFS stays visible.
                if peakH > 0 {
                    Rectangle()
                        .fill(DS.textPrimary)
                        .frame(width: barWidth, height: 1)
                        .offset(y: -(peakH - 1))
                }
            }
            .frame(width: barWidth, height: full)
            .overlay(
                RoundedRectangle(cornerRadius: DS.radiusSM)
                    .stroke(DS.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: DS.radiusSM))
        }
        .frame(width: barWidth, height: barHeight)
    }

    // MARK: - dBFS mapping

    /// Linear amplitude → dBFS. Clamps the floor at 1e-9 so log10 is
    /// finite (silence reads as -180 dB, which the height mapper then
    /// clamps to "empty bar" below `kDBMin`).
    ///
    ///     db = 20 * log10(max(amp, 1e-9))
    ///
    private func amplitudeToDB(_ amp: Float) -> Float {
        20.0 * log10(max(amp, 1e-9))
    }

    /// dBFS → bar height in points. Maps [kDBMin, kDBMax] linearly to
    /// [0, full]. Below `kDBMin` → 0 (empty). Above `kDBMax` → full
    /// (clipped, shouldn't happen for normalized peaks but defensive).
    private func dBToHeight(_ db: Float, full: CGFloat) -> CGFloat {
        if db <= kDBMin {
            return 0
        }
        if db >= kDBMax {
            return full
        }
        let norm = (db - kDBMin) / (kDBMax - kDBMin) // 0...1
        return CGFloat(norm) * full
    }
}

// MARK: - Preview

#if DEBUG
#Preview("MacroVUMeter — silence / mid / hot") {
    let preview = PreviewMacro()
    return VStack(spacing: 12) {
        MacroVUMeter(macro: preview, isProcessing: true)
        MacroVUMeter(macro: preview, isProcessing: true)
        MacroVUMeter(macro: preview, isProcessing: true)
        MacroVUMeter(macro: preview, isProcessing: false)
    }
    .padding()
    .background(Color.black)
}

/// Stand-in `MacroNode` subclass for previews — `MacroNode` requires a
/// full `NodeGraph` to construct, which is heavyweight for a preview.
/// We expose `telemetrySnapshot` via a tiny override that returns a
/// fixed value, so the preview renders without a live audio thread.
private final class PreviewMacro: MacroNode {
    override var telemetrySnapshot: MacroTelemetry {
        MacroTelemetry(peakL: 0.95, peakR: 0.78, rmsL: 0.50, rmsR: 0.40)
    }
    convenience init() {
        self.init(
            name: "PREVIEW",
            internalGraph: NodeGraph(),
            exposedPorts: [],
            portMappings: [:]
        )
    }
}
#endif
