import SwiftUI

// MARK: - Template Browser View (Whitepaper v2 — Composition Starting Points)
//
// Visual browser for MultiLaneTemplates. Shows 5 factory templates as cards
// with role badges, description, and one-click load. Solves the "blank canvas"
// problem — users get a complete working composition immediately.

private typealias DS = LRConstants.DS

struct TemplateBrowserView: View {
    @ObservedObject var engine: NeuralEngine
    @Binding var isPresented: Bool

    let templates = MultiLaneTemplate.factoryTemplates

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: DS.spacingXS) {
                    Text("NEW COMPOSITION")
                        .font(DS.font(DS.fontTitle, weight: .bold))
                        .foregroundColor(DS.neonTurquesa)

                    Text("Start with a complete multi-lane setup")
                        .font(DS.font(DS.fontBody))
                        .foregroundColor(DS.textSecondary)
                }

                Spacer()

                Button(action: { isPresented = false }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(DS.textTertiary)
                }
                .buttonStyle(.plain)
                .help("Close template browser")
            }
            .padding(.horizontal, DS.spacingXL)
            .padding(.vertical, DS.spacingLG)

            LRDivider()

            // Template Grid
            ScrollView {
                LazyVStack(spacing: DS.spacingLG) {
                    ForEach(templates) { template in
                        TemplateCard(
                            template: template,
                            onSelect: {
                                applyTemplate(template)
                            }
                        )
                    }
                }
                .padding(DS.spacingXL)
            }

            // Footer with "blank" option
            HStack {
                Spacer()

                Button(action: {
                    // Just close — user keeps current blank state
                    isPresented = false
                }) {
                    Text("START BLANK (Keep Current)")
                        .font(DS.font(DS.fontCaption, weight: .bold))
                        .foregroundColor(DS.textTertiary)
                        .padding(.horizontal, DS.spacingLG)
                        .padding(.vertical, DS.spacingSM)
                        .overlay(
                            RoundedRectangle(cornerRadius: DS.radiusSM)
                                .stroke(DS.border, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)

                Spacer()
            }
            .padding(.bottom, DS.spacingLG)
        }
        .frame(width: 700, height: 600)
        .background(DS.surfacePopover)
    }

    private func applyTemplate(_ template: MultiLaneTemplate) {
        engine.applyTemplate(template)
        isPresented = false
    }
}

// MARK: - Template Card

struct TemplateCard: View {
    let template: MultiLaneTemplate
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.spacingSM) {
            // Header row: name + BPM
            HStack {
                Text(template.name.uppercased())
                    .font(DS.font(DS.fontTitle, weight: .bold))
                    .foregroundColor(DS.textPrimary)

                Spacer()

                // BPM badge
                HStack(spacing: DS.spacingXS) {
                    Image(systemName: "metronome")
                        .font(.system(size: 10))
                    Text("\(template.bpm) BPM")
                        .font(DS.font(DS.fontCaption, weight: .bold))
                }
                .foregroundColor(DS.neonAmbar)
                .padding(.horizontal, DS.spacingSM)
                .padding(.vertical, 3)
                .background(DS.neonAmbar.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: DS.radiusSM)
                        .stroke(DS.neonAmbar.opacity(0.3), lineWidth: 1)
                )
                .cornerRadius(DS.radiusSM)
            }

            // Role badges
            HStack(spacing: DS.spacingXS) {
                ForEach(template.lanes) { lane in
                    LaneRoleBadge(role: lane.role, isActive: true)
                }
            }

            // Description
            Text(template.description)
                .font(DS.font(DS.fontBody))
                .foregroundColor(DS.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(3)

            // Lane summary
            HStack {
                Text(template.summary)
                    .font(DS.font(DS.fontCaption2))
                    .foregroundColor(DS.textTertiary)

                Spacer()

                // Load button
                Button(action: onSelect) {
                    HStack(spacing: DS.spacingXS) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 10))
                        Text("LOAD")
                            .font(DS.font(DS.fontCaption, weight: .bold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, DS.spacingLG)
                    .padding(.vertical, DS.spacingSM)
                    .background(
                        LinearGradient(
                            colors: [DS.neonTurquesa, DS.neonTurquesa.opacity(0.8)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .cornerRadius(DS.radiusSM)
                    .shadow(color: DS.neonTurquesa.opacity(0.4), radius: 4)
                }
                .buttonStyle(.plain)
                .scaleEffect(isHovered ? 1.02 : 1.0)
            }
        }
        .padding(DS.spacingLG)
        .background(
            RoundedRectangle(cornerRadius: DS.radiusLG)
                .fill(DS.surfaceElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.radiusLG)
                .stroke(
                    isHovered ? DS.neonTurquesa.opacity(0.5) : DS.border,
                    lineWidth: isHovered ? 2 : 1
                )
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - LaneTemplateConfig Extension for Identifiable

extension LaneTemplateConfig: Identifiable {
    var id: String { name }
}

// MARK: - Preview

#Preview {
    @Previewable @State var isPresented = true

    TemplateBrowserView(
        engine: NeuralEngine(),
        isPresented: $isPresented
    )
}
