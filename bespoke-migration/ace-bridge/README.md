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
python ace_bridge_server.py [--host 127.0.0.1] [--port 8976] [--model-path PATH] [--device auto|cpu|mps|cuda] [--debug]
```

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

Same as `/health` plus the resolved `model_path`, the fixed `sample_rate`/`buffer_size` the server assumes (48000 Hz), and the server `version`.

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

Only `audio` is required; every other field falls back to the default shown above. `audio` must be a base64-encoded WAV (16-bit PCM, 24-bit PCM, or 32-bit float; mono or multi-channel — multi-channel input is mixed down to mono). Request size is capped (1.4M base64 characters / 2MB decoded, roughly 10 seconds of mono float32 audio at 48 kHz) and oversized requests get a `413`.

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
  "model_type": "base"
}
```

On error, the response is `{"error": "<message>"}` with a `400` (bad input), `413` (payload too large), or `500` (inference failure) status.

### `POST /shutdown`

Requests a graceful shutdown, so the process can release resources before exiting. An alternative to sending `SIGTERM` directly to the process.

## Running the tests

`test_bridge.py` covers the WAV encode/decode helpers and the Flask endpoints in passthrough mode (no model, no GPU) — 15 tests that always run, plus one opt-in live-inference test that is skipped unless a real ACE-Step checkpoint and `ACE_BRIDGE_LIVE_INFER=1` are provided.

```bash
pip install pytest numpy
pytest test_bridge.py -v
```

Verified output from this checkout:

```
collected 16 items
15 passed, 1 skipped in 0.20s
```

The single skip is `TestLiveInfer::test_real_infer_changes_or_produces_audio`, which requires a real ACE-Step checkpoint (found automatically under `../../models/ace-step-v1.5-base` relative to the repo this bridge lives in, or pointed to via `ACE_BRIDGE_MODEL_PATH`) and `ACE_BRIDGE_LIVE_INFER=1` set explicitly — it is not expected to run in a plain checkout.

## ACE-Step license note

ACE-Step is distributed under the **Apache License, Version 2.0** (`ACE-Step/LICENSE` in the upstream repository; copyright 2025 Timedomain Inc. and stepfun). Apache-2.0 is permissive but has explicit redistribution conditions if you distribute the ACE-Step source or a derivative of it — among them: include a copy of the license, mark any files you changed, and preserve existing copyright/attribution notices. This bridge only talks to ACE-Step over its Python API at runtime and does not vendor or redistribute ACE-Step's code; if you package or redistribute ACE-Step itself (or a modified copy of it) alongside this bridge, review the Apache-2.0 terms in that upstream LICENSE file for what's required. This note is informational, not legal advice — consult the upstream license text and your own counsel for any redistribution decision.
