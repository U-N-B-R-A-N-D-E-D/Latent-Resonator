import SwiftUI

// MARK: - Latent XY Pad ("Drift Grid")
// X-axis: Guidance / CFG. Y-axis: Feedback / Recursion.
// Titanium gradient background, neon grid, semantic trail (neonAmbar).
// Cursor position throttled ~20 Hz. Overlays use .drawingGroup() for performance.

private typealias DS = LRConstants.DS

struct LatentXYPad: View {

    @Binding var x: Float
    @Binding var y: Float

    var xRange: ClosedRange<Float> = LRConstants.macroRange
    var yRange: ClosedRange<Float> = LRConstants.macroRange

    var xLabel: String = "TEXTURE"
    var yLabel: String = "CHAOS"

    /// When true, the pad displays the cursor position but disables drag gesture.
    /// Used for latent space visualization modes (e.g. spectral centroid/flatness).
    var isReadOnly: Bool = false

    /// Called once when a drag begins. Use to set suppressMacroApplication = true.
    var onDragStarted: (() -> Void)?
    /// Called on each throttled commit tick (~20 Hz) during drag. Apply macros here.
    var onCommit: (() -> Void)?
    /// Called once when a drag ends (after final commit). Use to apply macros + clear suppress.
    var onDragEnded: (() -> Void)?

    private let gridDivisions: Int = 10
    private let cursorSize: CGFloat = 14

    /// Throttled commit interval (seconds). ~33 Hz keeps the macro cascade
    /// manageable while feeling responsive during sustained drags.
    private let commitInterval: TimeInterval = 0.03

    @State private var isDragging = false
    @State private var isHovered = false

    // Local drag state -- updated at display rate for instant cursor feedback.
    // Only committed to the @Binding at the throttled rate above.
    @State private var localX: Float = 0
    @State private var localY: Float = 0
    @State private var commitTimer: Timer?
    @State private var didSyncInitial = false

    /// Trail ring buffer -- visualizes the recursive drift trajectory (§5.2).
    /// Capped at 60 points; oldest points fade out with decaying opacity.
    private let trailCapacity = 60
    @State private var trail: [(CGFloat, CGFloat)] = []

    // MARK: - Normalized Coordinates (read local values during drag)

    private var displayX: Float { isDragging ? localX : x }
    private var displayY: Float { isDragging ? localY : y }

    private var normalizedX: CGFloat {
        CGFloat((displayX - xRange.lowerBound) / (xRange.upperBound - xRange.lowerBound))
    }

    private var normalizedY: CGFloat {
        CGFloat((displayY - yRange.lowerBound) / (yRange.upperBound - yRange.lowerBound))
    }

    // MARK: - Body

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [DS.titanioTop, DS.titanioBottom],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                gridOverlay(in: geo.size).drawingGroup()
                trailOverlay(in: geo.size)
                crosshairOverlay(in: geo.size)
                cursorView(in: geo.size)
                scanlineOverlay(in: geo.size).drawingGroup()
                vignetteOverlay(in: geo.size).drawingGroup()

                if isHovered || isDragging {
                    coordinateReadout
                }

                // Axis labels
                VStack {
                    Spacer()
                    Text(xLabel)
                        .font(DS.font(DS.fontCaption, weight: .bold))
                        .foregroundColor(DS.phosphor.opacity(0.3))
                        .padding(.bottom, DS.spacingSM)
                }
                HStack {
                    Text(yLabel)
                        .font(DS.font(DS.fontCaption, weight: .bold))
                        .foregroundColor(DS.phosphor.opacity(0.3))
                        .rotationEffect(.degrees(-90))
                        .padding(.leading, DS.spacingSM)
                    Spacer()
                }
            }
            .border(isHovered ? DS.borderActive : DS.border, width: 1)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard !isReadOnly else { return }
                        if !isDragging {
                            isDragging = true
                            localX = x
                            localY = y
                            onDragStarted?()
                            startCommitTimer()
                        }
                        let nx = Float(min(max(value.location.x / geo.size.width, 0), 1))
                        let ny = Float(1.0 - min(max(value.location.y / geo.size.height, 0), 1))
                        localX = xRange.lowerBound + nx * (xRange.upperBound - xRange.lowerBound)
                        localY = yRange.lowerBound + ny * (yRange.upperBound - yRange.lowerBound)
                    }
                    .onEnded { _ in
                        guard !isReadOnly else { return }
                        stopCommitTimer()
                        commitValues()
                        isDragging = false
                        onDragEnded?()
                    }
            )
            .onHover { hovering in isHovered = hovering }
        }
        .frame(height: LRConstants.xyPadHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(xLabel) / \(yLabel) Pad")
        .accessibilityValue(String(format: "%@: %.2f, %@: %.2f", xLabel, x, yLabel, y))
        .onAppear {
            if !didSyncInitial {
                localX = x
                localY = y
                didSyncInitial = true
            }
        }
        .onChange(of: x) { _, newVal in
            if isReadOnly { localX = newVal }
        }
        .onChange(of: y) { _, newVal in
            if isReadOnly { localY = newVal }
        }
    }

    // MARK: - Throttled Commit

    private func startCommitTimer() {
        commitTimer?.invalidate()
        commitTimer = Timer.scheduledTimer(withTimeInterval: commitInterval, repeats: true) { _ in
            commitValues()
        }
    }

    private func stopCommitTimer() {
        commitTimer?.invalidate()
        commitTimer = nil
    }

    private func commitValues() {
        x = localX
        y = localY
        onCommit?()

        let nx = CGFloat((localX - xRange.lowerBound) / (xRange.upperBound - xRange.lowerBound))
        let ny = CGFloat((localY - yRange.lowerBound) / (yRange.upperBound - yRange.lowerBound))
        trail.append((nx, ny))
        if trail.count > trailCapacity { trail.removeFirst() }
    }

    // MARK: - Coordinate Readout

    private var coordinateReadout: some View {
        VStack {
            HStack {
                Spacer()
                Text(String(format: "%@: %.2f  %@: %.2f", xLabel, displayX, yLabel, displayY))
                    .font(DS.font(DS.fontCaption2, weight: .medium))
                    .foregroundColor(DS.phosphor.opacity(0.6))
                    .padding(.horizontal, DS.spacingMD)
                    .padding(.vertical, DS.spacingXS)
                    .background(DS.overlayReadout)
                    .cornerRadius(DS.radiusSM)
            }
            .padding(DS.spacingSM)
            Spacer()
        }
    }

    // MARK: - Trail (Recursive Drift Trajectory)

    private func trailOverlay(in size: CGSize) -> some View {
        Canvas { context, canvasSize in
            guard trail.count > 1 else { return }
            let count = trail.count
            for i in 1..<count {
                let opacity = Double(i) / Double(count) * 0.45
                let p0 = trail[i - 1]
                let p1 = trail[i]
                var path = Path()
                path.move(to: CGPoint(x: p0.0 * canvasSize.width, y: (1.0 - p0.1) * canvasSize.height))
                path.addLine(to: CGPoint(x: p1.0 * canvasSize.width, y: (1.0 - p1.1) * canvasSize.height))
                context.stroke(path, with: .color(DS.neonAmbar.opacity(opacity)), lineWidth: 1.5)
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Grid

    private func gridOverlay(in size: CGSize) -> some View {
        Canvas { context, canvasSize in
            let stepX = canvasSize.width / CGFloat(gridDivisions)
            let stepY = canvasSize.height / CGFloat(gridDivisions)

            for i in 0...gridDivisions {
                let xPos = CGFloat(i) * stepX
                let yPos = CGFloat(i) * stepY

                var vPath = Path()
                vPath.move(to: CGPoint(x: xPos, y: 0))
                vPath.addLine(to: CGPoint(x: xPos, y: canvasSize.height))
                context.stroke(vPath, with: .color(DS.phosphor.opacity(DS.gridLineOpacity)), lineWidth: 0.5)

                var hPath = Path()
                hPath.move(to: CGPoint(x: 0, y: yPos))
                hPath.addLine(to: CGPoint(x: canvasSize.width, y: yPos))
                context.stroke(hPath, with: .color(DS.phosphor.opacity(DS.gridLineOpacity)), lineWidth: 0.5)
            }
        }
    }

    // MARK: - Crosshair

    private func crosshairOverlay(in size: CGSize) -> some View {
        let posX = normalizedX * size.width
        let posY = (1.0 - normalizedY) * size.height

        return ZStack {
            Path { path in
                path.move(to: CGPoint(x: 0, y: posY))
                path.addLine(to: CGPoint(x: size.width, y: posY))
            }
            .stroke(DS.phosphor.opacity(DS.gridLineOpacity), lineWidth: 0.5)

            Path { path in
                path.move(to: CGPoint(x: posX, y: 0))
                path.addLine(to: CGPoint(x: posX, y: size.height))
            }
            .stroke(DS.phosphor.opacity(DS.gridLineOpacity), lineWidth: 0.5)
        }
    }

    // MARK: - Cursor (lightweight glow -- RadialGradient instead of blur)

    private func cursorView(in size: CGSize) -> some View {
        let posX = normalizedX * size.width
        let posY = (1.0 - normalizedY) * size.height

        return ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            DS.phosphor.opacity(isDragging ? 0.3 : 0.12),
                            DS.phosphor.opacity(0)
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: cursorSize * 1.25
                    )
                )
                .frame(width: cursorSize * 2.5, height: cursorSize * 2.5)

            Circle()
                .stroke(DS.phosphor.opacity(0.5), lineWidth: 1)
                .frame(width: cursorSize + 4, height: cursorSize + 4)

            Circle()
                .fill(DS.phosphor)
                .frame(width: cursorSize * 0.5, height: cursorSize * 0.5)
                .shadow(color: DS.phosphor, radius: isDragging ? 6 : 3)
        }
        .position(x: posX, y: posY)
        .animation(.interactiveSpring(response: 0.08), value: isDragging)
    }

    // MARK: - Scanlines

    private func scanlineOverlay(in size: CGSize) -> some View {
        Canvas { context, canvasSize in
            var yPos: CGFloat = 0
            let spacing: CGFloat = 3
            while yPos < canvasSize.height {
                var path = Path()
                path.move(to: CGPoint(x: 0, y: yPos))
                path.addLine(to: CGPoint(x: canvasSize.width, y: yPos))
                context.stroke(path, with: .color(.black.opacity(DS.scanlineOpacity)), lineWidth: 1)
                yPos += spacing
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Vignette (CRT edge darkening)

    private func vignetteOverlay(in size: CGSize) -> some View {
        Rectangle()
            .fill(
                RadialGradient(
                    gradient: Gradient(colors: [
                        Color.clear,
                        Color.black.opacity(DS.vignetteOpacity)
                    ]),
                    center: .center,
                    startRadius: min(size.width, size.height) * 0.3,
                    endRadius: max(size.width, size.height) * 0.7
                )
            )
            .allowsHitTesting(false)
    }
}
