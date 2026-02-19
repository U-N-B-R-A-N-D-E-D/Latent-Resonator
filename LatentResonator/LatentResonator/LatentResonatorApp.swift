import SwiftUI
import AppKit

// MARK: - Latent Resonator Application
//
// Entry point for the Latent Resonator instrument.
//
// Architecture:
//   The NeuralEngine is created at the App level and injected into
//   the view hierarchy as an @EnvironmentObject. This ensures:
//
//   1. Single engine instance shared across the entire app
//   2. Deterministic shutdown: when the app terminates, shutdownAll()
//      is called, which stops audio, kills the Python bridge process,
//      and cleans up all resources (quit = close everything).
//
// White paper reference:
//   The "All-in-One" principle -- the user clicks Start, the system
//   handles everything (venv, deps, server, audio). Quit closes
//   every subprocess. No orphaned Python processes.

// MARK: - Main window content (isolated so Scene body has a single concrete type)

private struct MainWindowContent: View {
    @ObservedObject var engine: NeuralEngine

    var body: some View {
        RootView(engine: engine)
            .frame(
                minWidth: LRConstants.windowWidth,
                minHeight: LRConstants.windowHeight
            )
            .background(LRConstants.DS.surfacePrimary)
            .onReceive(
                NotificationCenter.default.publisher(
                    for: NSApplication.willTerminateNotification
                )
            ) { _ in
                engine.shutdownAll()
            }
    }
}

@main
struct LatentResonatorApp: App {

    @StateObject private var engine = NeuralEngine()

    var body: some Scene {
        WindowGroup {
            MainWindowContent(engine: engine)
        }
        .defaultSize(
            width: LRConstants.windowWidth,
            height: LRConstants.windowHeight
        )

        Settings {
            LRSettingsView(engine: engine)
        }
    }
}
