import SwiftUI

// MARK: - Retro Knob (Dial Futura)
// Flat precision dial. 270° sweep, arc indicator, monospaced readout.
// Supports drag and scroll wheel with improved sensitivity and feedback.
// v2.0 - Enhanced interaction and visual feedback

private typealias DS = LRConstants.DS

struct RetroKnob: View {

    let label: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    var accentColor: Color = .orange
    var size: CGFloat = LRConstants.knobSize
    var modulationRange: ClosedRange<Float>? = nil
    var helpText: String? = nil
    var sensitivity: CGFloat? = nil  // Optional custom sensitivity

    @State private var isDragging = false
    @State private var isHovered = false
    @State private var dragStartValue: Float = 0
    @State private var accumulatedDelta: CGFloat = 0

    // MARK: - Computed Properties

    private var normalizedValue: CGFloat {
        let clamped = max(range.lowerBound, min(range.upperBound, value))
        return CGFloat((clamped - range.lowerBound) / (range.upperBound - range.lowerBound))
    }

    private var rotationAngle: Double {
        -135.0 + Double(normalizedValue) * 270.0
    }

    private var dragSensitivity: CGFloat {
        if let custom = sensitivity { return custom }
        // Auto-calculate based on range - smaller range = higher sensitivity
        let rangeSpan = CGFloat(range.upperBound - range.lowerBound)
        return rangeSpan / (size > 50 ? 150 : 120)
    }

    private var valueFontSize: CGFloat {
        max(size * 0.16, 8)
    }

    private var displayValue: String {
        // Smart formatting based on range
        let span = range.upperBound - range.lowerBound
        if span >= 1000 {
            return String(format: "%.0f", value)
        } else if span >= 100 {
            return String(format: "%.1f", value)
        } else if span >= 10 {
            return String(format: "%.2f", value)
        } else {
            return String(format: "%.3f", value)
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: DS.spacingSM) {
            // Knob visualization
            ZStack {
                // Background track
                Circle()
                    .stroke(
                        DS.panelHollow,
                        style: StrokeStyle(lineWidth: 3, lineCap: .round)
                    )
                    .frame(width: size, height: size)

                // Modulation arc (if applicable)
                if let modRange = modulationRange {
                    let span = range.upperBound - range.lowerBound
                    let modLow = CGFloat((modRange.lowerBound - range.lowerBound) / span)
                    let modHigh = CGFloat((modRange.upperBound - range.lowerBound) / span)
                    Circle()
                        .trim(from: modLow * 0.75, to: modHigh * 0.75)
                        .stroke(
                            DS.neonTurquesa.opacity(0.3),
                            style: StrokeStyle(lineWidth: 4, lineCap: .round)
                        )
                        .frame(width: size, height: size)
                        .rotationEffect(.degrees(-225))
                }

                // Value arc
                Circle()
                    .trim(from: 0.0, to: normalizedValue * 0.75)
                    .stroke(
                        accentColor,
                        style: StrokeStyle(lineWidth: isDragging ? 4 : 3, lineCap: .round)
                    )
                    .frame(width: size, height: size)
                    .rotationEffect(.degrees(-225))
                    .shadow(color: accentColor.opacity(isDragging ? 0.6 : 0.3), radius: isDragging ? 4 : 2)

                // Indicator needle
                Rectangle()
                    .fill(isDragging ? accentColor : DS.textPrimary)
                    .frame(width: 2, height: size / 2 - 8)
                    .offset(y: -(size / 4 - 4))
                    .rotationEffect(.degrees(rotationAngle))
                    .shadow(color: accentColor.opacity(0.5), radius: 2)

                // Center cap
                Circle()
                    .fill(DS.knobCapFill)
                    .frame(width: size * 0.45, height: size * 0.45)
                    .overlay(
                        Circle()
                            .stroke(isHovered || isDragging ? accentColor : DS.border, lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(0.3), radius: 2, x: 0, y: 1)

                // Value display
                Text(displayValue)
                    .font(DS.font(valueFontSize, weight: isDragging ? .bold : .medium))
                    .foregroundColor(isDragging ? accentColor : accentColor.opacity(0.9))
                    .shadow(color: accentColor.opacity(isDragging ? 0.5 : 0.2), radius: isDragging ? 2 : 0)

                // Drag hint (shows when hovering)
                if isHovered && !isDragging {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: size * 0.2, weight: .bold))
                        .foregroundColor(accentColor.opacity(0.4))
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        if !isDragging {
                            isDragging = true
                            dragStartValue = value
                            accumulatedDelta = 0
                        }

                        // Vertical drag with sensitivity adjustment
                        let deltaY = -gesture.translation.height
                        accumulatedDelta = deltaY

                        let valueDelta = Float(accumulatedDelta / dragSensitivity)
                        var newValue = dragStartValue + valueDelta

                        // Clamp to range
                        newValue = max(range.lowerBound, min(range.upperBound, newValue))

                        // Apply if changed
                        if newValue != value {
                            value = newValue
                        }
                    }
                    .onEnded { _ in
                        isDragging = false
                        accumulatedDelta = 0
                    }
            )
            // Scroll wheel support - DISABLED: may interfere with drag gestures
            // .overlay(
            //     ScrollWheelCatcher { deltaY in
            //         let step = Float(deltaY) * (range.upperBound - range.lowerBound) * 0.005
            //         let newValue = value + step
            //         value = max(range.lowerBound, min(range.upperBound, newValue))
            //     }
            // )
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.15)) {
                    isHovered = hovering
                }
            }
            .scaleEffect(isDragging ? 0.95 : (isHovered ? 1.05 : 1.0))
            .animation(.easeInOut(duration: 0.15), value: isDragging)
            .animation(.easeInOut(duration: 0.15), value: isHovered)

            // Label
            Text(label.uppercased())
                .font(DS.font(DS.fontCaption, weight: .bold))
                .foregroundColor(isDragging ? DS.textPrimary : DS.textSecondary)
                .tracking(DS.trackingLab)
        }
        .ifLet(helpText) { view, text in view.help(text) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(displayValue)
        .accessibilityAdjustableAction { direction in
            let span = range.upperBound - range.lowerBound
            let step = span * 0.05
            switch direction {
            case .increment:
                value = min(range.upperBound, value + step)
            case .decrement:
                value = max(range.lowerBound, value - step)
            @unknown default: break
            }
        }
    }
}

// MARK: - Preview

#Preview("RetroKnob - Various States") {
    VStack(spacing: 30) {
        HStack(spacing: 40) {
            // Default state
            StatefulKnobPreview(label: "FREQ", range: 20...20000, value: 440, color: .orange)

            // With value
            StatefulKnobPreview(label: "RES", range: 0...1, value: 0.7, color: .cyan)

            // Small size
            StatefulKnobPreview(label: "GAIN", range: 0...2, value: 1.0, color: .green, size: 40)
        }

        HStack(spacing: 40) {
            // With modulation range
            StatefulKnobWithModulation(label: "CUTOFF", range: 20...20000, initialValue: 5000, color: .pink)
        }
    }
    .padding()
    .background(DS.titanioBottom)
}

// Helper for preview
private struct StatefulKnobPreview: View {
    let label: String
    let range: ClosedRange<Float>
    let initialValue: Float
    let color: Color
    var size: CGFloat = 56

    init(label: String, range: ClosedRange<Float>, value: Float, color: Color, size: CGFloat = 56) {
        self.label = label
        self.range = range
        self.initialValue = value
        self.color = color
        self.size = size
    }

    @State private var value: Float = 0

    var body: some View {
        RetroKnob(
            label: label,
            value: .constant(initialValue),
            range: range,
            accentColor: color,
            size: size
        )
        .onAppear { value = initialValue }
    }
}

private struct StatefulKnobWithModulation: View {
    let label: String
    let range: ClosedRange<Float>
    let initialValue: Float
    let color: Color

    @State private var value: Float = 0

    var body: some View {
        RetroKnob(
            label: label,
            value: .constant(initialValue),
            range: range,
            accentColor: color,
            modulationRange: (range.lowerBound + (range.upperBound - range.lowerBound) * 0.3)...(range.lowerBound + (range.upperBound - range.lowerBound) * 0.7)
        )
        .onAppear { value = initialValue }
    }
}