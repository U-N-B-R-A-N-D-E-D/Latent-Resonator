import SwiftUI

// MARK: - Retro Knob
// Precision dial with 60s lab aesthetic.
// 270-degree sweep with tick marks, indicator line, and monospaced readout.
// Supports drag (vertical) and scroll wheel / trackpad for precise control.

private typealias DS = LRConstants.DS

struct RetroKnob: View {

    let label: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    var accentColor: Color = .orange
    var size: CGFloat = LRConstants.knobSize
    var modulationRange: ClosedRange<Float>? = nil
    var helpText: String? = nil

    @State private var previousTranslation: CGFloat = 0
    @State private var isHovered = false

    // MARK: - Derived State

    private var normalizedValue: CGFloat {
        CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
    }

    private var rotationAngle: Double {
        -135.0 + Double(normalizedValue) * 270.0
    }

    private var valueFontSize: CGFloat {
        max(size * 0.15, DS.fontCaption2)
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: DS.spacingMD) {
            ZStack {
                Circle()
                    .stroke(DS.border, lineWidth: 3)
                    .frame(width: size, height: size)

                if let modRange = modulationRange {
                    let span = range.upperBound - range.lowerBound
                    let modLow = CGFloat((modRange.lowerBound - range.lowerBound) / span)
                    let modHigh = CGFloat((modRange.upperBound - range.lowerBound) / span)
                    Circle()
                        .trim(from: modLow * 0.75, to: modHigh * 0.75)
                        .stroke(
                            DS.info.opacity(0.25),
                            style: StrokeStyle(lineWidth: 5, lineCap: .round)
                        )
                        .frame(width: size, height: size)
                        .rotationEffect(.degrees(-225))
                }

                Circle()
                    .trim(from: 0.0, to: normalizedValue * 0.75)
                    .stroke(
                        accentColor,
                        style: StrokeStyle(lineWidth: 3, lineCap: .round)
                    )
                    .frame(width: size, height: size)
                    .rotationEffect(.degrees(-225))

                ForEach(0..<11, id: \.self) { i in
                    Rectangle()
                        .fill(i % 5 == 0 ? DS.borderActive : DS.textDisabled)
                        .frame(width: 1, height: i % 5 == 0 ? 8 : 4)
                        .offset(y: -(size / 2 + 6))
                        .rotationEffect(.degrees(-135.0 + Double(i) * 27.0))
                }

                Rectangle()
                    .fill(accentColor)
                    .frame(width: 2, height: size / 2 - 8)
                    .offset(y: -(size / 4 - 4))
                    .rotationEffect(.degrees(rotationAngle))

                Circle()
                    .fill(Color(white: 0.12))
                    .frame(width: size * 0.5, height: size * 0.5)
                    .overlay(
                        Circle()
                            .stroke(isHovered ? DS.borderActive : DS.border, lineWidth: 1)
                    )

                Text(String(format: "%.1f", value))
                    .font(DS.font(valueFontSize, weight: .medium))
                    .foregroundColor(accentColor)
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { gesture in
                        let currentY = gesture.translation.height
                        let delta = Float(-(currentY - previousTranslation) / 200.0)
                        let span = range.upperBound - range.lowerBound
                        let newValue = value + delta * span
                        value = min(range.upperBound, max(range.lowerBound, newValue))
                        previousTranslation = currentY
                    }
                    .onEnded { _ in
                        previousTranslation = 0
                    }
            )
            .overlay(
                ScrollWheelCatcher { deltaY in
                    let span = range.upperBound - range.lowerBound
                    let step = Float(deltaY) * span * 0.003
                    let newValue = value + step
                    value = min(range.upperBound, max(range.lowerBound, newValue))
                }
            )
            .onHover { hovering in isHovered = hovering }

            Text(label.uppercased())
                .font(DS.font(DS.fontCaption, weight: .bold))
                .foregroundColor(DS.textSecondary)
                .tracking(1)
        }
        .ifLet(helpText) { view, text in view.help(text) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(String(format: "%.1f", value))
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

