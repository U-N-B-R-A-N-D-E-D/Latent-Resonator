import SwiftUI
import WebKit
import AppKit

// MARK: - Audio Visualizer XY Pad
//
// WebView-based audio visualizer that replaces the traditional XY pad.
// Shows real-time waveform + FFT while allowing touch control for Texture/Chaos.
//
// Touch interaction maps to macro parameters:
// - X axis: Texture (spectral density)
// - Y axis: Chaos (randomness)
//
// v2.0 Migration: Replaced ResonatorLane with MacroNode. All parameter access
// now goes through NodeGraph API. Visualization data comes from analysis nodes
// or macroNode parameters.

private typealias DS = LRConstants.DS

struct AudioVisualizerXYPad: NSViewRepresentable {
    @ObservedObject var macroNode: MacroNode
    let engine: NeuralEngine

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "visualizer")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.loadHTMLString(audioVisualizerHTMLContent, baseURL: nil)

        context.coordinator.webView = webView
        context.coordinator.macroNode = macroNode

        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // Update coordinator's macroNode reference when focus changes
        context.coordinator.macroNode = macroNode
        // Update audio data when macroNode publishes new snapshots
        context.coordinator.updateAudioData()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(macroNode: macroNode, engine: engine)
    }

    class Coordinator: NSObject, WKScriptMessageHandler {
        var webView: WKWebView?
        var macroNode: MacroNode
        let engine: NeuralEngine
        private var updateTimer: Timer?
        private var lastUpdateTime: Date = .distantPast

        init(macroNode: MacroNode, engine: NeuralEngine) {
            self.macroNode = macroNode
            self.engine = engine
            super.init()

            // Throttle updates to 30fps (33ms) to prevent overwhelming the WebView
            updateTimer = Timer.scheduledTimer(withTimeInterval: 1.0/30.0, repeats: true) { [weak self] _ in
                self?.updateAudioData()
            }
        }

        deinit {
            updateTimer?.invalidate()
        }

        func updateAudioData() {
            guard let webView = webView else { return }

            // v2.0: Get visualization data from macroNode parameters
            // These are updated by the audio graph analysis nodes
            let waveformData: [Float] = getWaveformData()
            let spectralData: [Float] = getSpectralData()

            // Skip if no data available
            guard !waveformData.isEmpty || !spectralData.isEmpty else { return }

            // Throttle: only update if enough time has passed
            let now = Date()
            guard now.timeIntervalSince(lastUpdateTime) > 0.03 else { return }
            lastUpdateTime = now

            let waveformJSON = waveformData.map { String($0) }.joined(separator: ",")

            // Downsample spectral data to 128 for performance
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

            let script = """
                window.updateAudioData({
                    waveform: [\(waveformJSON)],
                    fft: [\(fftJSON)]
                });
            """

            webView.evaluateJavaScript(script) { result, error in
                if let error = error {
                    print("AudioVisualizer: JS error: \(error)")
                }
            }
        }

        /// v2.0: Get waveform data from macroNode parameters or analysis nodes.
        /// Analysis nodes store their output in the macroNode's parameters.
        private func getWaveformData() -> [Float] {
            // Try to get waveform from macroNode parameters (set by analysis nodes)
            if let waveformParam = macroNode.parameters["waveformSnapshot"] as? [Float] {
                return waveformParam
            }

            // Fallback: look for analysis nodes in the internal graph that might have waveform data
            for node in macroNode.internalGraph.nodes.values {
                if node.nodeType == "spectral_analyzer" || node.nodeType == "scope" {
                    if let waveform = node.parameters["waveformOutput"] as? [Float] {
                        return waveform
                    }
                }
            }

            return []
        }

        /// v2.0: Get spectral data from macroNode parameters or analysis nodes.
        private func getSpectralData() -> [Float] {
            // Try to get spectral bins from macroNode parameters
            if let spectralParam = macroNode.parameters["spectralBins"] as? [Float] {
                return spectralParam
            }

            // Fallback: look for spectral analyzer nodes
            for node in macroNode.internalGraph.nodes.values {
                if node.nodeType == "spectral_analyzer" {
                    if let bins = node.parameters["magnitudeOutput"] as? [Float] {
                        return bins
                    }
                }
            }

            return []
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any],
                  let action = body["action"] as? String else { return }

            switch action {
            case "touchMove":
                if let x = body["x"] as? Double, let y = body["y"] as? Double {
                    // Map X/Y to Texture/Chaos macros
                    let texture = Float(x) * (LRConstants.macroRange.upperBound - LRConstants.macroRange.lowerBound) + LRConstants.macroRange.lowerBound
                    let chaos = Float(1.0 - y) * (LRConstants.macroRange.upperBound - LRConstants.macroRange.lowerBound) + LRConstants.macroRange.lowerBound

                    DispatchQueue.main.async { [weak self] in
                        guard let self = self else { return }

                        // v2.0: Update NodeGraph parameters (source of truth)
                        self.engine.nodeGraph.setParameter(
                            nodeId: self.macroNode.id,
                            key: "texture",
                            value: texture
                        )
                        self.engine.nodeGraph.setParameter(
                            nodeId: self.macroNode.id,
                            key: "chaos",
                            value: chaos
                        )

                        // Trigger macro application
                        self.engine.nodeGraph.setParameter(
                            nodeId: self.macroNode.id,
                            key: "applyMacroTexture",
                            value: 1.0
                        )
                        self.engine.nodeGraph.setParameter(
                            nodeId: self.macroNode.id,
                            key: "applyMacroChaos",
                            value: 1.0
                        )
                    }
                }
            case "touchEnd":
                // Trigger final macro application
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.engine.nodeGraph.setParameter(
                        nodeId: self.macroNode.id,
                        key: "applyMacroTexture",
                        value: 1.0
                    )
                    self.engine.nodeGraph.setParameter(
                        nodeId: self.macroNode.id,
                        key: "applyMacroChaos",
                        value: 1.0
                    )
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
<div class="axis-labels">
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
    // Preview requires a macroNode - create a simple one for preview purposes
    let previewEngine = NeuralEngine.preview
    let previewMacro = MacroNode.fromPreset(preset: .moogBass)

    AudioVisualizerXYPad(macroNode: previewMacro, engine: previewEngine)
        .frame(width: 400, height: 200)
}
