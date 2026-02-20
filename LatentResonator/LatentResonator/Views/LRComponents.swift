import SwiftUI
import AppKit

// MARK: - LR Design System Components
//
// Reusable UI primitives that enforce consistent styling across all views.
// No @Published, no ObservableObject, no new state management.
// These are pure SwiftUI views that reference LRConstants.DS tokens.

private typealias DS = LRConstants.DS

// MARK: - LRToggle
//
// Binary toggle button with consistent styling.
// Used for: M(ute), S(olo), FREEZE, TRIGLESS, REC, ODE/SDE.

struct LRToggle: View {

    let label: String
    let isActive: Bool
    let activeColor: Color
    var fullWidth: Bool = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(DS.font(DS.fontBody, weight: .bold))
                .foregroundColor(isActive ? .black : DS.textTertiary)
                .frame(maxWidth: fullWidth ? .infinity : nil)
                .padding(.horizontal, DS.togglePaddingH)
                .padding(.vertical, DS.togglePaddingV)
                .background(isActive ? activeColor.opacity(DS.activeOpacity) : Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: DS.toggleCornerRadius)
                        .stroke(
                            isActive
                                ? activeColor.opacity(0.5)
                                : (isHovered ? DS.borderActive : DS.border),
                            lineWidth: 1
                        )
                )
                .cornerRadius(DS.toggleCornerRadius)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in isHovered = hovering }
        .animation(DS.stateTransition, value: isActive)
        .accessibilityLabel(label)
        .accessibilityValue(isActive ? "On" : "Off")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - LRSegmentPicker
//
// Horizontal segmented picker with consistent styling.
// Used for: ExcitationMode, FilterMode, SaturationMode, LFOTarget,
//           XYAxisMode, StepAdvanceMode, Phase selectors.

struct LRSegmentPicker<Item: Hashable>: View {

    let items: [Item]
    let selected: Item
    let color: Color
    let labelForItem: (Item) -> String
    let onSelect: (Item) -> Void

    var body: some View {
        HStack(spacing: DS.spacingXS) {
            ForEach(items, id: \.self) { item in
                LRSegmentButton(
                    label: labelForItem(item),
                    isSelected: item == selected,
                    color: color
                ) {
                    onSelect(item)
                }
            }
        }
    }
}

private struct LRSegmentButton: View {

    let label: String
    let isSelected: Bool
    let color: Color
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(DS.font(DS.fontCaption, weight: .bold))
                .foregroundColor(isSelected ? .black : color.opacity(0.6))
                .frame(maxWidth: .infinity)
                .padding(.vertical, DS.togglePaddingV)
                .background(isSelected ? color.opacity(DS.activeOpacity) : Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: DS.toggleCornerRadius)
                        .stroke(
                            isSelected
                                ? color.opacity(0.4)
                                : (isHovered ? color.opacity(0.3) : color.opacity(0.2)),
                            lineWidth: 1
                        )
                )
                .cornerRadius(DS.toggleCornerRadius)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in isHovered = hovering }
        .animation(DS.stateTransition, value: isSelected)
        .accessibilityLabel(label)
        .accessibilityValue(isSelected ? "Selected" : "")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - LRStatusRow
//
// Single-line status indicator: [dot] LABEL: VALUE | optional extras.
// Used for: bridge process status, ACE-STEP status, lane running state.

struct LRStatusRow: View {

    let dotColor: Color
    let label: String
    let value: String
    var valueColor: Color = DS.textSecondary
    var extras: [(String, Color)] = []
    var errorText: String? = nil

    var body: some View {
        HStack(spacing: DS.spacingMD) {
            Circle()
                .fill(dotColor)
                .frame(width: DS.dotSM, height: DS.dotSM)
                .shadow(color: dotColor.opacity(0.5), radius: 2)

            Text(label)
                .font(DS.font(DS.fontCaption, weight: .bold))
                .foregroundColor(DS.textTertiary)

            Text(value)
                .font(DS.font(DS.fontCaption, weight: .bold))
                .foregroundColor(valueColor)

            ForEach(Array(extras.enumerated()), id: \.offset) { _, extra in
                Text(extra.0)
                    .font(DS.font(DS.fontCaption, weight: .medium))
                    .foregroundColor(extra.1)
            }

            Spacer()

            if let err = errorText {
                Text(err.prefix(35))
                    .font(DS.font(DS.fontCaption2))
                    .foregroundColor(DS.danger.opacity(0.5))
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }
}

// MARK: - LRSectionHeader
//
// Consistent section header with tracking and optional right-aligned content.

struct LRSectionHeader: View {

    let title: String
    var color: Color = DS.textTertiary
    var trailing: String? = nil
    var trailingColor: Color = DS.textTertiary

    var body: some View {
        HStack {
            Text(title)
                .font(DS.font(DS.fontCaption, weight: .bold))
                .foregroundColor(color)
                .tracking(1)
            Spacer()
            if let trailing = trailing {
                Text(trailing)
                    .font(DS.font(DS.fontCaption, weight: .bold))
                    .foregroundColor(trailingColor)
            }
        }
    }
}

// MARK: - LRDivider
//
// Consistent 1px divider using design tokens.

struct LRDivider: View {
    var body: some View {
        Rectangle()
            .fill(DS.dividerColor)
            .frame(height: DS.dividerHeight)
    }
}

// MARK: - LRActionButton
//
// Trigger-style action button (INITIATE, ABORT, PANIC, DETAIL, REMOVE).

struct LRActionButton: View {

    enum Style { case primary, destructive, ghost }

    let label: String
    var icon: String? = nil
    var color: Color = DS.danger
    var style: Style = .primary
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.spacingMD) {
                if let icon = icon {
                    Image(systemName: icon).font(.system(size: DS.fontHeadline))
                }
                Text(label)
                    .font(DS.font(DS.fontHeadline, weight: .bold))
                    .tracking(2)
            }
            .foregroundColor(foregroundColor)
            .frame(maxWidth: .infinity)
            .padding(.vertical, DS.spacingLG)
            .background(backgroundColor)
            .overlay(Rectangle().stroke(color, lineWidth: style == .ghost ? 0 : 2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in isHovered = hovering }
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isButton)
    }

    private var foregroundColor: Color {
        switch style {
        case .primary:     return .black
        case .destructive: return color
        case .ghost:       return color.opacity(isHovered ? 0.8 : 0.5)
        }
    }

    private var backgroundColor: Color {
        switch style {
        case .primary:     return color
        case .destructive: return Color.black
        case .ghost:       return Color.clear
        }
    }
}

// MARK: - LRParamSlider
//
// Consistent parameter slider with label and value readout.
// Supports scroll wheel / trackpad input for precise adjustment.

struct LRParamSlider: View {

    let label: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    var format: String = "%.1f"
    var multiplier: Float = 1.0
    var color: Color = DS.success
    var hint: String? = nil
    var isHighImpact: Bool = false

    var body: some View {
        HStack(spacing: DS.spacingMD) {
            HStack(spacing: DS.spacingXS) {
                if isHighImpact {
                    Rectangle()
                        .fill(color.opacity(0.6))
                        .frame(width: 2, height: 12)
                        .cornerRadius(1)
                }
                Text(label)
                    .font(DS.font(DS.fontCaption2, weight: .bold))
                    .foregroundColor(DS.textTertiary)
                if let hint = hint {
                    Text("?")
                        .font(DS.font(DS.fontCaption2, weight: .bold))
                        .foregroundColor(DS.textDisabled)
                        .help(hint)
                }
            }
            .frame(width: 86, alignment: .leading)
            Slider(value: $value, in: range)
                .accentColor(color)
                .overlay(
                    ScrollWheelCatcher { delta in
                        let span = range.upperBound - range.lowerBound
                        let step = Float(delta) * span * 0.003
                        value = min(range.upperBound, max(range.lowerBound, value + step))
                    }
                )
            Text(String(format: format, value * multiplier))
                .font(DS.font(DS.fontCaption, weight: .medium))
                .foregroundColor(color.opacity(0.7))
                .frame(width: 54, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(String(format: format, value * multiplier))
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

// MARK: - Scroll Wheel Catcher (macOS)
//
// Transparent NSView overlay that intercepts scrollWheel events from
// trackpad or mouse and forwards the vertical delta to the caller.
// Used by RetroKnob and LRParamSlider for precision input.

struct ScrollWheelCatcher: NSViewRepresentable {

    let onScroll: (CGFloat) -> Void

    func makeNSView(context: Context) -> ScrollWheelNSView {
        let view = ScrollWheelNSView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ nsView: ScrollWheelNSView, context: Context) {
        nsView.onScroll = onScroll
    }
}

final class ScrollWheelNSView: NSView {

    var onScroll: ((CGFloat) -> Void)?

    override func scrollWheel(with event: NSEvent) {
        let delta = event.scrollingDeltaY
        guard abs(delta) > 0.01 else { return }
        onScroll?(delta)
    }
}

// MARK: - Slider + Scroll Modifier
//
// View extension for adding scroll-wheel support to any SwiftUI Slider.
// Usage: Slider(value: $val, in: range).scrollableSlider(value: $val, range: range)

extension View {
    func scrollableSlider(value: Binding<Float>, range: ClosedRange<Float>) -> some View {
        self.overlay(
            ScrollWheelCatcher { delta in
                let span = range.upperBound - range.lowerBound
                let step = Float(delta) * span * 0.003
                let newVal = value.wrappedValue + step
                value.wrappedValue = min(range.upperBound, max(range.lowerBound, newVal))
            }
        )
    }

    func scrollableSlider(value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        self.overlay(
            ScrollWheelCatcher { delta in
                let span = range.upperBound - range.lowerBound
                let step = delta * span * 0.003
                let newVal = value.wrappedValue + step
                value.wrappedValue = min(range.upperBound, max(range.lowerBound, newVal))
            }
        )
    }
}
