import Foundation
import os

// MARK: - ACE-Step Bridge Client
//
// Async HTTP client communicating with ace_bridge_server.py.
// Sends audio chunks + parameters as JSON/base64 WAV, receives
// processed audio.
//
// The bridge is optional: when unavailable, NeuralEngine falls back
// to the local DSP SpectralProcessor (Black Box Resonator §6.1).
//
// White paper reference:
//   §3.3 -- S_{i+1} = ACE(S_i + N(μ,σ), P, γ)
//   §6.1 -- Full ACE-Step inference via Python bridge.

/// Connection state for the ACE-Step bridge server.
enum ACEBridgeStatus: String {
    case disconnected = "DISCONNECTED"
    case connecting   = "CONNECTING"
    case connected    = "CONNECTED"
    case modelLoaded  = "MODEL LOADED"
    case error        = "ERROR"
    case recovering   = "RECOVERING"  // Auto-reconnection in progress
}

/// Response from the /health endpoint.
struct ACEHealthResponse: Decodable {
    let status: String
    let model_loaded: Bool
    let model_type: String?
    let device: String?
    let error: String?
    let inference_count: Int?
    let timestamp: Double?
}

/// Response from the /infer endpoint.
struct ACEInferResponse: Decodable {
    let audio: String          // base64-encoded WAV
    let sample_rate: Int
    let num_samples: Int
    let duration_ms: Double
    let model_used: Bool
    let model_type: String?
}

/// Error response from the bridge server.
struct ACEErrorResponse: Decodable {
    let error: String
}

/// Errors thrown by ACEStepBridge.
enum ACEBridgeError: Error, LocalizedError {
    case notConnected
    case serverError(String)
    case decodingFailed(String)
    case networkError(Error)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "ACE-Step bridge server not connected"
        case .serverError(let msg):
            return "Bridge server error: \(msg)"
        case .decodingFailed(let msg):
            return "Response decoding failed: \(msg)"
        case .networkError(let err):
            return "Network error: \(err.localizedDescription)"
        }
    }
}

// MARK: - ACEStepBridge

/// Async HTTP client for the ACE-Step bridge server.
///
/// Usage:
/// ```swift
/// let bridge = ACEStepBridge()
/// bridge.startHealthPolling()
///
/// if bridge.status == .connected || bridge.status == .modelLoaded {
///     let output = try await bridge.infer(
///         samples: inputBuffer,
///         prompt: "ferrofluid texture",
///         guidanceScale: 15.0
///     )
/// }
/// ```
final class ACEStepBridge: ObservableObject {

    // MARK: - Published State

    /// Current connection status.
    @Published var status: ACEBridgeStatus = .disconnected

    /// Whether the remote model is loaded and active.
    @Published var isModelLoaded: Bool = false

    /// Device the model is running on (cpu, mps, cuda).
    @Published var remoteDevice: String = "none"

    /// Model type reported by the server (turbo, sft, base, unknown).
    @Published var remoteModelType: String = "none"

    /// Last error message from the server.
    @Published var lastError: String? = nil

    /// Total inference cycles completed on the server.
    @Published var remoteInferenceCount: Int = 0

    /// Round-trip latency of last inference call (ms).
    @Published var lastLatencyMs: Double = 0.0

    // MARK: - In-Flight Request Tracking
    //
    // BridgeProcessManager checks this before tearing down the bridge process
    // (profile switch, PERFORM mode entry, app quit) so it never kills the
    // server out from under an active /infer request -- see terminateServer().
    // A count, not a bool: multiple FeedbackLoopNodes share this one bridge
    // and can have concurrent requests in flight. OSAllocatedUnfairLock
    // matches the lock style already used for per-node inference gating
    // (see FeedbackLoopNode.isInferringLock).

    private let inFlightInferCount = OSAllocatedUnfairLock(initialState: 0)

    /// True while at least one /infer request is awaiting a response.
    var isInferInFlight: Bool {
        inFlightInferCount.withLock { $0 > 0 }
    }

    // MARK: - Configuration

    /// Base URL for the bridge server.
    let baseURL: URL

    /// URLSession with short timeouts for health checks and longer for inference.
    private let healthSession: URLSession
    private let inferSession: URLSession

    /// Health polling timer. Uses dynamic intervals: boot backoff (1s → 2s → 4s → 8s → 16s)
    /// then steady-state polling once the first successful /health returns.
    private var healthTimer: Timer?

    /// Current health polling interval. Mutated by the boot-backoff loop.
    private var healthPollInterval: TimeInterval = LRConstants.ACEBridge.healthPollBootIntervalInitial

    /// True while the polling loop is still in exponential boot backoff.
    private var isHealthPollingBootPhase: Bool = false

    /// True when the dynamic polling loop is active (prevents redundant reconnect timers).
    private var isHealthPollingActive: Bool = false

    /// Timestamp when bridge boot was initiated (for ready-time logging).
    var bridgeStartTime: Date?

    /// Ensures the "model loaded" ready log is emitted only once per boot.
    private var bridgeReadyLogged: Bool = false

    // MARK: - Reconnection State

    /// Consecutive health check failures
    @Published var consecutiveFailures: Int = 0
    /// Maximum failures before triggering circuit breaker
    private let maxConsecutiveFailures = LRConstants.maxConsecutiveFailures
    /// Whether auto-reconnection is enabled
    private var autoReconnectEnabled = true
    /// Current reconnection attempt (for exponential backoff)
    private var reconnectAttempt = 0
    /// Maximum reconnection attempts before giving up
    private let maxReconnectAttempts = 10
    /// Reconnection timer (separate from health timer)
    private var reconnectTimer: Timer?
    /// Timestamp of last successful health check
    private var lastSuccessfulHealthCheck: Date?

    // MARK: - Init

    init(
        baseURL: URL = LRConstants.ACEBridge.baseURLAsURL
    ) {
        self.baseURL = baseURL

        // Health check session: longer timeout when bridge is busy with inference
        let healthConfig = URLSessionConfiguration.ephemeral
        healthConfig.timeoutIntervalForRequest = LRConstants.ACEBridge.healthTimeout
        healthConfig.timeoutIntervalForResource = LRConstants.ACEBridge.healthTimeout + 5.0
        self.healthSession = URLSession(configuration: healthConfig)

        // Inference session: longer timeout for model processing
        // CPU-only inference takes 45-70s per diffusion step; generous timeout prevents premature failures.
        let inferConfig = URLSessionConfiguration.ephemeral
        inferConfig.timeoutIntervalForRequest = LRConstants.ACEBridge.inferTimeout
        inferConfig.timeoutIntervalForResource = LRConstants.ACEBridge.inferTimeout * 2
        self.inferSession = URLSession(configuration: inferConfig)
    }

    deinit {
        stopHealthPolling()
        reconnectTimer?.invalidate()
    }

    // MARK: - Health Polling

    /// Start periodic health checks to the bridge server.
    /// Uses exponential boot backoff (1s, 2s, 4s, 8s, 16s cap) until the first
    /// successful /health, then switches to a slower 30s steady-state poll.
    func startHealthPolling() {
        stopHealthPolling()
        isHealthPollingActive = true
        bridgeReadyLogged = false

        // Begin boot backoff: first check after 1s, then double until 16s cap.
        isHealthPollingBootPhase = true
        healthPollInterval = LRConstants.ACEBridge.healthPollBootIntervalInitial
        scheduleNextHealthCheck(after: healthPollInterval)
    }

    /// Stop health polling.
    func stopHealthPolling() {
        healthTimer?.invalidate()
        healthTimer = nil
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        isHealthPollingActive = false
    }

    /// Schedule a single fire-and-reschedule health check. The interval is
    /// recalculated after each check so boot backoff can shrink/expand.
    private func scheduleNextHealthCheck(after interval: TimeInterval) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.healthTimer?.invalidate()
            self.healthTimer = Timer.scheduledTimer(
                withTimeInterval: interval,
                repeats: false
            ) { [weak self] _ in
                Task { [weak self] in
                    await self?.healthCheckTick()
                }
            }
        }
    }

    /// One polling tick: check /health, then reschedule with the appropriate interval.
    private func healthCheckTick() async {
        await checkHealth()

        if isHealthPollingBootPhase {
            if status == .connected || status == .modelLoaded {
                // First successful /health: leave boot backoff and switch to steady-state.
                isHealthPollingBootPhase = false
                healthPollInterval = LRConstants.ACEBridge.healthPollSteadyInterval
            } else {
                // Server not yet ready; back off exponentially up to the cap.
                healthPollInterval = min(
                    healthPollInterval * 2,
                    LRConstants.ACEBridge.healthPollBootIntervalCap
                )
            }
        } else {
            // Steady-state: long-lived bridge, infrequent polls.
            healthPollInterval = LRConstants.ACEBridge.healthPollSteadyInterval
        }

        logBridgeReadyIfNeeded()
        scheduleNextHealthCheck(after: healthPollInterval)
    }

    /// Emit a single structured ready line the first time the model reports loaded.
    private func logBridgeReadyIfNeeded() {
        guard !bridgeReadyLogged,
              status == .modelLoaded,
              let startTime = bridgeStartTime else { return }
        bridgeReadyLogged = true
        let elapsed = Date().timeIntervalSince(startTime)
        let formatted = String(format: "%.1f", elapsed)
        print("[Bridge:ready] ✓ Model loaded on \(remoteDevice) in \(formatted)s — full neural inference active")
    }

    /// Check the server's /health endpoint.
    /// Implements exponential backoff and circuit breaker pattern for resilience.
    func checkHealth() async {
        let url = baseURL.appendingPathComponent(LRConstants.ACEBridge.healthEndpoint)

        await MainActor.run {
            if status == .disconnected || status == .error {
                status = .connecting
            }
        }

        do {
            let (data, response) = try await healthSession.data(from: url)

            guard let httpResponse = response as? HTTPURLResponse else {
                await handleHealthCheckFailure(error: "Invalid response type from server")
                return
            }

            guard httpResponse.statusCode == 200 else {
                let errorMsg = "Server returned HTTP \(httpResponse.statusCode)"
                await handleHealthCheckFailure(error: errorMsg)
                return
            }

            let health = try JSONDecoder().decode(ACEHealthResponse.self, from: data)

            await MainActor.run {
                // Success - reset failure counters
                self.consecutiveFailures = 0
                self.reconnectAttempt = 0
                self.lastSuccessfulHealthCheck = Date()
                self.isModelLoaded = health.model_loaded
                self.remoteDevice = health.device ?? "none"
                self.remoteModelType = health.model_type ?? "unknown"
                self.lastError = health.error
                self.remoteInferenceCount = health.inference_count ?? 0

                if health.model_loaded {
                    self.status = .modelLoaded
                } else {
                    self.status = .connected
                }
            }
        } catch {
            await handleHealthCheckFailure(error: error.localizedDescription)
        }
    }

    /// Handle health check failure with circuit breaker logic.
    private func handleHealthCheckFailure(error: String) async {
        await MainActor.run {
            consecutiveFailures += 1
            lastError = error

            // Circuit breaker: too many failures
            if consecutiveFailures >= maxConsecutiveFailures {
                if autoReconnectEnabled && reconnectAttempt < maxReconnectAttempts {
                    status = .recovering
                    // When the dynamic polling loop is active, its own backoff handles
                    // retries; scheduling a duplicate reconnect timer would create
                    // overlapping /health calls and extra console noise.
                    if !isHealthPollingActive {
                        scheduleReconnection()
                    }
                } else {
                    status = .error
                    if reconnectAttempt >= maxReconnectAttempts {
                        lastError = "Max reconnection attempts reached. Bridge unavailable."
                    }
                }
            } else {
                status = .disconnected
            }
        }
    }

    /// Schedule automatic reconnection with exponential backoff.
    private func scheduleReconnection() {
        reconnectAttempt += 1

        // Exponential backoff: 1s, 2s, 4s, 8s, 16s... up to 60s max
        let backoffSeconds = min(pow(2.0, Double(reconnectAttempt - 1)), 60.0)

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            self.reconnectTimer?.invalidate()
            self.reconnectTimer = Timer.scheduledTimer(
                withTimeInterval: backoffSeconds,
                repeats: false
            ) { [weak self] _ in
                Task { [weak self] in
                    await self?.attemptReconnection()
                }
            }
        }
    }

    /// Attempt to reconnect to the bridge server.
    private func attemptReconnection() async {
        await MainActor.run {
            status = .recovering
        }

        // Try health check again
        await checkHealth()
    }

    /// Force immediate reconnection attempt (e.g., after manual restart).
    func forceReconnect() {
        reconnectAttempt = 0
        consecutiveFailures = 0
        autoReconnectEnabled = true

        Task {
            await checkHealth()
            startHealthPolling()
        }
    }

    /// Disable auto-reconnection (e.g., when user manually stops).
    func disableAutoReconnect() {
        autoReconnectEnabled = false
        reconnectTimer?.invalidate()
        reconnectTimer = nil
    }

    // MARK: - Inference

    /// Run one inference cycle through the ACE-Step 1.5 bridge server.
    ///
    /// - Parameters:
    ///   - samples: Mono float32 audio samples.
    ///   - sampleRate: Audio sample rate (default: 48000).
    ///   - prompt: Semantic prompt text P.
    ///   - guidanceScale: CFG scale γ.
    ///   - numSteps: Diffusion steps.
    ///   - seed: Random seed (-1 for random).
    ///   - inputStrength: α blend factor.
    ///   - entropy: Entropy level [0..1].
    ///   - granularity: Granularity level [0..1].
    ///   - taskType: ACE-Step task (cover, repaint, lego, extract, complete).
    ///   - thinking: Bypass LM planner when false (§6.1).
    ///   - shift: Attention allocation (1.0=structure, 10.0=detail).
    ///   - inferMethod: "ode" (deterministic) or "sde" (stochastic).
    ///   - denoiseStrength: Per-step denoise amount (0 = none, 1 = full). App skips bridge when 0.
    ///
    /// - Returns: Processed audio samples as `[Float]`.
    func infer(
        samples: [Float],
        sampleRate: Int = Int(LRConstants.sampleRate),
        prompt: String = "",
        guidanceScale: Float = LRConstants.cfgScaleDefault,
        numSteps: Int = LRConstants.aceStepsDefault,
        seed: Int = -1,
        inputStrength: Float = LRConstants.inputStrengthDefault,
        entropy: Float = 0.25,
        granularity: Float = 0.45,
        taskType: String = LRConstants.aceTaskTypeDefault,
        thinking: Bool = LRConstants.aceThinkingDefault,
        shift: Float = LRConstants.aceShiftDefault,
        inferMethod: String = LRConstants.aceInferMethodDefault,
        denoiseStrength: Float = LRConstants.denoiseStrengthDefault
    ) async throws -> [Float] {
        guard status == .connected || status == .modelLoaded else {
            throw ACEBridgeError.notConnected
        }

        inFlightInferCount.withLock { $0 += 1 }
        defer { inFlightInferCount.withLock { $0 -= 1 } }

        // Encode audio to WAV bytes, then base64
        let wavData = WAVCodec.encode(samples: samples, sampleRate: sampleRate)
        let audioB64 = wavData.base64EncodedString()

        // Calculate audio_duration from actual sample count.
        // This tells ACE-Step to generate output matching our input size,
        // preventing the 85ms-input -> 10s-output mismatch that caused
        // ring buffer overflow and 93% audio loss.
        let audioDuration = Double(samples.count) / Double(sampleRate)

        // Build request body -- includes ACE-Step 1.5 native parameters
        let body: [String: Any] = [
            "audio": audioB64,
            "prompt": prompt,
            "guidance_scale": guidanceScale,
            "num_steps": numSteps,
            "seed": seed,
            "input_strength": inputStrength,
            "entropy": entropy,
            "granularity": granularity,
            "task_type": taskType,
            "thinking": thinking,
            "shift": shift,
            "infer_method": inferMethod,
            "audio_duration": audioDuration,
            "denoise_strength": denoiseStrength,
        ]

        let url = baseURL.appendingPathComponent(LRConstants.ACEBridge.inferEndpoint)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let t0 = CFAbsoluteTimeGetCurrent()

        do {
            let (data, response) = try await inferSession.data(for: request)

            let latency = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0

            guard let httpResponse = response as? HTTPURLResponse else {
                throw ACEBridgeError.serverError("Invalid HTTP response")
            }

            if httpResponse.statusCode != 200 {
                // Try to decode error
                if let errResp = try? JSONDecoder().decode(
                    ACEErrorResponse.self, from: data
                ) {
                    throw ACEBridgeError.serverError(errResp.error)
                }
                throw ACEBridgeError.serverError(
                    "HTTP \(httpResponse.statusCode)"
                )
            }

            let inferResp = try JSONDecoder().decode(
                ACEInferResponse.self, from: data
            )

            // Decode base64 WAV response
            guard let wavBytes = Data(base64Encoded: inferResp.audio) else {
                throw ACEBridgeError.decodingFailed("Invalid base64 audio")
            }

            let outputSamples = WAVCodec.decode(wavData: wavBytes)

            await MainActor.run {
                self.lastLatencyMs = latency
                if inferResp.model_used {
                    self.isModelLoaded = true
                    self.status = .modelLoaded
                }
            }

            return outputSamples

        } catch let error as ACEBridgeError {
            throw error
        } catch {
            throw ACEBridgeError.networkError(error)
        }
    }

    // MARK: - Helpers

    private func updateStatus(
        _ newStatus: ACEBridgeStatus,
        error: String? = nil
    ) async {
        await MainActor.run {
            self.status = newStatus
            self.lastError = error
            if newStatus == .disconnected || newStatus == .error {
                self.isModelLoaded = false
            }
        }
    }
}
