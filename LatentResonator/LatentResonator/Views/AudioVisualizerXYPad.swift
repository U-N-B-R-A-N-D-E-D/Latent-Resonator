import SwiftUI
import WebKit
import AppKit

// MARK: - Audio Visualizer XY Pad
//
// WebView-based audio visualizer XY pad with **generic** value bindings.
// Owns a Canvas that renders the live waveform + FFT (read from
// `waveformSource` / `spectralSource` closures) while the user drags
// the touch cursor.
//
// X and Y are exposed as `Binding<Float>` so this widget is agnostic
// of macros, lanes, or any specific node type — the parent view decides
// which parameter goes on each axis.
//
// v2.0 Migration: removed `ResonatorLane` dependency. v2.1: also
// removed the hard-coded `MacroNode` / texture+chaos parameter coupling.
// The widget now reads visualisation data via plain closures and writes
// X/Y through generic `Binding<Float>`s.

private typealias DS = LRConstants.DS

struct AudioVisualizerXYPad: NSViewRepresentable {
    /// Current X value (e.g. focus macro's X-axis parameter). 2-way bound.
    @Binding var x: Float
    /// Current Y value (e.g. focus macro's Y-axis parameter). 2-way bound.
    @Binding var y: Float

    /// Range for the X axis. Used to map touch position → parameter value.
    var xRange: ClosedRange<Float> = 0...1
    /// Range for the Y axis. Used to map touch position → parameter value.
    var yRange: ClosedRange<Float> = 0...1

    /// Short label for the X axis (rendered in the HTML overlay).
    var xLabel: String = "X"
    /// Short label for the Y axis (rendered in the HTML overlay).
    var yLabel: String = "Y"

    /// Closure providing the latest waveform samples (-1...+1). Optional.
    /// Called at ~30 Hz on the main queue. Return an empty array to skip.
    var waveformSource: (() -> [Float])? = nil
    /// Closure providing the latest spectral magnitudes (0...1). Optional.
    /// Called at ~30 Hz on the main queue. Return an empty array to skip.
    var spectralSource: (() -> [Float])? = nil

    /// Optional notification fired after touch X/Y have been written to the
    /// bindings. Use for triggering downstream macro application, parameter
    /// smoothing, telemetry, etc.
    var onTouch: (() -> Void)? = nil

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "visualizer")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.loadHTMLString(audioVisualizerHTMLContent, baseURL: nil)

        context.coordinator.webView = webView
        context.coordinator.parent = self

        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // Keep the coordinator pointed at the latest binding snapshot so that
        // touch events write through to the most recent X/Y bindings.
        context.coordinator.parent = self
        context.coordinator.updateAudioData()
        context.coordinator.updateAxisLabels()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    class Coordinator: NSObject, WKScriptMessageHandler {
        var webView: WKWebView?
        /// Latest parent snapshot. Updated from `updateNSView` so that
        /// touch handlers always read the most recent bindings.
        var parent: AudioVisualizerXYPad
        private var updateTimer: Timer?
        private var lastUpdateTime: Date = .distantPast
        private var lastSentXLabel: String = ""
        private var lastSentYLabel: String = ""

        init(parent: AudioVisualizerXYPad) {
            self.parent = parent
            super.init()

            // Throttle updates to 30 Hz (33 ms) to keep the WebView painting smooth
            // without flooding the JS bridge.
            updateTimer = Timer.scheduledTimer(withTimeInterval: 1.0/30.0, repeats: true) { [weak self] _ in
                self?.updateAudioData()
            }
        }

        deinit {
            updateTimer?.invalidate()
        }

        func updateAudioData() {
            guard let webView = webView else { return }

            let waveformData: [Float] = parent.waveformSource?() ?? []
            let spectralData: [Float] = parent.spectralSource?() ?? []

            guard !waveformData.isEmpty || !spectralData.isEmpty else { return }

            let now = Date()
            guard now.timeIntervalSince(lastUpdateTime) > 0.03 else { return }
            lastUpdateTime = now

            let waveformJSON = waveformData.map { String($0) }.joined(separator: ",")

            let downsampledFFT: [Float]
            if spectralData.count > 128 {
                let strideValue = spectralData.count / 128
                downsampledFFT = stride(from: 0, to: spectralData.count, by: strideValue)
                    .prefix(128)
                    .map { spectralData[$0] }
            } else {
                downsampledFFT = spectralData
            }

            let fftJSON = downsampledFFT.map { String($0) }.joined(separator: ",")

            let script = "window.updateAudioData({waveform:[\(waveformJSON)],fft:[\(fftJSON)]});"

            webView.evaluateJavaScript(script) { _, error in
                if let error = error {
                    print("AudioVisualizer: JS error: \(error)")
                }
            }
        }

        /// Push the current X/Y axis labels into the HTML overlay if they
        /// changed since the last invocation. Cheap no-op when stable.
        func updateAxisLabels() {
            guard let webView = webView else { return }
            let xL = parent.xLabel
            let yL = parent.yLabel
            guard xL != lastSentXLabel || yL != lastSentYLabel else { return }
            lastSentXLabel = xL
            lastSentYLabel = yL
            let escX = xL.replacingOccurrences(of: "'", with: "\\'")
            let escY = yL.replacingOccurrences(of: "'", with: "\\'")
            let script = "window.updateAxisLabels && window.updateAxisLabels('\(escX)', '\(escY)');"
            webView.evaluateJavaScript(script, completionHandler: nil)
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any],
                  let action = body["action"] as? String else { return }

            switch action {
            case "touchMove":
                if let nx = body["x"] as? Double, let ny = body["y"] as? Double {
                    // Map normalized touch coords [0, 1] into the parent's X/Y
                    // ranges. Y is inverted so that moving the cursor "up" raises
                    // the bound value (HTML pointer y grows downward).
                    let xRange = parent.xRange
                    let yRange = parent.yRange
                    let xValue = Float(nx) * (xRange.upperBound - xRange.lowerBound) + xRange.lowerBound
                    let yValue = Float(1.0 - ny) * (yRange.upperBound - yRange.lowerBound) + yRange.lowerBound

                    let clampedX = min(max(xValue, xRange.lowerBound), xRange.upperBound)
                    let clampedY = min(max(yValue, yRange.lowerBound), yRange.upperBound)

                    DispatchQueue.main.async { [weak self] in
                        guard let self = self else { return }
                        self.parent.x = clampedX
                        self.parent.y = clampedY
                        self.parent.onTouch?()
                    }
                }
            case "touchEnd":
                DispatchQueue.main.async { [weak self] in
                    self?.parent.onTouch?()
                }
            default:
                break
            }
        }
    }
}

// MARK: - HTML/JS for Audio Visualizer

private let audioVisualizerHTMLContent = """
<!DOCTYPE html>
<html>
<head>
<style>
body {
    margin: 0;
    background: #0a0a0a;
    overflow: hidden;
    font-family: -apple-system, BlinkMacSystemFont, sans-serif;
}
#canvas {
    display: block;
    width: 100%;
    height: 100%;
}
.overlay {
    position: absolute;
    top: 8px;
    left: 8px;
    color: #00d4aa;
    font-size: 10px;
    opacity: 0.6;
    pointer-events: none;
}
.axis-labels {
    position: absolute;
    bottom: 8px;
    right: 8px;
    color: #00d4aa;
    font-size: 10px;
    text-align: right;
    opacity: 0.6;
    pointer-events: none;
}
</style>
</head>
<body>
<canvas id="canvas"></canvas>
<div class="overlay">DRIFT FIELD</div>
        <div id="axis-labels" class="axis-labels">
            <div>X: TEXTURE</div>
            <div>Y: CHAOS</div>
        </div>
<script>
const canvas = document.getElementById('canvas');
const ctx = canvas.getContext('2d');

function resizeCanvas() {
    const dpr = window.devicePixelRatio || 1;
    canvas.width = window.innerWidth * dpr;
    canvas.height = window.innerHeight * dpr;
    ctx.scale(dpr, dpr);
}
window.addEventListener('resize', resizeCanvas);
resizeCanvas();

let waveformData = [];
let fftData = [];

// Update the floating axis labels. Called from Swift via WKWebView.
window.updateAxisLabels = function(xLabel, yLabel) {
    const el = document.getElementById('axis-labels');
    if (el) {
        el.innerHTML = '<div>X: ' + xLabel + '</div><div>Y: ' + yLabel + '</div>';
    }
};

function drawWaveform(samples) {
    const width = canvas.width / (window.devicePixelRatio || 1);
    const height = canvas.height / (window.devicePixelRatio || 1);
    const mid = height / 2;

    ctx.strokeStyle = '#00d4aa';
    ctx.lineWidth = 2;
    ctx.beginPath();

    const step = width / samples.length;
    for (let i = 0; i < samples.length; i++) {
        const x = i * step;
        const y = mid + samples[i] * mid * 0.8;
        if (i === 0) {
            ctx.moveTo(x, y);
        } else {
            ctx.lineTo(x, y);
        }
    }
    ctx.stroke();
}

function drawFFT(bins) {
    const width = canvas.width / (window.devicePixelRatio || 1);
    const height = canvas.height / (window.devicePixelRatio || 1);

    const barWidth = width / bins.length;
    const barSpacing = 1;

    for (let i = 0; i < bins.length; i++) {
        const barHeight = bins[i] * height * 0.4;
        const x = i * (barWidth + barSpacing);
        const y = height - barHeight;

        // Gradient from cyan to amber
        const hue = 170 - (i / bins.length) * 60;
        ctx.fillStyle = `hsla(${hue}, 80%, 50%, 0.6)`;
        ctx.fillRect(x, y, barWidth - barSpacing, barHeight);
    }
}

function render() {
    const width = canvas.width / (window.devicePixelRatio || 1);
    const height = canvas.height / (window.devicePixelRatio || 1);

    // Fade effect
    ctx.fillStyle = 'rgba(10, 10, 10, 0.3)';
    ctx.fillRect(0, 0, width, height);

    // Draw FFT (background)
    if (fftData.length > 0) {
        drawFFT(fftData);
    }

    // Draw waveform (foreground)
    if (waveformData.length > 0) {
        drawWaveform(waveformData);
    }

    requestAnimationFrame(render);
}

render();

// Exposed function for Swift to call
window.updateAudioData = function(data) {
    if (data.waveform) {
        waveformData = data.waveform;
    }
    if (data.fft) {
        fftData = data.fft;
    }
};

// Touch handling
let isDragging = false;

canvas.addEventListener('pointerdown', (e) => {
    isDragging = true;
    handleTouch(e);
});

canvas.addEventListener('pointermove', (e) => {
    if (isDragging) {
        handleTouch(e);
    }
});

canvas.addEventListener('pointerup', () => {
    isDragging = false;
    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.visualizer) {
        window.webkit.messageHandlers.visualizer.postMessage({
            action: 'touchEnd'
        });
    }
});

canvas.addEventListener('pointerleave', () => {
    if (isDragging) {
        isDragging = false;
        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.visualizer) {
            window.webkit.messageHandlers.visualizer.postMessage({
                action: 'touchEnd'
            });
        }
    }
});

function handleTouch(e) {
    const rect = canvas.getBoundingClientRect();
    const x = (e.clientX - rect.left) / rect.width;
    const y = (e.clientY - rect.top) / rect.height;

    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.visualizer) {
        window.webkit.messageHandlers.visualizer.postMessage({
            action: 'touchMove',
            x: x,
            y: y
        });
    }
}
</script>
</body>
</html>
"""

// MARK: - Preview

#Preview {
    struct PreviewHost: View {
        @State private var x: Float = 0.5
        @State private var y: Float = 0.5
        var body: some View {
            AudioVisualizerXYPad(
                x: $x,
                y: $y,
                xRange: 0...1,
                yRange: 0...1,
                xLabel: "TEXTURE",
                yLabel: "CHAOS"
            )
            .frame(width: 400, height: 200)
        }
    }
    return PreviewHost()
}
