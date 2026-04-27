import Foundation

// MARK: - Audio Visualizer HTML
//
// Lightweight Canvas 2D visualizer for real-time audio waveform + FFT display.
// Memory: ~5KB HTML/JS + ~4KB canvas framebuffer = ~9KB total.
//
// Design: Mecha Metal aesthetic with fade trails and neon colors.
// Touch-reactive XY pad drives Texture/Chaos macros.

let audioVisualizerHTML = """
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
<style>
* { margin: 0; padding: 0; box-sizing: border-box; }
body { 
    margin: 0; 
    background: #0a0a0a; 
    overflow: hidden; 
    font-family: -apple-system, system-ui;
    touch-action: none;
}
canvas { 
    display: block; 
    width: 100%;
    height: 100%;
}
#info {
    position: absolute;
    top: 8px;
    right: 8px;
    color: rgba(0, 255, 159, 0.6);
    font-size: 10px;
    font-family: monospace;
    pointer-events: none;
}
</style>
</head>
<body>
<canvas id="canvas"></canvas>
<div id="info">DRIFT FIELD VISUALIZER</div>
<script>
const canvas = document.getElementById('canvas');
const ctx = canvas.getContext('2d', { alpha: false });
let width, height;

function resize() {
    const dpr = window.devicePixelRatio || 1;
    const rect = canvas.getBoundingClientRect();
    width = rect.width * dpr;
    height = rect.height * dpr;
    canvas.width = width;
    canvas.height = height;
    ctx.scale(dpr, dpr);
    width = rect.width;
    height = rect.height;
}
window.addEventListener('resize', resize);
resize();

let waveform = new Array(256).fill(0);
let fft = new Array(128).fill(0);
let touchX = 0.5, touchY = 0.5;
let isDragging = false;
let lastUpdateTime = 0;

function draw(timestamp) {
    // Clear with fade trail (creates motion blur effect)
    ctx.fillStyle = 'rgba(10, 10, 10, 0.15)';
    ctx.fillRect(0, 0, width, height);
    
    // Draw grid
    ctx.strokeStyle = 'rgba(0, 255, 159, 0.05)';
    ctx.lineWidth = 1;
    ctx.beginPath();
    for (let i = 0; i <= 4; i++) {
        const y = (i / 4) * height;
        ctx.moveTo(0, y);
        ctx.lineTo(width, y);
        const x = (i / 4) * width;
        ctx.moveTo(x, 0);
        ctx.lineTo(x, height);
    }
    ctx.stroke();
    
    // Draw waveform (upper half)
    ctx.strokeStyle = '#00ff9f';
    ctx.lineWidth = 2;
    ctx.beginPath();
    for (let i = 0; i < waveform.length; i++) {
        const x = (i / waveform.length) * width;
        const y = height * 0.25 + waveform[i] * height * 0.2;
        if (i === 0) ctx.moveTo(x, y);
        else ctx.lineTo(x, y);
    }
    ctx.stroke();
    
    // Draw FFT as bars (lower half)
    const barWidth = width / fft.length;
    const maxFFT = Math.max(...fft, 0.001);
    for (let i = 0; i < fft.length; i++) {
        const x = i * barWidth;
        const normalized = fft[i] / maxFFT;
        const barHeight = normalized * height * 0.35;
        
        // Color gradient based on frequency
        const hue = (i / fft.length) * 60 + 300; // Purple to cyan
        ctx.fillStyle = `hsla(${hue}, 100%, 60%, 0.7)`;
        ctx.fillRect(x, height - barHeight, barWidth - 1, barHeight);
    }
    
    // Draw touch cursor
    if (isDragging) {
        ctx.fillStyle = 'rgba(0, 255, 159, 0.2)';
        ctx.beginPath();
        ctx.arc(touchX * width, touchY * height, 30, 0, Math.PI * 2);
        ctx.fill();
        
        ctx.strokeStyle = 'rgba(0, 255, 159, 0.6)';
        ctx.lineWidth = 2;
        ctx.beginPath();
        ctx.arc(touchX * width, touchY * height, 30, 0, Math.PI * 2);
        ctx.stroke();
    }
    
    // Crosshair at touch point
    ctx.strokeStyle = 'rgba(0, 255, 159, 0.4)';
    ctx.lineWidth = 1;
    ctx.beginPath();
    ctx.moveTo(touchX * width, 0);
    ctx.lineTo(touchX * width, height);
    ctx.moveTo(0, touchY * height);
    ctx.lineTo(width, touchY * height);
    ctx.stroke();
    
    requestAnimationFrame(draw);
}
draw();

// Message handler from Swift
window.updateAudioData = function(data) {
    if (data.waveform) waveform = data.waveform;
    if (data.fft) fft = data.fft;
    lastUpdateTime = Date.now();
};

// Touch/mouse handling
function handlePointerMove(e) {
    const rect = canvas.getBoundingClientRect();
    touchX = (e.clientX - rect.left) / rect.width;
    touchY = (e.clientY - rect.top) / rect.height;
    
    // Clamp to [0, 1]
    touchX = Math.max(0, Math.min(1, touchX));
    touchY = Math.max(0, Math.min(1, touchY));
    
    if (isDragging && window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.visualizer) {
        window.webkit.messageHandlers.visualizer.postMessage({
            action: 'touchMove',
            x: touchX,
            y: touchY
        });
    }
}

canvas.addEventListener('pointerdown', (e) => {
    isDragging = true;
    handlePointerMove(e);
});

canvas.addEventListener('pointermove', (e) => {
    if (isDragging) {
        handlePointerMove(e);
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

canvas.addEventListener('pointercancel', () => {
    isDragging = false;
});

// Prevent default touch behavior
canvas.addEventListener('touchstart', (e) => e.preventDefault(), { passive: false });
canvas.addEventListener('touchmove', (e) => e.preventDefault(), { passive: false });
</script>
</body>
</html>
"""
