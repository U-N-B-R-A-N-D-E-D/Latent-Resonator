import SwiftUI
import AppKit
import Dispatch

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
//
// SIGTERM/SIGINT handling:
//   `NSApplication.willTerminateNotification` (below) only fires on
//   AppKit's own graceful-quit path (Cmd+Q, Dock Quit, `NSApp.terminate`).
//   A raw `kill`, a crash supervisor, or launchd stopping the process
//   sends SIGTERM directly and bypasses that notification entirely,
//   leaving the Python bridge subprocess running as an orphan. The
//   signal handlers installed in `init()` below cover that path too,
//   so `shutdownAll()` runs on every way this process can be asked to
//   stop, not just the one AppKit knows about.

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

    @StateObject private var engine: NeuralEngine

    // Held for the lifetime of the process: a `DispatchSourceSignal` is
    // cancelled (and cleanup silently never fires) if nothing keeps a
    // strong reference to it.
    private static var sigtermSource: DispatchSourceSignal?
    private static var sigintSource: DispatchSourceSignal?

    init() {
        let engine = NeuralEngine()
        _engine = StateObject(wrappedValue: engine)

        // Create log file at startup
        let logPath = ("~/Library/Application Support/LatentResonator/app.log" as NSString).expandingTildeInPath
        let msg = "[LatentResonatorApp] App initializing at \(Date())\n"
        try? msg.write(toFile: logPath, atomically: true, encoding: .utf8)

        Self.installSignalHandlers(engine: engine)
    }

    /// Ensures `shutdownAll()` -- and therefore the Python bridge subprocess
    /// getting terminated -- runs on SIGTERM/SIGINT, not only on AppKit's
    /// own graceful-quit path. See the file-level comment above for why
    /// this is necessary.
    private static func installSignalHandlers(engine: NeuralEngine) {
        // The default disposition for these signals is to terminate the
        // process immediately. Switching it to SIG_IGN first is required
        // so that disposition can't win a race against the dispatch
        // source below before it has a chance to run our cleanup.
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)

        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        term.setEventHandler { [weak engine] in
            engine?.shutdownAll()
            exit(0)
        }
        term.resume()
        sigtermSource = term

        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        interrupt.setEventHandler { [weak engine] in
            engine?.shutdownAll()
            exit(0)
        }
        interrupt.resume()
        sigintSource = interrupt
    }

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
