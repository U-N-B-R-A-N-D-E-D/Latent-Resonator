# ACE-Step Bridge

A small, standalone HTTP server that wraps [ACE-Step 1.5](https://github.com/ace-step/ACE-Step) neural audio inference behind a simple JSON API. It has no dependency on any particular host application — anything that can send an HTTP request can drive it: send an audio chunk plus a handful of generation parameters, and get processed audio back.

This bridge was originally built as part of a larger project and is extracted here as a standalone, reusable component.

## What it does

- Runs as a local (or remote) HTTP service on top of Flask.
- Accepts a short audio clip (as base64-encoded WAV) and a set of generation parameters, and runs one ACE-Step inference cycle over it.
- **Degrades gracefully:** if no model is loaded, `/infer` runs in passthrough mode and echoes the input audio back unmodified, so a calling client can fall back to its own audio processing.
- Uses `waitress` as a multi-threaded production WSGI server by default (falls back to Flask's single-threaded dev server if `waitress` isn't installed).

## Prerequisites

- Python 3.9-3.12 (ACE-Step's dependency stack does not yet support 3.13+).
- macOS, Linux, or Windows with a supported Python. Apple Silicon (MPS), NVIDIA (CUDA), and CPU are all supported as inference devices.
- For actual neural inference (as opposed to passthrough mode): an [ACE-Step 1.5](https://github.com/ace-step/ACE-Step) checkpoint, either downloaded locally or referenced as a HuggingFace repo ID. `ace-step` itself is not published on PyPI and must be installed from its GitHub repository (`setup_ace_bridge.sh --with-model` automates this).

## Setup

The included `setup_ace_bridge.sh` script automates environment creation, dependency installation, and (optionally) model download, then starts the server. Everything it creates (virtual environment, cloned ACE-Step checkout, downloaded model weights) lives next to the script itself, so the bridge is self-contained and does not assume any particular surrounding project layout.

```bash
# First-time setup, no model — server starts in passthrough mode
./setup_ace_bridge.sh

# Full setup with the base model downloaded from HuggingFace (~7GB)
./setup_ace_bridge.sh --with-model

# Download the SFT variant instead
./setup_ace_bridge.sh --with-model --model-type sft

# Use an existing local model checkpoint
./setup_ace_bridge.sh --start-only --model-path /path/to/model

# Custom host/port
./setup_ace_bridge.sh --port 9000
```

The script creates a virtual environment at `.venv-ace-bridge/` next to it, installs `requirements_bridge.txt`, and (with `--with-model`) clones ACE-Step into `ACE-Step/` and downloads the requested checkpoint into `models/`. Run `./setup_ace_bridge.sh --help` for the full option list.

### Manual setup

If you'd rather manage the environment yourself:

```bash
python3.12 -m venv .venv-ace-bridge
source .venv-ace-bridge/bin/activate
pip install -r requirements_bridge.txt

# Optional, for actual neural inference:
git clone https://github.com/ace-step/ACE-Step.git
pip install -e ./ACE-Step --no-deps
# then install ACE-Step's inference dependencies (see requirements_bridge.txt
# and setup_ace_bridge.sh for the exact package list)

python ace_bridge_server.py --model-path /path/to/model
```

### Model types

| Type  | Steps | CFG support | Notes |
|-------|-------|-------------|-------|
| base  | 50    | yes         | Default; supports the full task set (lego/extract/complete). |
| sft   | 50    | yes         | High quality. |
| turbo | 8     | no          | Fast, but any CFG-dependent controls are inactive. |

## Running the server

```bash
python ace_bridge_server.py [--host 127.0.0.1] [--port 8976] [--model-path PATH] [--device auto|cpu|mps|cuda] [--dtype auto|float32|float16|bfloat16] [--warmup] [--debug]
```

- `--dtype auto` (default) runs the model in float16 on MPS and keeps ACE-Step's default elsewhere. Pass `--dtype float32` for the previous MPS behaviour. `bfloat16` loads but produces audio that diverges from float32 on MPS; do not use it.
- `--warmup` runs one short throw-away inference after loading, so the first real request does not pay one-time initialisation. `/health` only answers once the warm-up is done.
- `ACE_BRIDGE_TIMING=1` logs the per-phase timing breakdown of every `/infer` call (the same numbers are always returned in the response `timings` field).

- `--model-path` accepts a local directory or a HuggingFace repo ID. Without it, the server starts in passthrough mode.
- `--device auto` picks MPS, then CUDA, then CPU, in that order, based on availability.
- Set `LATENT_RESONATOR_FORCE_CPU=1` in the environment to force CPU execution unconditionally (a safety valve for MPS backends that crash on certain ops). The name is a holdover from this bridge's origin project; any caller can set it regardless of what launched the server.
- `--low-latency` / `--performance-mode` cap the number of diffusion steps for lower-latency, real-time-oriented inference; pair with `--max-steps` to set the cap explicitly (default 6 if performance mode is on and `--max-steps` isn't given).

## HTTP API

All responses are JSON.

### `GET /health`

Lightweight status check, suitable for periodic polling by a client to confirm the server is reachable and to see whether neural inference is currently active.

```json
{
  "status": "ok",
  "model_loaded": true,
  "model_type": "base",
  "device": "mps",
  "error": null,
  "inference_count": 3,
  "timestamp": 1234567890.123
}
```

### `GET /status`

Same as `/health` plus the resolved `model_path`, the active `dtype`, the `max_wav_bytes` input cap, a `progress` snapshot (see below), the fixed `sample_rate`/`buffer_size` the server assumes (48000 Hz), and the server `version`.

### `GET /progress`

Progress of the request currently being served, for driving a progress bar or ETA in a UI:

```json
{
  "state": "busy",
  "phase": "diffusion",
  "step": 12,
  "total_steps": 28,
  "elapsed_s": 15.0,
  "eta_s": 11.8
}
```

- `state` is `idle` or `busy`; when idle the counters are zero.
- `phase` is one of `starting`, `text_encode`, `vae_encode`, `diffusion`, `vae_decode`.
- `step` counts completed diffusion steps. `total_steps` is an estimate (`num_steps` scaled by `1 - input_strength` for the default `cover` task) until the pipeline reports the real count as the loop starts.
- `eta_s` is `null` until at least two steps have completed, then extrapolates the remaining diffusion time (it does not include VAE decode).
- Requests are serialised: a second concurrent `/infer` waits for the first, and `/progress` always describes the one running.

### `POST /infer`

Runs one inference cycle.

Request body:

```json
{
  "audio": "<base64-encoded WAV>",
  "prompt": "semantic prompt text",
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
  "thinking": true,
  "task_type": "cover"
}
```

Only `audio` is required; every other field falls back to the default shown above. `audio` must be a base64-encoded WAV (16-bit PCM, 24-bit PCM, or 32-bit float; mono or multi-channel — multi-channel input is mixed down to mono). Request size is capped at 12,000,000 decoded WAV bytes (16.1M base64 characters). That accepts 30 seconds of 48 kHz stereo float32 (11.52 MB) or 60 seconds of mono float32; larger requests get a `413`. Note that `audio_duration` is ignored for the default `cover` task: the output length follows the input clip.

A few fields are expressed in a normalized, caller-friendly range and remapped onto the underlying ACE-Step parameters:

| Request field | Range | Maps to | Effect |
|---|---|---|---|
| `shift` | 1-10 | `guidance_interval` (0.1-0.9) | Structure vs. texture: low shift applies CFG early, high shift applies it late. |
| `entropy` | 0-1 | `omega_scale` (1-20) | Higher values increase stochastic deviation between runs. |
| `granularity` | 0-1 | `guidance_interval_decay` (0-1) | Higher values decay CFG faster across steps, for finer detail. |
| `infer_method` | `"ode"` / `"sde"` | `retake_variance` (0.0 / 0.5) | `ode` is deterministic; `sde` injects stochastic per-step noise. |
| `denoise_strength` | 0-1 | effective step count | 0 short-circuits to passthrough; otherwise scales `num_steps`. |

Two further fields control how the prompt reaches the model:

- **`thinking`** (bool, default `true`): when `false`, the three ERG guidance channels (`use_erg_tag`, `use_erg_lyric`, `use_erg_diffusion`) are all disabled, so the prompt is injected directly into the diffusion transformer instead of being routed through ACE-Step's LM-based guidance planner. Use this to bypass LM-mediated guidance when you want the prompt applied more directly.
- **`task_type`** (string, default `"cover"`): selects which ACE-Step task the input audio is run through.
  - `"cover"` — audio-to-audio: the input audio feeds back in as a reference (`ref_audio`) alongside the prompt. This is the default and the mode intended for iterative, feedback-driven use (each call's output can become the next call's input).
  - `"repaint"` — repaints a window of the input audio (currently the whole clip, `0` to `audio_duration`) guided by the prompt.
  - `"extend"` — continues the input audio past its end.
  - `"edit"` — rewrites a segment of the input audio toward the prompt.
  - Any other value is reserved (not yet mapped) and falls back to `"cover"` with a warning logged server-side.

Response body:

```json
{
  "audio": "<base64-encoded WAV>",
  "sample_rate": 48000,
  "num_samples": 4096,
  "duration_ms": 42.3,
  "model_used": true,
  "model_type": "base",
  "timings": {
    "input_write": 0.0, "text_encode": 0.0, "vae_encode": 0.11,
    "cond_encode": 0.01, "diffusion_loop": 0.65, "vae_decode": 0.32,
    "output_read": 0.0, "other": 0.0, "total": 1.1
  }
}
```

`timings` is in seconds and is empty on passthrough. `cond_encode` is the transformer's text/lyric conditioning encode, `other` is pipeline time not attributed to a phase (scheduler set-up, file I/O, GC).

On error, the response is `{"error": "<message>"}` with a `400` (bad input), `413` (payload too large), or `500` (inference failure) status.

### `POST /shutdown`

Requests a graceful shutdown, so the process can release resources before exiting. An alternative to sending `SIGTERM` directly to the process.

## Running the tests

`test_bridge.py` covers the WAV encode/decode helpers and the Flask endpoints in passthrough mode (no model, no GPU), plus progress tracking, input limits and the wrapper instrumentation against a stub pipeline — 32 tests that always run, plus one opt-in live-inference test that is skipped unless a real ACE-Step checkpoint and `ACE_BRIDGE_LIVE_INFER=1` are provided.

```bash
pip install pytest numpy
pytest test_bridge.py -v
```

Verified output from this checkout:

```
collected 33 items
32 passed, 1 skipped in 5.4s
```

The single skip is `TestLiveInfer::test_real_infer_changes_or_produces_audio`, which requires a real ACE-Step checkpoint (found automatically under `../../models/ace-step-v1.5-base` relative to the repo this bridge lives in, or pointed to via `ACE_BRIDGE_MODEL_PATH`) and `ACE_BRIDGE_LIVE_INFER=1` set explicitly — it is not expected to run in a plain checkout.

## Performance

Measure with the bundled harness against a running server (stdlib only):

```bash
python bench_bridge.py --url http://127.0.0.1:8976 --durations 3,10,30 --steps 8 --repeat 3
```

It prints wall time, real-time factor (RTF = wall seconds per second of audio; lower is better, below 1.0 is faster than real time), and the per-phase `timings` the server returns.

### Measured results

Hardware: Apple M1 Max, 32 GB unified memory, PyTorch 2.10 (MPS), ACE-Step v1 3.5B, `cover` task, mono float32 input at 48 kHz, `num_steps=8`, `input_strength=0.6` (3 diffusion steps run). The machine was shared with other heavy processes: 1-minute load average was 8-15 during every run below, and one resident 5 GB process was competing for memory. Treat absolute numbers as indicative and the ratios as the finding; runs are n=3 per row.

| Configuration | Audio | Wall s (runs) | Median RTF |
|---|---|---|---|
| Before (original server, float32) | 3 s | 42.2, 38.9, 57.2 | 14.1 |
| Before (original server, float32) | 5 s | 45.8, 87.0, 67.6 | 13.5 |
| After (`--dtype float16 --warmup`, defaults) | 3 s | 2.2, 1.1, 1.1 | 0.4 |
| After | 5 s | 2.2, 1.3, 1.3 | 0.3 |
| After | 10 s | 3.3, 2.3, 2.4 | 0.2 |
| After | 30 s | 6.9, 8.2, 7.5 | 0.3 |
| After, float32 only (`--dtype float32 --warmup`) | 3 s | 71.3, 38.1, 61.1 | 20.4 |
| After, float32 only | 5 s | 57.8, 33.7, 35.3 | 7.1 |

The first request per new clip length or prompt is about 1 s slower than the following ones (one-time shape and prompt set-up); after that the per-take cost scales with duration. The original server could not accept 10 s or 30 s clips at all (`413`).

Per-phase breakdown, 3 s clip, warm (after / float32 only), seconds:

| Phase | float16 | float32 |
|---|---|---|
| text encode | 0.00 (cached) | 0.00 (cached) |
| VAE encode | 0.1 | 0.7-1.3 |
| conditioning encode (`cond_encode`) | 0.01 | 20-26 |
| diffusion loop (3 steps) | 0.65 | 6.6-35 |
| VAE decode (vocoder) | 0.32 | 6.8-7.2 |

### Where the fixed cost came from

- The fixed 25-30 s per call was not the diffusion steps and not text encoding. In float32 on MPS, the small conditioning encode inside the transformer (`cond_encode`) took 20-26 s on every call and the vocoder took about 6.5 s, regardless of clip length. The same operations take 0.01 s in isolation once warm, and ACE-Step does not offload models between calls (`cpu_offload=False` by default; the pipeline is reused). The cost tracked memory and GPU contention: the float32 model is about 14 GB, on a 32 GB machine that is also running other large processes. Halving the weights (float16) removed it. This attribution is inferred from the measurements above and from isolated timing runs; it was not proven with a memory profiler.
- ACE-Step forces float32 on MPS. Float16 gives audio with a correlation of 0.88 to float32 for the same seed and similar level; bfloat16 does not (correlation about 0). `--dtype float32` restores the previous behaviour if bit-for-bit fidelity to it matters.
- The first request after start still pays kernel/weight initialisation: 15-70 s when the model files are not in the OS page cache, about 4 s once they are. `--warmup` moves this to startup.
- Smaller wins: the pipeline's per-call `gc.collect()` (0.5-1.2 s) now runs every 10 calls, text-encoder outputs are cached per prompt, and requests are serialised with a lock instead of racing on the shared pipeline.

### What cannot be improved from the bridge

- Each call re-encodes the reference audio and re-runs the full VAE decode inside ACE-Step; a persistent latent cache between calls would need changes to `ACEStepPipeline`.
- The pipeline only exchanges audio through WAV files on disk (small: about 0.02 s), and rebuilds its scheduler and resampler per call.
- In `cover` mode CFG runs two transformer passes per step; there is no wrapper-side switch for a single-pass mode without changing guidance behaviour (`guidance_scale=1` disables it but changes output).
- Step-level progress relies on replacing the `tqdm` name inside `acestep.pipeline_ace_step`; an ACE-Step refactor of the loop would silently fall back to the estimated step count.

## ACE-Step license note

ACE-Step is distributed under the **Apache License, Version 2.0** (`ACE-Step/LICENSE` in the upstream repository; copyright 2025 Timedomain Inc. and stepfun). Apache-2.0 is permissive but has explicit redistribution conditions if you distribute the ACE-Step source or a derivative of it — among them: include a copy of the license, mark any files you changed, and preserve existing copyright/attribution notices. This bridge only talks to ACE-Step over its Python API at runtime and does not vendor or redistribute ACE-Step's code; if you package or redistribute ACE-Step itself (or a modified copy of it) alongside this bridge, review the Apache-2.0 terms in that upstream LICENSE file for what's required. This note is informational, not legal advice — consult the upstream license text and your own counsel for any redistribution decision.
