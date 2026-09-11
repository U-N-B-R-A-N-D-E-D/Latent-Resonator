# ACE-Step Python Bridge — Server & Client Patterns

**Trigger phrases:** "ACE-Step", "bridge", "Python server", "inference", "HTTP", "Flask", "PyTorch", "ace_bridge_server", "bridge process", "venv", "model loading", "ACEStepWrapper"

**Purpose:** Guide implementation and debugging of the ACE-Step Python bridge server and its Swift HTTP client. Contracts below are copied from the real files — `Scripts/ace_bridge_server.py` and `ACEStepBridge.swift` — not a hypothetical example. If you change one side, update the other in the same edit.

---

## WHEN TO LOAD THIS SKILL

- User mentions "bridge", "Python server", "ACE-Step"
- User is modifying `ace_bridge_server.py`, `ACEStepBridge.swift`, or `BridgeProcessManager.swift`
- User reports bridge connection issues or inference failures
- User wants to add/change bridge endpoints or request/response fields

---

## SYSTEM OVERVIEW

### Two-Process Architecture

```
┌────────────────────┐    HTTP/JSON     ┌──────────────────────────┐
│  Latent Resonator  │  <──────────>   │  ACE-Step Bridge          │
│  (Swift / macOS)   │   base64 WAV     │  (Python / Flask+waitress)│
│                    │                  │                          │
│  ACEStepBridge     │  GET  /health    │  ACEStepWrapper           │
│  FeedbackLoopNode   │  POST /infer    │  ACE-Step 1.5 pipeline    │
│  BridgeProcessMgr  │  GET  /status    │  (or passthrough)         │
│                    │  POST /shutdown  │                           │
└────────────────────┘                  └──────────────────────────┘

Binding: 127.0.0.1:8976 (localhost only, no network exposure — see main()'s --host default)
```

### Three Operating Modes

| Mode | Condition | Behavior |
|------|-----------|----------|
| **Disconnected** | `BridgeProcessManager` hasn't launched the process, or health polling is failing | `FeedbackLoopNode` passes audio through dry |
| **Passthrough** | Server running, `ACEStepWrapper.is_loaded == False` (no `--model-path`, or load failed) | `/infer` echoes `audio_samples` back unchanged |
| **Neural Inference** | Server running, model loaded | Full ACE-Step 1.5 pipeline via `acestep.pipeline_ace_step.ACEStepPipeline` |

**Graceful degradation is load-bearing, not a fallback path to eventually remove**: `ACEStepWrapper.infer()` returns the input unchanged whenever `is_loaded` is `False` or `denoise_strength <= 0.0`, and swallows pipeline exceptions the same way (`except Exception: return audio_samples`).

---

## PYTHON SERVER (`LatentResonator/LatentResonator/Scripts/ace_bridge_server.py`)

### `ACEStepWrapper` — the model wrapper (`__all__`-exported)

```python
class ACEStepWrapper:
    """
    Wraps ACE-Step 1.5 for single-chunk inference. Passthrough when not loaded.

    Model types (auto-detected from the model path string, default "base"):
      turbo — 8 steps, no CFG      sft — 50 steps, CFG      base — 50 steps, CFG + tasks
    """

    def __init__(self, model_path: str = None, device: str = "cpu"):
        self.is_loaded = False
        self.model_type = "unknown"     # turbo | sft | base | unknown
        self.device = device
        self.load_error = None
        self.inference_count = 0
        if model_path:
            self.load(model_path)       # tries acestep.pipeline_ace_step.ACEStepPipeline,
                                         # falls back to diffusers AutoPipelineForText2Audio

    def infer(
        self,
        audio_samples: np.ndarray,      # mono float32
        sample_rate: int = 48000,
        prompt: str = "",
        guidance_scale: float = 15.0,   # CFG γ, whitepaper §4.2.1: 15.0–18.0 overdrive zone
        num_steps: int = 20,
        seed: int = -1,
        input_strength: float = 0.6,    # α — ref_audio_strength
        audio_duration: float = 10.0,
        denoise_strength: float = 1.0,  # 0 => passthrough; else effective_steps = round(num_steps * denoise_strength)
        guidance_interval: float = 0.5,
        guidance_interval_decay: float = 0.0,
        omega_scale: float = 10.0,
        min_guidance_scale: float = 3.0,
        retake_variance: float = 0.0,
        scheduler_type: str = "euler",
        cfg_type: str = "apg",
        use_erg_tag: bool = True,
        use_erg_lyric: bool = True,
        use_erg_diffusion: bool = True,
    ) -> np.ndarray:
        ...
```

Real device handling: MPS is honored via `--device auto|mps|cuda|cpu`, but `LATENT_RESONATOR_FORCE_CPU=1` (env var, checked before any `torch` import) forces CPU everywhere — a documented workaround for an MPS `rsub` SIGABRT. Don't remove that override without checking the current PyTorch/ACE-Step MPS support status first.

### Endpoints (as implemented — don't invent extra fields without updating `ACEStepBridge.swift` too)

**`GET /health`** — polled by `ACEStepBridge.checkHealth()` every 10s:

```json
{
  "status": "ok",
  "model_loaded": true,
  "model_type": "base",
  "device": "mps",
  "error": null,
  "inference_count": 42,
  "timestamp": 1735000000.123
}
```

**`GET /status`** — same fields plus `model_path`, `sample_rate`, `buffer_size`, `version`.

**`POST /shutdown`** — called by `BridgeProcessManager` before `SIGTERM`; uses `werkzeug.server.shutdown` or falls back to `os.kill(os.getpid(), SIGTERM)`.

**`POST /infer`** — request body (field names are `snake_case`, matching `ACEStepBridge.swift`'s `body: [String: Any]` exactly):

```json
{
  "audio": "<base64 WAV>",
  "prompt": "ferrofluid texture, recursive drift",
  "guidance_scale": 15.0,
  "num_steps": 20,
  "seed": -1,
  "input_strength": 0.6,
  "shift": 5.0,
  "infer_method": "ode",
  "entropy": 0.25,
  "granularity": 0.45,
  "audio_duration": 10.0,
  "denoise_strength": 1.0,
  "task_type": "cover",
  "thinking": false
}
```

Whitepaper → ACE-Step parameter mapping (this is the part agents get wrong — these are NOT passed straight through):

```
shift        [1..10]  → guidance_interval        [0.1..0.9]   linear remap
entropy      [0..1]   → omega_scale               [1..20]      1 + entropy*19
granularity  [0..1]   → guidance_interval_decay   [0..1]       identity (clamped)
infer_method "sde"    → retake_variance = 0.5; "ode" → 0.0
```

Response:

```json
{
  "audio": "<base64 WAV>",
  "sample_rate": 48000,
  "num_samples": 4096,
  "duration_ms": 42.3,
  "model_used": true,
  "model_type": "base"
}
```

Error response (400/413/500): `{"error": "..."}`. Payload limits are enforced server-side: `MAX_AUDIO_B64_LEN = 1_400_000`, `MAX_WAV_BYTES = 2_000_000` — raise 413 rather than let a huge decode run.

### Low-Latency / Performance Mode

`--low-latency` (legacy) or `--performance-mode` caps `num_steps` to 6 inside `/infer`. `NeuralEngine`/`RootView` trigger this by restarting the bridge process with the flag when switching to PERFORM mode — see `BridgeProcessManager.switchProfile(to:)`.

### Server Startup

```bash
python ace_bridge_server.py --port 8976 --model-path /path/to/model --device auto
```

Production serving is **waitress**, not Flask's dev server (`serve(app, host=args.host, port=args.port, threads=6)`) — Flask dev server is single-threaded and can't handle concurrent health-check + inference requests.

### Python Code Quality

```bash
black --check LatentResonator/LatentResonator/Scripts/
flake8 LatentResonator/LatentResonator/Scripts/
pylint LatentResonator/LatentResonator/Scripts/*.py
pytest LatentResonator/LatentResonator/Scripts/test_bridge.py -v
```

Style: `__all__` for public symbols (see the top of `ace_bridge_server.py`), Markdown-style docstrings, snake_case, no secrets.

---

## SWIFT HTTP CLIENT (`ACEStepBridge.swift`)

Real shape — an `ObservableObject`, not the toy example this file used to contain:

```swift
final class ACEStepBridge: ObservableObject {
    @Published var status: ACEBridgeStatus            // .disconnected/.connecting/.connected/.modelLoaded/.error/.recovering
    @Published var isModelLoaded: Bool
    @Published var remoteDevice: String
    @Published var remoteModelType: String
    @Published var lastError: String?
    @Published var remoteInferenceCount: Int
    @Published var lastLatencyMs: Double

    func startHealthPolling()   // Timer, 10s interval, exponential-backoff reconnect on failure
    func checkHealth() async
    func infer(
        samples: [Float], sampleRate: Int = ..., prompt: String = "",
        guidanceScale: Float = ..., numSteps: Int = ..., seed: Int = -1,
        inputStrength: Float = ..., entropy: Float = 0.25, granularity: Float = 0.45,
        taskType: String = ..., thinking: Bool = ..., shift: Float = ...,
        inferMethod: String = ..., denoiseStrength: Float = ...
    ) async throws -> [Float]
}
```

`infer(...)` encodes samples via `WAVCodec.encode`, base64s them, builds the exact JSON body above, POSTs with a long timeout (`LRConstants.ACEBridge.inferTimeout` — CPU inference can take 45–70s per step), and throws `ACEBridgeError` (`.notConnected`, `.serverError`, `.decodingFailed`, `.networkError`) on failure. It requires `status == .connected || status == .modelLoaded` — callers must check that before invoking it, exactly as `FeedbackLoopNode`'s inference `Task` does.

**Consumer of this client:** `Graph/Nodes/NeuralNodes.swift` — `FeedbackLoopNode`'s async inference `Task` calls `bridge.infer(...)` directly (not through `ACEStepInferenceNode`, which is parameter-surface-only). Load the `v2-node-graph` skill for how that wiring works.

---

## PROCESS LIFECYCLE (`BridgeProcessManager.swift`)

Real responsibilities: creates/reuses the venv under `~/Library/Application Support/LatentResonator/venv-ace-bridge/` (user-writable, works when the app itself is read-only in `/Applications`), installs `Scripts/requirements_bridge.txt`, launches `ace_bridge_server.py` as a child `Process`, captures stdout/stderr via `Pipe` + `readabilityHandler` into `@Published var realtimeLog: [String]` (bounded, ~100 lines) for `TerminalConsoleView`, and calls `POST /shutdown` before `terminate()`.

---

## SECURITY

- **Never bind to `0.0.0.0`.** `main()` defaults `--host` to `127.0.0.1`; keep it that way. No auth on any endpoint, inference is expensive (DoS surface), audio data may be sensitive.
- No secrets in the repo (`.gitignore` already excludes `.env`, `*.key`, `*.pem`).
- Validate untrusted input server-side: the real `/infer` already does (`isinstance` checks, `MAX_AUDIO_B64_LEN`/`MAX_WAV_BYTES`, `safe_float`/`safe_int` coercion with defaults) — follow that pattern for any new field instead of trusting `request.get_json()` blindly.

---

## DEBUGGING

**Bridge not connecting:**

```bash
curl http://127.0.0.1:8976/health   # expect {"status":"ok", "model_loaded": ..., ...}
ps aux | grep ace_bridge_server
```

Check `NeuralEngine.aceBridge.lastError` in Swift; check the Python process's stdout (surfaced live in `TerminalConsoleView` inside CANVAS mode, or run the script manually).

**Inference returns unchanged audio (passthrough) when a model should be loaded:**

- `/health` → `model_loaded: false`? Check `load_error` in the same response.
- Common cause: `acestep` package not importable — the server logs `[IMPORT ERROR]` with `sys.path` and tries `ace_step` and `diffusers` fallbacks before giving up.
- `denoise_strength <= 0.0` in the request also forces passthrough by design — that's not a bug, check the caller's intent.

**Inference is slow / times out:**

- Check `/status` → `device`. CPU inference is the slow path; MPS/CUDA should be selected via `--device auto` unless `LATENT_RESONATOR_FORCE_CPU=1` is set.
- `--performance-mode` / `--low-latency` caps steps to 6 for real-time use.

---

## TESTING

```bash
pytest LatentResonator/LatentResonator/Scripts/test_bridge.py -v
```

`test_bridge.py` already exists — extend it rather than writing a parallel test file. Cover: `/health` shape, passthrough echo when no model, 400 on malformed/oversized request, WAV round-trip via `encode_wav_bytes`/`decode_wav_bytes`.

---

## THE BRIDGE IS OPTIONAL, NOT LOAD-BEARING FOR THE APP TO RUN

Without it: DSP-only passthrough through `FeedbackLoopNode`, fully functional instrument. With it: the neural feedback loop the whitepaper describes. Keep the passthrough path correct whenever you touch either side — it's the difference between "graceful degradation" and "the app is silent when the model isn't loaded."
