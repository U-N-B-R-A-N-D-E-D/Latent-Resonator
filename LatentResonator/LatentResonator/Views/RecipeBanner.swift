import SwiftUI

// MARK: - Recipe Banner (Whitepaper v2 — Composition Affordances)
//
// A dismissible banner that appears when a PatchRecipe is applied to a lane.
// Shows the recipe name, signal chain diagram, and a 2-3 sentence description
// explaining the sonic result and what parameters to tweak first.
//
// Design: Matches the titanium aesthetic (LRConstants.DS) with a subtle
// accent border. Dismisses via X button or automatically after 15 seconds.

private typealias DS = LRConstants.DS

struct RecipeBanner: View {

    let recipe: PatchRecipe
    let laneName: String
    var onDismiss: () -> Void

    @State private var opacity: Double = 0.0
    @State private var timer: Timer? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: DS.spacingSM) {
            // Header row: recipe name + dismiss button
            HStack {
                HStack(spacing: DS.spacingXS) {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 12))
                        .foregroundColor(DS.neonAmbar)
                    Text("RECIPE APPLIED")
                        .font(DS.font(DS.fontCaption2, weight: .bold))
                        .foregroundColor(DS.neonAmbar)
                }
                .padding(.horizontal, DS.spacingSM)
                .padding(.vertical, 2)
                .background(DS.neonAmbar.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: DS.radiusSM)
                        .stroke(DS.neonAmbar.opacity(0.3), lineWidth: 1)
                )
                .cornerRadius(DS.radiusSM)

                Spacer()

                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(DS.textTertiary)
                        .frame(width: 20, height: 20)
                        .background(DS.panelHollow)
                        .cornerRadius(DS.radiusSM)
                }
                .buttonStyle(.plain)
                .help("Dismiss recipe banner")
            }

            // Recipe title and chain diagram
            HStack(alignment: .firstTextBaseline, spacing: DS.spacingSM) {
                Text(recipe.name)
                    .font(DS.font(DS.fontTitle, weight: .bold))
                    .foregroundColor(DS.textPrimary)

                Text("on \(laneName)")
                    .font(DS.font(DS.fontBody))
                    .foregroundColor(DS.textSecondary)

                Spacer()

                // Signal chain diagram
                Text(recipe.chain)
                    .font(DS.font(DS.fontCaption, weight: .medium))
                    .foregroundColor(DS.neonTurquesa.opacity(0.8))
                    .padding(.horizontal, DS.spacingSM)
                    .padding(.vertical, 2)
                    .background(DS.neonTurquesa.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.radiusSM)
                            .stroke(DS.neonTurquesa.opacity(0.2), lineWidth: 1)
                    )
                    .cornerRadius(DS.radiusSM)
            }

            // Description
            Text(recipe.description)
                .font(DS.font(DS.fontBody))
                .foregroundColor(DS.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(3)
        }
        .padding(DS.spacingLG)
        .background(
            LinearGradient(
                colors: [
                    DS.titanioTop.opacity(0.95),
                    DS.titanioBottom.opacity(0.98)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.radiusLG)
                .stroke(
                    LinearGradient(
                        colors: [DS.neonAmbar.opacity(0.4), DS.neonAmbar.opacity(0.1)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .cornerRadius(DS.radiusLG)
        .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)
        .opacity(opacity)
        .onAppear {
            withAnimation(.easeIn(duration: 0.3)) {
                opacity = 1.0
            }
            // Auto-dismiss after 15 seconds
            timer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: false) { _ in
                dismiss()
            }
        }
        .onDisappear {
            timer?.invalidate()
            timer = nil
        }
    }

    private func dismiss() {
        timer?.invalidate()
        timer = nil
        withAnimation(.easeOut(duration: 0.2)) {
            opacity = 0.0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            onDismiss()
        }
    }
}

// MARK: - Recipe Banner Container (Manages Multiple Banners)

@MainActor
final class RecipeBannerController: ObservableObject {
    @Published var activeBanners: [RecipeBannerItem] = []

    struct RecipeBannerItem: Identifiable {
        let id = UUID()
        let recipe: PatchRecipe
        let laneName: String
    }

    func show(recipe: PatchRecipe, for laneName: String) {
        let item = RecipeBannerItem(recipe: recipe, laneName: laneName)
        activeBanners.append(item)
        // Keep only the last 3 banners to prevent clutter
        if activeBanners.count > 3 {
            activeBanners.removeFirst()
        }
    }

    func dismiss(id: UUID) {
        activeBanners.removeAll { $0.id == id }
    }
}

// MARK: - Recipe Banner Stack View

struct RecipeBannerStack: View {
    @StateObject private var controller = RecipeBannerController()

    var body: some View {
        VStack(spacing: DS.spacingSM) {
            ForEach(controller.activeBanners) { item in
                RecipeBanner(
                    recipe: item.recipe,
                    laneName: item.laneName
                ) {
                    controller.dismiss(id: item.id)
                }
            }
        }
        .padding(.horizontal, DS.spacingXL)
        .padding(.top, DS.spacingXL)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(!controller.activeBanners.isEmpty)
    }

    // Public API to show a banner
    func show(recipe: PatchRecipe, for laneName: String) {
        controller.show(recipe: recipe, for: laneName)
    }
}

// MARK: - View Modifier for Easy Integration

struct RecipeBannerModifier: ViewModifier {
    @StateObject private var controller = RecipeBannerController()

    func body(content: Content) -> some View {
        ZStack {
            content

            // Banner overlay
            VStack(spacing: DS.spacingSM) {
                ForEach(controller.activeBanners) { item in
                    RecipeBanner(
                        recipe: item.recipe,
                        laneName: item.laneName
                    ) {
                        controller.dismiss(id: item.id)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, DS.spacingXL)
            .padding(.top, DS.spacingXL)
            .allowsHitTesting(!controller.activeBanners.isEmpty)
        }
        .environmentObject(controller)
    }
}

extension View {
    func recipeBannerOverlay() -> some View {
        modifier(RecipeBannerModifier())
    }
}

// MARK: - Preview

#Preview {
    ZStack {
        DS.titanioBottom.ignoresSafeArea()

        RecipeBanner(
            recipe: .neuralDrone,
            laneName: "Lane 1"
        ) {}
        .padding()
    }
}
