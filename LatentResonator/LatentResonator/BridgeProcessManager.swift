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

    // MARK: - Published State

    @Published var state: ServerState = .idle
    @Published var lastError: String?
    @Published var setupLog: [String] = []

    // MARK: - Process Management

    private var serverProcess: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?

    // MARK: - Path Discovery (Compile-Time + Bundle Fallback)
    //
    // Primary: #filePath resolves to this source file at compile time.
    // Fallback: Bundle.main.resourcePath for distributed .app bundles where
    // #filePath points to a non-existent build machine path.
    //
    //   {projectRoot}/
    //     LatentResonator/
    //       LatentResonator/
    //         BridgeProcessManager.swift   <- #filePath
    //         Scripts/
    //           ace_bridge_server.py
    //           requirements_bridge.txt
    //     .venv-ace-bridge/                <- created here

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
        // Primary: derive from #filePath
        let devRoot = sourceFileURL
            .deletingLastPathComponent()        // LatentResonator/ (inner)
            .deletingLastPathComponent()        // LatentResonator/ (outer)
            .deletingLastPathComponent()        // project root
        if FileManager.default.fileExists(atPath: devRoot.path) {
            return devRoot
        }
        // Fallback: Bundle's parent directory
        if let resourcePath = Bundle.main.resourcePath {
            return URL(fileURLWithPath: resourcePath)
                .deletingLastPathComponent()    // Contents/
                .deletingLastPathComponent()    // .app bundle
                .deletingLastPathComponent()    // parent dir
        }
        return devRoot
    }

    private var venvDir: URL {
        Self.projectRoot.appendingPathComponent(".venv-ace-bridge")
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
           !custom.isEmpty {
            searchDirs.append(URL(fileURLWithPath: custom))
        }

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
    func launchServer() {
        guard state == .idle || state == .error else {
            log("Bridge already \(state.rawValue), skipping launch")
            return
        }

        setupQueue.async { [weak self] in
            self?.performLaunch()
        }
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
        } else {
            log("Existing venv found: \(venvDir.lastPathComponent)")
        }

        // --- Step 3: Start the bridge server (or reuse if already listening) ---

        let healthURL = URL(string: LRConstants.ACEBridge.baseURL)!
            .appendingPathComponent(LRConstants.ACEBridge.healthEndpoint)

        // When forceCPU is true, never reuse — an existing bridge may be MPS and will crash.
        // Kill any process on the port so we launch fresh with --device cpu.
        if LRConstants.ACEBridge.forceCPU {
            if checkHealthSync(url: healthURL, timeout: 2.0) {
                log("forceCPU: terminating existing bridge to launch with --device cpu")
                requestShutdownViaHTTPSync()
                killProcessOnPortSync(port: LRConstants.ACEBridge.defaultPort)
                Thread.sleep(forTimeInterval: 1.0)  // allow port to be released
            }
        } else if checkHealthSync(url: healthURL, timeout: 2.0) {
            updateState(.running)
            log("[ok] Bridge already running on port \(LRConstants.ACEBridge.defaultPort) (reusing)")
            return
        }

        updateState(.launching)
        log("Starting bridge server on port \(LRConstants.ACEBridge.defaultPort)...")

        do {
            try startServerProcess()

            // Wait until the server is actually listening (model load can take a long time)
            let healthURL = URL(string: LRConstants.ACEBridge.baseURL)!
                .appendingPathComponent(LRConstants.ACEBridge.healthEndpoint)
            let maxWait: TimeInterval = 120
            let pollInterval = LRConstants.ACEBridge.bridgeStartupPollInterval
            let initialDelay = LRConstants.ACEBridge.bridgeStartupInitialDelay
            var waited: TimeInterval = 0
            var up = false
            Thread.sleep(forTimeInterval: initialDelay)
            waited = initialDelay
            while waited < maxWait {
                if serverProcess?.isRunning != true {
                    break
                }
                if checkHealthSync(url: healthURL, timeout: 2.0) {
                    up = true
                    break
                }
                Thread.sleep(forTimeInterval: pollInterval)
                waited += pollInterval
            }

            if let process = serverProcess, process.isRunning, up {
                updateState(.running)
                log("[ok] Bridge server running (PID: \(process.processIdentifier))")
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

        URLSession.shared.dataTask(with: request) { _, response, _ in
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                result = true
            }
            semaphore.signal()
        }.resume()

        _ = semaphore.wait(timeout: .now() + timeout + 0.5)
        return result
    }

    // MARK: - Server Process

    private func startServerProcess() throws {
        let process = Process()
        process.executableURL = pythonInVenv

        var args = [
            serverScript.path,
            "--host", "127.0.0.1",
            "--port", "\(LRConstants.ACEBridge.defaultPort)"
        ]

        // Auto-discover model weights in models/ directory.
        // When found, pass --model-path so the bridge loads the AI model
        // instead of running in passthrough mode.
        if let modelPath = discoverModelPath() {
            args += ["--model-path", modelPath]
            log("Model weights discovered: \(modelPath)")
        } else {
            log("No model weights found -- passthrough mode")
        }

        // Device: use CPU when MPS crashes (Metal validation in rsub). Otherwise auto (MPS on Apple Silicon).
        let device = LRConstants.ACEBridge.forceCPU ? "cpu" : "auto"
        args += ["--device", device]
        if LRConstants.ACEBridge.forceCPU {
            log("Using CPU device (MPS disabled due to rsub crash)")
        }

        process.arguments = args
        process.currentDirectoryURL = Self.scriptsDir

        // Inherit PATH but activate venv
        var env = ProcessInfo.processInfo.environment
        env["VIRTUAL_ENV"] = venvDir.path
        if LRConstants.ACEBridge.forceCPU {
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
                self?.log("[server] \(line)")
            }
        }

        // Capture stderr (Flask logs to stderr)
        let stderr = Pipe()
        process.standardError = stderr
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let str = String(data: data, encoding: .utf8) else { return }
            for line in str.components(separatedBy: .newlines) where !line.isEmpty {
                self?.log("[server] \(line)")
            }
        }

        // Handle unexpected termination
        process.terminationHandler = { [weak self] proc in
            guard let self = self else { return }
            let code = proc.terminationStatus
            self.log("Server exited (code: \(code))")

            // Clean up pipe handlers
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil

            DispatchQueue.main.async {
                if self.state != .stopping {
                    // Unexpected termination
                    self.state = .error
                    self.lastError = "Server exited unexpectedly (code \(code))"
                } else {
                    // Expected shutdown
                    self.state = .idle
                }
                self.serverProcess = nil
            }
        }

        try process.run()

        serverProcess = process
        stdoutPipe = stdout
        stderrPipe = stderr
    }

    // MARK: - Terminate Server

    /// Terminate the bridge server so it never survives app quit.
    /// - If we started the process: HTTP /shutdown, SIGTERM, wait up to 3s, then SIGKILL (synchronous).
    /// - If we reused an existing server (no process handle): POST /shutdown so that server exits.
    func terminateServer() {
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
        let url = URL(string: LRConstants.ACEBridge.baseURL)!
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

        for path in candidates {
            if FileManager.default.fileExists(atPath: path) {
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
        print(">> Bridge: \(message)")
        DispatchQueue.main.async { [weak self] in
            self?.setupLog.append(message)
            // Keep log bounded to prevent memory growth
            if (self?.setupLog.count ?? 0) > 200 {
                self?.setupLog.removeFirst(50)
            }
        }
    }
}
