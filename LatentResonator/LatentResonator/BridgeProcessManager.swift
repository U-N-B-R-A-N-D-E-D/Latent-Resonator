import Foundation

// MARK: - Bridge Process Manager
//
// Manages the lifecycle of the Python ACE-Step bridge server process.
// Implements the "All-in-One" principle: the Swift app handles the
// entire bridge lifecycle -- venv creation, dependency installation,
// server launch, and graceful termination.
//
// Launch flow:
//   1. Discover project structure via compile-time #filePath
//   2. Check for Python venv; create + install deps if missing
//   3. Launch ace_bridge_server.py as a child process
//   4. Monitor process health
//   5. Terminate on app quit (SIGTERM -> wait -> SIGKILL)
//
// White paper reference:
//   §6.1 -- The model as "Black Box Resonator"
//   The bridge is the conduit between Swift real-time audio and
//   Python-hosted ACE-Step 1.5 inference. Automation ensures
//   the user focuses on the instrument, not the infrastructure.

/// Performance profile for the ACE-Step bridge server.
/// Hardware-style toggles for trading quality vs. latency.
/// DECISION D6: Profile switching disabled during playback.
enum PerformanceProfile: String, CaseIterable, Identifiable {
    case ultra = "ULTRA"
    case balanced = "BALANCED"
    case studio = "STUDIO"

    var id: String { rawValue }

    /// CLI flags to pass to the bridge server for this profile.
    var cliFlags: [String] {
        switch self {
        case .ultra:
            return ["--performance-mode", "--max-steps", "4", "--quantization", "q8"]
        case .balanced:
            return ["--performance-mode", "--max-steps", "8", "--quantization", "q8"]
        case .studio:
            return ["--max-steps", "20", "--quantization", "fp16"]
        }
    }

    /// Human-readable description of the profile.
    var description: String {
        switch self {
        case .ultra:    return "Ultra-Low Latency (4 steps, Q8)"
        case .balanced: return "Balanced (8 steps, Q8)"
        case .studio:   return "Studio Quality (20 steps, FP16)"
        }
    }

    /// Short label for UI display.
    var shortLabel: String {
        switch self {
        case .ultra:    return "U"
        case .balanced: return "B"
        case .studio:   return "S"
        }
    }
}

final class BridgeProcessManager: ObservableObject {

    // MARK: - Server State

    /// Lifecycle state of the bridge server process.
    enum ServerState: String {
        case idle       = "IDLE"
        case settingUp  = "VENV SETUP"
        case installing = "INSTALLING"
        case launching  = "LAUNCHING"
        case running    = "RUNNING"
        case stopping   = "STOPPING"
        case error      = "ERROR"
    }

    // MARK: - Performance Profile

    /// Current performance profile. Defaults to balanced for general use.
    /// Changing profile requires bridge restart (disabled during playback per D6).
    @Published var currentProfile: PerformanceProfile = .balanced

    /// Whether profile switching is allowed (false during playback).
    var canSwitchProfile: Bool {
        return state != .running
    }

    // MARK: - Published State

    @Published var state: ServerState = .idle
    @Published var lastError: String?
    @Published var setupLog: [String] = []
    @Published var realtimeLog: [String] = []

    // MARK: - Process Management

    private var serverProcess: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?

    /// Set by NeuralEngine at init. Lets terminateServer() check for an
    /// in-flight /infer request before killing the process -- see
    /// waitForInFlightInferenceToClear().
    weak var aceBridge: ACEStepBridge?

    // MARK: - MPS Crash Latch
    //
    // Runtime backstop for LRConstants.ACEBridge.forceCPU. If a bridge we
    // launched on mps/auto ever dies unexpectedly (Metal validation abort in
    // `rsub`, see Constants.swift comment), we latch this true so every
    // subsequent launch -- regardless of forceCPU -- forces --device cpu.
    // Cleared only by a fresh app launch (intentionally not auto-cleared:
    // once we've seen this torch/Metal build abort on GPU, don't trust it
    // again for the rest of the session).
    @Published private(set) var mpsCrashLatched: Bool = false

    /// Device string ("cpu" / "auto") actually passed to the most recently
    /// launched bridge process. Set in `startServerProcess()`, read from the
    /// termination handler to decide whether a crash was GPU-related.
    private var lastLaunchedDevice: String = "cpu"

    /// Guards the one automatic CPU-fallback relaunch after an MPS crash so
    /// a bridge that keeps dying for an unrelated reason can't loop forever
    /// relaunching itself. One retry, then it's a normal `.error` state
    /// requiring the user to intervene (matches the existing behavior for
    /// every other launch failure).
    private var autoRecoveryAttempted = false

    // MARK: - Path Discovery (Compile-Time + Bundle Fallback)
    //
    // Primary: #filePath resolves to this source file at compile time.
    // Fallback: Bundle.main.resourcePath for distributed .app bundles where
    // #filePath points to a non-existent build machine path.
    //
    //   ~/Library/Application Support/LatentResonator/
    //     venv-ace-bridge/                 <- created here (user-writable)
    //   Scripts/                          <- from Bundle or #filePath
    //     ace_bridge_server.py
    //     requirements_bridge.txt

    private static let sourceFileURL = URL(fileURLWithPath: #filePath)

    /// Resolved scripts directory: prefers #filePath, falls back to Bundle resources.
    private static var scriptsDir: URL {
        // Primary: compile-time path (works in Xcode development builds)
        let devPath = sourceFileURL
            .deletingLastPathComponent()
            .appendingPathComponent("Scripts")
        if FileManager.default.fileExists(atPath: devPath.appendingPathComponent("ace_bridge_server.py").path) {
            return devPath
        }
        // Fallback: Bundle resources (works in archived .app distributions)
        if let resourcePath = Bundle.main.resourcePath {
            let bundlePath = URL(fileURLWithPath: resourcePath).appendingPathComponent("Scripts")
            if FileManager.default.fileExists(atPath: bundlePath.appendingPathComponent("ace_bridge_server.py").path) {
                return bundlePath
            }
        }
        // Last resort: return the dev path and let launchServer() handle the error
        print(">> BridgeProcessManager: WARNING -- Scripts directory not found via #filePath or Bundle")
        return devPath
    }

    private static var projectRoot: URL {
        // Primary: derive from #filePath (dev builds)
        let devRoot = sourceFileURL
            .deletingLastPathComponent()        // LatentResonator/ (inner)
            .deletingLastPathComponent()        // LatentResonator/ (outer)
            .deletingLastPathComponent()        // project root
        if FileManager.default.fileExists(atPath: devRoot.path) {
            return devRoot
        }
        // Fallback: Bundle's parent directory (distributed .app)
        if let resourcePath = Bundle.main.resourcePath {
            return URL(fileURLWithPath: resourcePath)
                .deletingLastPathComponent()    // Contents/
                .deletingLastPathComponent()    // .app bundle
                .deletingLastPathComponent()    // parent dir
        }
        return devRoot
    }

    /// Venv in Application Support so distributed apps (e.g. in /Applications) can create it
    /// without permission errors. projectRoot may be read-only for installed apps.
    private var venvDir: URL {
        LRConstants.appSupportVenvDir
    }

    private var pythonInVenv: URL {
        venvDir.appendingPathComponent("bin").appendingPathComponent("python3")
    }

    private var pipInVenv: URL {
        venvDir.appendingPathComponent("bin").appendingPathComponent("pip")
    }

    private var serverScript: URL {
        Self.scriptsDir.appendingPathComponent("ace_bridge_server.py")
    }

    private var requirementsFile: URL {
        Self.scriptsDir.appendingPathComponent("requirements_bridge.txt")
    }

    // MARK: - Model Path Auto-Discovery
    //
    // 3-location fallback chain (checked in order):
    //   1. UserDefaults override -- user-configured via Settings
    //   2. ~/Library/Application Support/LatentResonator/Models/
    //   3. {projectRoot}/models/ -- developer convenience
    //
    // Returns the first path containing a non-empty model subdirectory.

    private func discoverModelPath() -> String? {
        let fm = FileManager.default

        // Build the ordered search list
        var searchDirs: [URL] = []

        if let custom = UserDefaults.standard.string(forKey: LRConstants.ModelConfig.userDefaultsKey),
           !custom.isEmpty,
           LRConstants.ModelConfig.isModelPathSafe(custom, projectRoot: Self.projectRoot) {
            searchDirs.append(URL(fileURLWithPath: custom))
        }

        searchDirs.append(LRConstants.ModelConfig.defaultDirectory)
        searchDirs.append(LRConstants.ModelConfig.appSupportModelsDir)
        searchDirs.append(Self.projectRoot.appendingPathComponent("models"))

        for dir in searchDirs {
            if let found = scanForModel(in: dir, fileManager: fm) {
                log("Model weights discovered: \(found) (from \(dir.path))")
                return found
            }
        }

        log("No model weights found in any search path -- passthrough mode")
        return nil
    }

    /// Scans a directory for the first non-empty subdirectory (model weights).
    private func scanForModel(in dir: URL, fileManager fm: FileManager) -> String? {
        guard fm.fileExists(atPath: dir.path) else { return nil }

        do {
            let entries = try fm.contentsOfDirectory(atPath: dir.path)
            for entry in entries {
                let full = dir.appendingPathComponent(entry)
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: full.path, isDirectory: &isDir), isDir.boolValue {
                    let contents = try fm.contentsOfDirectory(atPath: full.path)
                    if !contents.isEmpty {
                        return full.path
                    }
                }
            }
        } catch {
            log("Model discovery error in \(dir.path): \(error.localizedDescription)")
        }

        return nil
    }

    // MARK: - Setup Queue

    private let setupQueue = DispatchQueue(
        label: "com.latentresonator.bridge.setup",
        qos: .userInitiated
    )

    // MARK: - Lifecycle

    deinit {
        terminateServer()
    }

    // MARK: - Launch (All-in-One)

    /// Launch the bridge server. Creates venv and installs deps if needed.
    /// Safe to call multiple times -- no-ops if already running.
    /// Uses the current `currentProfile` for performance settings.
    func launchServer() {
        guard state == .idle || state == .error else {
            log("Bridge already \(state.rawValue), skipping launch")
            return
        }

        setupQueue.async { [weak self] in
            self?.performLaunch()
        }
    }

    /// Switch performance profile.
    /// DECISION D6: Profile switching disabled during playback.
    /// - Parameters:
    ///   - profile: The new profile to switch to
    ///   - restart: If true, restarts the server to apply the new profile immediately
    /// - Returns: True if switch was successful, false if blocked (running state)
    @discardableResult
    func switchProfile(to profile: PerformanceProfile, restart: Bool = false) -> Bool {
        // D6: Disallow switching while bridge is running
        guard canSwitchProfile else {
            log("[WARN] Profile switch blocked: cannot switch while bridge is running (D6)")
            return false
        }

        let oldProfile = currentProfile
        currentProfile = profile
        log("Performance profile: \(oldProfile.rawValue) -> \(profile.rawValue)")

        // Restart server with new profile if requested and currently running
        if restart && state == .running {
            log("Restarting bridge with new profile...")
            terminateServer()
            // Wait for stop to complete, then restart
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.launchServer()
            }
        }

        return true
    }

    /// Full launch sequence: pre-flight -> setup if needed -> start server.
    private func performLaunch() {
        let fm = FileManager.default

        // Pre-flight: verify server script exists
        guard fm.fileExists(atPath: serverScript.path) else {
            updateState(.error)
            setError("Bridge script not found: \(serverScript.path)")
            return
        }

        log("Project root: \(Self.projectRoot.path)")
        log("Scripts dir:  \(Self.scriptsDir.path)")

        // --- Step 1: Python virtual environment ---

        let needsVenv = !fm.fileExists(atPath: pythonInVenv.path)

        if needsVenv {
            updateState(.settingUp)
            log("Creating Python virtual environment...")

            // Ensure Application Support/LatentResonator exists (venv parent)
            let venvParent = venvDir.deletingLastPathComponent()
            if !fm.fileExists(atPath: venvParent.path) {
                do {
                    try fm.createDirectory(at: venvParent, withIntermediateDirectories: true)
                } catch {
                    updateState(.error)
                    setError("Cannot create venv directory: \(error.localizedDescription)")
                    return
                }
            }

            // Find system Python 3.9+
            guard let systemPython = findSystemPython() else {
                updateState(.error)
                setError("Python 3.9+ not found. Install via: brew install python@3.11")
                return
            }

            log("System Python: \(systemPython)")

            // Create venv
            let (venvOk, venvOut) = runSyncProcess(systemPython, ["-m", "venv", venvDir.path])
            if !venvOk {
                updateState(.error)
                setError("Failed to create venv: \(venvOut)")
                return
            }
            log("[ok] Virtual environment created")

            // --- Step 2: Install dependencies ---

            updateState(.installing)
            log("Installing Python dependencies...")

            // Upgrade pip
            let (_, _) = runSyncProcess(pipInVenv.path, [
                "install", "--upgrade", "pip", "--quiet"
            ])

            // Install from requirements file
            if fm.fileExists(atPath: requirementsFile.path) {
                let (reqOk, reqOut) = runSyncProcess(pipInVenv.path, [
                    "install", "-r", requirementsFile.path, "--quiet"
                ])
                if !reqOk {
                    log("[WARN] Full requirements install failed, trying core deps...")
                    log("  \(reqOut)")
                    let (coreOk, coreOut) = runSyncProcess(pipInVenv.path, [
                        "install", "flask", "numpy", "--quiet"
                    ])
                    if !coreOk {
                        updateState(.error)
                        setError("Dependency install failed: \(coreOut)")
                        return
                    }
                }
            } else {
                // No requirements file -- install core deps inline
                let (coreOk, coreOut) = runSyncProcess(pipInVenv.path, [
                    "install", "flask", "numpy", "--quiet"
                ])
                if !coreOk {
                    updateState(.error)
                    setError("Dependency install failed: \(coreOut)")
                    return
                }
            }

            log("[ok] Dependencies installed")
            
            // --- Step 2b: Install ACE-Step package from GitHub (if not present) ---
            installACEStepPackageIfNeeded()
            
            // --- Step 2c: Download model if not present ---
            downloadModelIfNeeded()
            
        } else {
            log("Existing venv found: \(venvDir.lastPathComponent)")
            // Even with existing venv, check if ace_step is installed and model exists
            installACEStepPackageIfNeeded()
            downloadModelIfNeeded()
        }

        // --- Step 3: Start the bridge server (or reuse if already listening) ---

        let healthURL = LRConstants.ACEBridge.baseURLAsURL
            .appendingPathComponent(LRConstants.ACEBridge.healthEndpoint)

        // Reuse any already-running, healthy bridge -- regardless of forceCPU.
        // By the time a bridge answers /health it has already survived model
        // load (and, if running on MPS, the risky first-op window forceCPU
        // exists to avoid). Killing a proven-good bridge just to relaunch it
        // on CPU throws away the only session known to work and forces a slow
        // cold CPU boot for no safety benefit. forceCPU below only governs the
        // --device flag for a bridge we are about to launch fresh.
        if checkHealthSync(url: healthURL, timeout: 2.0) {
            updateState(.running)
            log("[Bridge:boot] ✓ Bridge already running on port \(LRConstants.ACEBridge.defaultPort) (reusing, device unchanged)")
            return
        }

        updateState(.launching)

        do {
            try startServerProcess()

            // Wait until the server is actually listening (model load can take a long time)
            let healthURL = LRConstants.ACEBridge.baseURLAsURL
                .appendingPathComponent(LRConstants.ACEBridge.healthEndpoint)
            let maxWait: TimeInterval = 120
            var pollInterval = LRConstants.ACEBridge.healthPollBootIntervalInitial
            var waited: TimeInterval = 0
            var up = false
            var attempt = 0

            while waited < maxWait {
                if serverProcess?.isRunning != true {
                    break
                }
                // Back off before each attempt: 1s, 2s, 4s, 8s, 16s cap.
                Thread.sleep(forTimeInterval: pollInterval)
                waited += pollInterval
                attempt += 1
                log("[Bridge:boot] Waiting for Python server... (attempt \(attempt), backoff \(String(format: "%.1f", pollInterval))s)")
                if checkHealthSync(url: healthURL, timeout: 2.0) {
                    up = true
                    break
                }
                pollInterval = min(pollInterval * 2, LRConstants.ACEBridge.healthPollBootIntervalCap)
            }

            if let process = serverProcess, process.isRunning, up {
                updateState(.running)
                log("[Bridge:boot] ✓ Bridge server running (PID: \(process.processIdentifier))")
            } else if serverProcess?.isRunning != true {
                updateState(.error)
                setError("Server process exited before ready")
            } else {
                updateState(.error)
                setError("Server did not respond to /health within \(Int(maxWait))s")
            }
        } catch {
            updateState(.error)
            setError("Failed to start server: \(error.localizedDescription)")
        }
    }

    /// Synchronous health check: returns true if the bridge responds with HTTP 200.
    private func checkHealthSync(url: URL, timeout: TimeInterval) -> Bool {
        var result = false
        let semaphore = DispatchSemaphore(value: 0)
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout

        URLSession.shared.dataTask(with: request) { _, response, error in
            if let http = response as? HTTPURLResponse {
                if http.statusCode == 200 {
                    result = true
                }
            }
            semaphore.signal()
        }.resume()

        _ = semaphore.wait(timeout: .now() + timeout + 0.5)
        return result
    }

    // MARK: - Server Process

    /// Start the bridge server with the current performance profile.
    /// - Parameter profile: The performance profile to use (defaults to currentProfile)
    private func startServerProcess(profile: PerformanceProfile? = nil) throws {
        let process = Process()
        process.executableURL = pythonInVenv

        let effectiveProfile = profile ?? currentProfile

        var args = [
            serverScript.path,
            "--host", "127.0.0.1",
            "--port", "\(LRConstants.ACEBridge.defaultPort)"
        ]

        // Auto-discover model weights in models/ directory.
        // When found, pass --model-path so the bridge loads the AI model
        // instead of running in passthrough mode.
        // #region agent log
        let rawModelPath = discoverModelPath()
        log("[DEBUG] discoverModelPath() returned: \(rawModelPath ?? "nil")")
        // #endregion
        if let modelPath = rawModelPath {
            args += ["--model-path", modelPath]
            // #region agent log
            log("[DEBUG] Adding --model-path to args. Current args count: \(args.count)")
            log("[DEBUG] Full command will be: \(pythonInVenv.path) \(args.joined(separator: " "))")
            // #endregion
            log("Model weights discovered: \(modelPath)")
        } else {
            // #region agent log
            log("[DEBUG] No model path found - server will run in passthrough mode")
            // #endregion
            log("No model weights found -- passthrough mode")
        }

        // Device: CPU when forceCPU is set OR a previous bridge this session
        // already crashed on mps/auto (mpsCrashLatched -- see the MPS Crash
        // Latch section above and the Constants.swift comment on forceCPU).
        // Otherwise auto (MPS on Apple Silicon).
        let forceCPUEffective = LRConstants.ACEBridge.forceCPU || mpsCrashLatched
        let device = forceCPUEffective ? "cpu" : "auto"
        args += ["--device", device]
        lastLaunchedDevice = device
        if mpsCrashLatched {
            log("Using CPU device (MPS crash latch engaged earlier this session)")
        } else if LRConstants.ACEBridge.forceCPU {
            log("Using CPU device (forceCPU default -- MPS disabled due to rsub crash risk)")
        }

        // Performance profile: apply profile-specific CLI flags
        args += effectiveProfile.cliFlags
        log("Performance profile: \(effectiveProfile.rawValue) - \(effectiveProfile.description)")

        // Structured boot lifecycle log: one line, all salient facts.
        log("[Bridge:boot] Starting ACE-Step bridge on 127.0.0.1:\(LRConstants.ACEBridge.defaultPort) (profile=\(effectiveProfile.rawValue), device=\(device))")

        // Mark the boot start time so the async health client can report model-ready latency.
        aceBridge?.bridgeStartTime = Date()

        process.arguments = args
        process.currentDirectoryURL = Self.scriptsDir

        // Inherit PATH but activate venv
        var env = ProcessInfo.processInfo.environment
        env["VIRTUAL_ENV"] = venvDir.path
        if forceCPUEffective {
            env["LATENT_RESONATOR_FORCE_CPU"] = "1"
        }
        env["PATH"] = "\(venvDir.path)/bin:" + (env["PATH"] ?? "")
        // Ensure Python doesn't buffer output
        env["PYTHONUNBUFFERED"] = "1"
        // MPS fallback: enable for any ops not yet fully implemented in MPS
        env["PYTORCH_ENABLE_MPS_FALLBACK"] = "1"
        // MPS memory fix for ACE-Step 1.5 v0.1.0+ (prevents "MPS backend out of memory")
        env["PYTORCH_MPS_HIGH_WATERMARK_RATIO"] = "0.0"
        process.environment = env

        // Capture stdout
        let stdout = Pipe()
        process.standardOutput = stdout
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let str = String(data: data, encoding: .utf8) else { return }
            for line in str.components(separatedBy: .newlines) where !line.isEmpty {
                guard self?.isMacOSNetworkNoise(line) == false else { continue }
                self?.log("[server] \(line)")
                DispatchQueue.main.async {
                    self?.realtimeLog.append(line)
                    if (self?.realtimeLog.count ?? 0) > 100 {
                        self?.realtimeLog.removeFirst(20)
                    }
                }
            }
        }

        // Capture stderr (Flask logs to stderr)
        let stderr = Pipe()
        process.standardError = stderr
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let str = String(data: data, encoding: .utf8) else { return }
            for line in str.components(separatedBy: .newlines) where !line.isEmpty {
                guard self?.isMacOSNetworkNoise(line) == false else { continue }
                self?.log("[server] \(line)")
                DispatchQueue.main.async {
                    self?.realtimeLog.append(line)
                    if (self?.realtimeLog.count ?? 0) > 100 {
                        self?.realtimeLog.removeFirst(20)
                    }
                }
            }
        }

        // Handle unexpected termination
        process.terminationHandler = { [weak self] proc in
            guard let self = self else { return }
            let code = proc.terminationStatus
            self.log("[Bridge:dead] Bridge process exited (code=\(code)) — passthrough active, will retry on next inference")

            // Clean up pipe handlers
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil

            DispatchQueue.main.async {
                self.serverProcess = nil

                guard self.state != .stopping else {
                    // Expected shutdown
                    self.state = .idle
                    return
                }

                // Unexpected termination. A crash while running on mps/auto
                // is exactly the failure mode LRConstants.ACEBridge.forceCPU
                // exists to avoid (Metal validation abort inside `rsub` --
                // see the Constants.swift comment). Latch CPU for every
                // future launch this session, and self-heal once instead of
                // leaving the instrument dead until the user restarts the
                // app -- graceful degradation, per .cursor/AGENTS.md
                // invariant #7 ("system must function in all modes").
                self.state = .error
                let crashedOnGPU = self.lastLaunchedDevice != "cpu"

                if crashedOnGPU {
                    self.mpsCrashLatched = true
                    self.lastError = "MPS crashed (exit \(code)) -- falling back to CPU"
                    self.log("[WARN] Bridge crashed on device '\(self.lastLaunchedDevice)' -- latching forceCPU for all future launches")

                    if !self.autoRecoveryAttempted {
                        self.autoRecoveryAttempted = true
                        self.log("Attempting one automatic CPU-fallback relaunch...")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                            self?.launchServer()
                        }
                    } else {
                        self.log("[WARN] Already attempted a CPU-fallback relaunch this session -- leaving bridge stopped")
                    }
                } else {
                    self.lastError = "Server exited unexpectedly (code \(code))"
                }
            }
        }

        try process.run()

        serverProcess = process
        stdoutPipe = stdout
        stderrPipe = stderr
    }

    // MARK: - Terminate Server

    /// Bounded wait for any in-flight /infer request to finish before the bridge
    /// process is torn down. Killing the server mid-request destroys real
    /// inference output and surfaces as a -1005 "network connection lost" error
    /// on the Swift side for no reason. Capped at
    /// `LRConstants.ACEBridge.inFlightShutdownGrace` so callers -- including app
    /// quit -- never hang indefinitely on a stuck request.
    private func waitForInFlightInferenceToClear() {
        guard let aceBridge = aceBridge, aceBridge.isInferInFlight else { return }
        let grace = LRConstants.ACEBridge.inFlightShutdownGrace
        log("[WARN] /infer in flight -- delaying bridge stop up to \(Int(grace))s so it can finish")
        let deadline = Date().addingTimeInterval(grace)
        while aceBridge.isInferInFlight && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
        }
        if aceBridge.isInferInFlight {
            log("[WARN] /infer still in flight after grace period -- stopping bridge anyway")
        } else {
            log("[ok] In-flight /infer cleared -- proceeding with bridge stop")
        }
    }

    /// Terminate the bridge server so it never survives app quit.
    /// - If we started the process: HTTP /shutdown, SIGTERM, wait up to 3s, then SIGKILL (synchronous).
    /// - If we reused an existing server (no process handle): POST /shutdown so that server exits.
    /// - First waits (bounded) for any in-flight /infer request to clear -- see
    ///   waitForInFlightInferenceToClear(). Callers that restart the bridge
    ///   (profile switch, PERFORM mode entry) effectively "queue" behind this wait
    ///   instead of cutting off the one inference that was actually working.
    func terminateServer() {
        waitForInFlightInferenceToClear()

        if let process = serverProcess, process.isRunning {
            // We own this process -- kill it synchronously so quit never leaves an orphan
            DispatchQueue.main.async { [weak self] in
                self?.state = .stopping
            }
            log("Stopping bridge server (PID: \(process.processIdentifier))...")
            requestShutdownViaHTTPSync()
            if process.isRunning {
                process.terminate()
            }

            let deadline = Date().addingTimeInterval(2.0)
            while process.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.15)
            }
            if process.isRunning {
                log("Sending SIGKILL...")
                kill(process.processIdentifier, SIGKILL)
                Thread.sleep(forTimeInterval: 0.3)
            }
            // Belt and suspenders: ensure nothing is left on the port
            killProcessOnPortSync(port: LRConstants.ACEBridge.defaultPort)
            serverProcess = nil
            stdoutPipe = nil
            stderrPipe = nil
            DispatchQueue.main.async { [weak self] in
                self?.state = .idle
            }
            return
        }

        // Reused server (we didn't start it) -- HTTP /shutdown then kill by port so it never survives quit
        if state == .running {
            log("Stopping bridge (reused instance)...")
            requestShutdownViaHTTPSync()
            killProcessOnPortSync(port: LRConstants.ACEBridge.defaultPort)
        }
        DispatchQueue.main.async { [weak self] in
            self?.state = .idle
        }
    }

    /// Synchronous POST /shutdown so the bridge exits before the app quits (reused or owned).
    private func requestShutdownViaHTTPSync() {
        let url = LRConstants.ACEBridge.baseURLAsURL
            .appendingPathComponent("shutdown")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 2.0

        let semaphore = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { _, _, _ in
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 1.5)
    }

    /// Kill any process listening on the given port (e.g. orphaned bridge). Used on quit when we reused.
    private func killProcessOnPortSync(port: Int) {
        let (ok, output) = runSyncProcess("/usr/sbin/lsof", ["-ti", ":\(port)"])
        guard ok, !output.isEmpty else { return }
        let pids = output.split(separator: "\n").compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
        let selfPid = ProcessInfo.processInfo.processIdentifier
        for pid in pids where pid != selfPid && pid > 0 {
            log("Killing process on port \(port) (PID: \(pid))...")
            kill(pid, SIGTERM)
            Thread.sleep(forTimeInterval: 0.5)
            kill(pid, SIGKILL)
        }
    }

    /// Whether the server process is currently alive.
    var isRunning: Bool {
        serverProcess?.isRunning == true
    }

    // MARK: - Python Discovery

    /// Find a usable Python 3.9-3.12 on the system.
    /// ACE-Step dependencies (spacy) require Python <3.13.
    /// Prefer explicit 3.12/3.11 paths before the generic python3.
    private func findSystemPython() -> String? {
        let candidates = [
            "/opt/homebrew/bin/python3.12", // Homebrew Python 3.12 (preferred)
            "/opt/homebrew/bin/python3.11", // Homebrew Python 3.11
            "/usr/local/bin/python3",       // Intel Homebrew
            "/usr/bin/python3",             // macOS system Python
            "/opt/homebrew/bin/python3",    // Apple Silicon Homebrew (may be 3.13+)
        ]

        for path in candidates where FileManager.default.fileExists(atPath: path) {
            // Verify version >= 3.9 and < 3.13 (ACE-Step deps require <3.13)
            let (ok, output) = runSyncProcess(path, [
                "-c", "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')"
            ])
            if ok {
                let version = output.trimmingCharacters(in: .whitespacesAndNewlines)
                let parts = version.split(separator: ".")
                if parts.count >= 2,
                   let major = Int(parts[0]), let minor = Int(parts[1]),
                   major >= 3, minor >= 9, minor < 13 {
                    return path
                }
            }
        }

        // Fallback: `which python3`
        let (ok, output) = runSyncProcess("/usr/bin/which", ["python3"])
        if ok {
            let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty, FileManager.default.fileExists(atPath: path) {
                return path
            }
        }

        return nil
    }

    // MARK: - Synchronous Process Runner

    /// Run a subprocess synchronously and return (success, combinedOutput).
    @discardableResult
    private func runSyncProcess(_ executable: String, _ arguments: [String]) -> (Bool, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""

            return (process.terminationStatus == 0, output)
        } catch {
            return (false, error.localizedDescription)
        }
    }

    // MARK: - Logging & State Helpers

    /// Thread-safe state update on main queue.
    private func updateState(_ newState: ServerState) {
        DispatchQueue.main.async { [weak self] in
            self?.state = newState
        }
    }

    /// Thread-safe error update.
    private func setError(_ message: String) {
        log("ERROR: \(message)")
        DispatchQueue.main.async { [weak self] in
            self?.lastError = message
        }
    }

    /// Append a log line (thread-safe, bounded).
    private func log(_ message: String) {
        if isMacOSNetworkNoise(message) { return }
        print(">> Bridge: \(message)")
        DispatchQueue.main.async { [weak self] in
            self?.setupLog.append(message)
            // Keep log bounded to prevent memory growth
            if (self?.setupLog.count ?? 0) > 200 {
                self?.setupLog.removeFirst(50)
            }
        }
    }

    /// Strips macOS URLSession/network-framework noise that is not a real Python
    /// server log. These lines are emitted by the OS network stack on loopback
    /// during connection refused / socket teardown and bury actual bridge status.
    private func isMacOSNetworkNoise(_ line: String) -> Bool {
        let lowercased = line.lowercased()
        let noiseMarkers = [
            "nw_socket_handle_socket_event",
            "nw_protocol_socket_set_no_wake_from_sleep",
            "nw_endpoint_flow_failed_with_error",
            "nw_socket_connect",
            "nw_connection_",
            "nw_protocol_",
            "nw_endpoint_",
            "nw_path_",
            "so_nowakefromsleep",
            "setsockopt so_"
        ]
        return noiseMarkers.contains { lowercased.contains($0) }
    }
    
    // MARK: - ACE-Step Package Auto-Installation
    
    /// Check if ace_step package is installed, and install from GitHub if not.
    private func installACEStepPackageIfNeeded() {
        log("Checking ACE-Step package...")

        // Test if ace_step can be imported (multiple import patterns)
        let importTests = [
            ("acestep", "import acestep; print('acestep available')"),
            ("acestep.pipeline_ace_step", "from acestep.pipeline_ace_step import ACEStepPipeline; print('ACEStepPipeline available')"),
            ("ace_step", "import ace_step; print('ace_step available')"),
            ("ace-step", "import ace_step; print('ace-step available')"),
        ]

        var importResults: [String: String] = [:]
        for (name, code) in importTests {
            let (ok, output) = runSyncProcess(pythonInVenv.path, ["-c", code])
            importResults[name] = ok ? "OK: \(output.trimmingCharacters(in: .whitespacesAndNewlines))" : "FAIL: \(output.trimmingCharacters(in: .whitespacesAndNewlines))"
        }

        // Check which imports succeeded - MUST have acestep.pipeline_ace_step fully working
        let canImportBasic = importResults["acestep"]?.hasPrefix("OK:") ?? false
        let canImportPipeline = importResults["acestep.pipeline_ace_step"]?.hasPrefix("OK:") ?? false
        let canImport = canImportBasic && canImportPipeline

        if canImport {
            log("[ok] ACE-Step package already installed (verified pipeline import)")
            return
        }

        // If pipeline import fails but basic acestep exists, we may need to install missing deps
        if canImportBasic && !canImportPipeline {
            log("[WARN] acestep package exists but pipeline import fails - likely missing dependencies")
            log("[INFO] Installing inference dependencies from requirements_bridge.txt...")
            updateState(.installing)

            // Single source of truth: requirements_bridge.txt (base + inference deps).
            // No hardcoded package list here — keeps the venv spec in one place.
            let reqs = Self.projectRoot.appendingPathComponent(
                "LatentResonator/LatentResonator/Scripts/requirements_bridge.txt"
            )
            let (depsOk, depsOut) = runSyncProcess(pipInVenv.path, [
                "install", "-r", reqs.path, "--quiet"
            ])
            
            if depsOk {
                log("[ok] Dependencies installed successfully")
                // Re-test import
                let (retestOk, retestOut) = runSyncProcess(pythonInVenv.path, ["-c", "from acestep.pipeline_ace_step import ACEStepPipeline; print('pipeline_ok')"])
                if retestOk {
                    log("[ok] Pipeline import verified after dependency install")
                    return
                } else {
                    log("[WARN] Pipeline import still fails after deps install: \(retestOut)")
                }
            } else {
                log("[WARN] Failed to install dependencies: \(depsOut)")
            }
        }
        
        log("ACE-Step package not found. Installing from GitHub...")
        updateState(.installing)
        
        let aceStepRepoDir = Self.projectRoot.appendingPathComponent("ACE-Step")
        
        // Clone or update the ACE-Step repo
        if FileManager.default.fileExists(atPath: aceStepRepoDir.path) {
            log("Updating ACE-Step repo...")
            let _ = runSyncProcess("/usr/bin/git", ["-C", aceStepRepoDir.path, "pull"])
        } else {
            log("Cloning ACE-Step from GitHub...")
            let (cloneOk, cloneOut) = runSyncProcess("/usr/bin/git", [
                "clone", "https://github.com/ace-step/ACE-Step.git",
                aceStepRepoDir.path
            ])
            if !cloneOk {
                log("[WARN] Failed to clone ACE-Step: \(cloneOut)")
                log("Server will run in passthrough mode (no neural inference)")
                return
            }
        }
        
        // Install ACE-Step package
        if FileManager.default.fileExists(atPath: aceStepRepoDir.path) {
            log("Installing ACE-Step package (this may take a while)...")
            
            // Install with --no-deps first to avoid version conflicts
            let (installOk, installOut) = runSyncProcess(pipInVenv.path, [
                "install", "-e", aceStepRepoDir.path, "--no-deps", "--quiet"
            ])
            
            if !installOk {
                log("[WARN] ACE-Step install failed: \(installOut)")
                return
            }
            
            // Install inference dependencies from requirements_bridge.txt (single source of truth).
            log("Installing inference dependencies from requirements_bridge.txt...")
            let reqs = Self.projectRoot.appendingPathComponent(
                "LatentResonator/LatentResonator/Scripts/requirements_bridge.txt"
            )
            let (depsOk, depsOut) = runSyncProcess(pipInVenv.path, [
                "install", "-r", reqs.path, "--quiet"
            ])
            
            if depsOk {
                log("[ok] ACE-Step package installed successfully")
            } else {
                log("[WARN] Some dependencies failed: \(depsOut)")
            }
        }
    }
    
    // MARK: - Model Auto-Download
    
    /// Download ACE-Step model if not present in Application Support.
    /// Uses huggingface_hub for automatic download (~7GB).
    private func downloadModelIfNeeded() {
        let fm = FileManager.default
        let modelsDir = LRConstants.ModelConfig.appSupportModelsDir
        
        // Check if any model already exists
        if let existingModel = discoverModelPath() {
            log("[ok] Model found: \(existingModel)")
            return
        }
        
        log("No ACE-Step model found. Downloading base model (~7GB)...")
        log("This only happens once and may take 10-30 minutes.")
        updateState(.installing)
        
        // Ensure models directory exists
        do {
            try fm.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        } catch {
            log("[ERROR] Cannot create models directory: \(error.localizedDescription)")
            return
        }
        
        // Install huggingface_hub if not present
        let (hfOk, _) = runSyncProcess(pipInVenv.path, [
            "install", "huggingface_hub", "--quiet"
        ])
        if !hfOk {
            log("[WARN] Failed to install huggingface_hub")
        }
        
        // Download using Python script
        let modelType = "base"
        let hfModelID = "ACE-Step/Ace-Step1.5"
        let modelDir = modelsDir.appendingPathComponent("ace-step-v1.5-\(modelType)")
        
        log("Downloading \(hfModelID)...")
        
        let downloadScript = """
        from huggingface_hub import snapshot_download
        import sys
        
        try:
            snapshot_download(
                repo_id='\(hfModelID)',
                local_dir='\(modelDir.path)',
                local_dir_use_symlinks=False,
            )
            print('DOWNLOAD_COMPLETE')
        except Exception as e:
            print(f'DOWNLOAD_FAILED: {e}', file=sys.stderr)
            sys.exit(1)
        """
        
        let (downloadOk, downloadOut) = runSyncProcess(pythonInVenv.path, [
            "-c", downloadScript
        ])
        
        if downloadOk && downloadOut.contains("DOWNLOAD_COMPLETE") {
            log("[ok] Model downloaded to \(modelDir.path)")
        } else {
            log("[WARN] Model download failed: \(downloadOut)")
            log("Server will start in passthrough mode")
            log("You can manually download later with: --with-model")
        }
    }
}
