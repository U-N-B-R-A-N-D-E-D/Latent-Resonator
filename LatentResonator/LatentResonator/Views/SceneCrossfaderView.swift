import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Scene Crossfader View
//
// A/B scene selection and crossfader. Extracted from PerformanceMotherbaseView.

private typealias DS = LRConstants.DS

struct SceneCrossfaderView: View {
    @ObservedObject var engine: NeuralEngine

    var body: some View {
        VStack(spacing: DS.spacingMD) {
            HStack(spacing: DS.spacingMD) {
                Text("A")
                    .font(DS.font(DS.fontCaption, weight: .bold))
                    .foregroundColor(DS.info)
                    .frame(width: 12)

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(LinearGradient(
                                colors: [DS.info.opacity(0.4), DS.warning.opacity(0.4)],
                                startPoint: .leading,
                                endPoint: .trailing
                            ))
                            .frame(height: 6)
                            .frame(maxWidth: .infinity)
                            .offset(y: (geo.size.height - 6) / 2)

                        let thumbX = CGFloat(engine.crossfaderPosition) * (geo.size.width - 14)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(DS.textPrimary)
                            .frame(width: 14, height: 18)
                            .offset(x: thumbX, y: (geo.size.height - 18) / 2)
                    }
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let pos = Float(min(max(value.location.x / geo.size.width, 0), 1))
                                engine.crossfaderPosition = pos
                                engine.applyCrossfader()
                            }
                    )
                    .overlay(
                        ScrollWheelCatcher { delta in
                            let newVal = Double(engine.crossfaderPosition) + delta * 0.003
                            engine.crossfaderPosition = Float(min(1, max(0, newVal)))
                            engine.applyCrossfader()
                        }
                    )
                }
                .frame(height: 22)

                Text("B")
                    .font(DS.font(DS.fontCaption, weight: .bold))
                    .foregroundColor(DS.warning)
                    .frame(width: 12)
            }
            .help("Crossfader -- morph between Scene A and Scene B parameter snapshots (Left/Right arrows)")

            HStack {
                Text(String(format: "A: %d%%", Int((1 - engine.crossfaderPosition) * 100)))
                    .font(DS.font(DS.fontCaption2, weight: .medium))
                    .foregroundColor(DS.info.opacity(0.5))
                Spacer()
                Text(String(format: "B: %d%%", Int(engine.crossfaderPosition * 100)))
                    .font(DS.font(DS.fontCaption2, weight: .medium))
                    .foregroundColor(DS.warning.opacity(0.5))
            }

            sceneRowAB
            crossfadeDurationControl
        }
        .padding(.horizontal, DS.spacingXL)
        .padding(.vertical, DS.spacingMD)
    }

    private var sceneRowAB: some View {
        VStack(spacing: 3) {
            sceneRow(label: "A", selectedIndex: engine.crossfaderSceneAIndex) { index in
                engine.crossfaderSceneAIndex = index
                engine.applyScene(at: index)
                engine.crossfaderPosition = 0
            }
            sceneRow(label: "B", selectedIndex: engine.crossfaderSceneBIndex) { index in
                engine.crossfaderSceneBIndex = index
                engine.crossfaderPosition = 1
            }
        }
    }

    private func sceneRow(label: String, selectedIndex: Int, onTap: @escaping (Int) -> Void) -> some View {
        HStack(spacing: DS.spacingSM) {
            Text(label)
                .font(DS.font(DS.fontCaption, weight: .bold))
                .foregroundColor(DS.success.opacity(0.5))
                .frame(width: 10)
            ForEach(0..<min(8, engine.sceneBank.scenes.count), id: \.self) { index in
                Button(action: { onTap(index) }) {
                    Text("\(index + 1)")
                        .font(DS.font(DS.fontCaption, weight: .bold))
                        .foregroundColor(selectedIndex == index ? .black : DS.success.opacity(0.6))
                        .frame(width: 24, height: 22)
                        .background(selectedIndex == index ? DS.success : Color.gray.opacity(DS.inactiveOpacity))
                        .overlay(RoundedRectangle(cornerRadius: DS.radiusSM).stroke(DS.success.opacity(0.4), lineWidth: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.5)
                        .onEnded { [engine] _ in
                            DispatchQueue.main.async { engine.captureCurrentToScene(at: index) }
                        }
                )
                .animation(DS.stateTransition, value: selectedIndex)
                .help("Scene \(index + 1) -- TAP to load, LONG-PRESS to save current state")
            }
        }
    }

    private var crossfadeDurationControl: some View {
        HStack(spacing: DS.spacingMD) {
            Text("XFADE")
                .font(DS.font(DS.fontCaption2, weight: .bold))
                .foregroundColor(DS.textTertiary)
            Slider(
                value: Binding(
                    get: { engine.sceneBank.crossfadeDuration },
                    set: { [engine] val in
                        DispatchQueue.main.async {
                            var bank = engine.sceneBank
                            bank.crossfadeDuration = val
                            engine.sceneBank = bank
                        }
                    }
                ),
                in: 0.1...10.0
            )
            .accentColor(DS.success.opacity(0.6))
            .scrollableSlider(value: Binding(
                get: { engine.sceneBank.crossfadeDuration },
                set: { var b = engine.sceneBank; b.crossfadeDuration = $0; engine.sceneBank = b }
            ), range: 0.1...10.0)
            Text(String(format: "%.1fs", engine.sceneBank.crossfadeDuration))
                .font(DS.font(DS.fontCaption2, weight: .medium))
                .foregroundColor(DS.textSecondary)
                .frame(width: 28, alignment: .trailing)
        }
        .help("How long the crossfade transition takes between scenes")
    }
}
