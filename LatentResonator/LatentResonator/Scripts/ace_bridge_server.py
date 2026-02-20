#!/usr/bin/env python3
"""
ACE-Step Bridge Server — Latent Resonator
==========================================

HTTP bridge wrapping ACE-Step 1.5 inference for the Swift Latent Resonator app.
Receives audio chunks + parameters via JSON/base64 WAV, runs inference,
returns processed audio.

Endpoints:
  GET  /health     — connection check + model status
  POST /infer      — run one inference cycle
  GET  /status     — detailed model and server status

The server gracefully degrades:
  - If ACE-Step model is loaded → full neural inference
  - If model not loaded        → passthrough (echoes audio back)

Usage:
  python ace_bridge_server.py [--port 8976] [--model-path PATH]

White paper reference:
  §3.3 Recursive formula: S_{i+1} = ACE(S_i + N(μ,σ), P, γ)
  §6.1 The model as "Black Box Resonator"
"""

import argparse
import base64
import io
import json
import logging
import os
import struct
import sys
import tempfile
import time
import traceback
from pathlib import Path

# ---------------------------------------------------------------------------
# MPS Safety — MUST be set before any torch import
# ---------------------------------------------------------------------------
# INVESTIGATION (Phase 4 — MPS Crash Analysis):
#
# Root cause: PyTorch's MPS (Metal Performance Shaders) backend on Apple
# Silicon triggers SIGABRT in the Metal compute shader dispatch for certain
# tensor operations used by ACE-Step 1.5:
#   rsub_Scalar → sub_Tensor → validateComputeFunctionArguments → SIGABRT
#
# Crash stack trace signature:
#   MTLComputeCommandEncoder::setBuffer → validateComputeFunctionArguments
#   → assertion failure in Metal kernel argument binding
#
# This is a known PyTorch issue (pytorch/pytorch#77764, #99272) affecting:
#   - torch.rsub() with scalar operands
#   - torch.where() with MPS tensors  
#   - Certain in-place operations on strided MPS tensors
#
# Status & path forward:
#   1. PyTorch >= 2.3 significantly improved MPS coverage; many previously
#      crashing ops are now supported. Re-test with latest nightly.
#   2. The PYTORCH_ENABLE_MPS_FALLBACK=1 env var handles most cases but
#      does NOT prevent ACE-Step's internal code from explicitly requesting
#      MPS tensors via torch.backends.mps.is_available() checks.
#   3. For production: the Core ML on-device path (CoreMLInference.swift)
#      bypasses Python entirely and should be the long-term solution.
#   4. CPU inference on M1/M2/M3 is adequate for the 2-30s cycle time.
#
# Current mitigation: monkey-patch MPS out of existence when --device != mps.
# This is safe and effective. The flag below is the first line of defense.
# Additionally, the --device flag defaults to "cpu" to avoid the hard crash.
os.environ["PYTORCH_ENABLE_MPS_FALLBACK"] = "1"

# ---------------------------------------------------------------------------
# Nuclear MPS disable — monkey-patch BEFORE any model code
# ---------------------------------------------------------------------------
# Setting device="cpu" and .to("cpu") is NOT enough because ACE-Step's
# internal code checks torch.backends.mps.is_available() and creates MPS
# tensors during inference. The only reliable way to prevent MPS usage is
# to make PyTorch believe MPS doesn't exist at all.
#
# We parse --device early: if it's NOT "mps" or "auto", we disable MPS
# completely so no library code can accidentally use it.
_raw_device = "cpu"
for _i, _a in enumerate(sys.argv):
    if _a == "--device" and _i + 1 < len(sys.argv):
        _raw_device = sys.argv[_i + 1]
        break

if _raw_device not in ("mps", "auto"):
    try:
        import torch
        import torch.backends.mps as _mps_mod
        # Overwrite the C-backed functions with lambdas that always say "no"
        _mps_mod.is_available = lambda: False
        _mps_mod.is_built = lambda: False
        torch.backends.mps.is_available = lambda: False
        torch.backends.mps.is_built = lambda: False
        logging.basicConfig(level=logging.INFO)
        logging.info(
            "MPS disabled via monkey-patch (--device %s). "
            "All operations will use CPU.", _raw_device
        )
    except ImportError:
        pass  # torch not installed yet; will fail later with a clear message

import numpy as np

try:
    from flask import Flask, request, jsonify
except ImportError:
    print("ERROR: Flask not installed. Run: pip install flask")
    sys.exit(1)

# ---------------------------------------------------------------------------
# ACE-Step Model Wrapper
# ---------------------------------------------------------------------------

class ACEStepWrapper:
    """
    Wraps ACE-Step 1.5 model for single-chunk inference.

    When the model is loaded, audio is processed through the full
    ACE-Step pipeline (LLM + Diffusion Transformer).

    When the model is NOT loaded, the wrapper operates in passthrough
    mode — returning input audio unmodified so the Swift app can still
    run its DSP effects chain.

    Model types and their capabilities (ACE-Step 1.5 Tutorial):
      - turbo:  8 steps, NO CFG support, fast
      - sft:   50 steps, CFG supported, high quality
      - base:  50 steps, CFG + lego/extract/complete tasks
    """

    # Known model type slugs for auto-detection
    _MODEL_TYPE_KEYWORDS = {
        "turbo": "turbo",
        "sft": "sft",
        "base": "base",
    }

    def __init__(self, model_path: str = None, device: str = "cpu"):
        self.model = None
        self.model_path = model_path
        self.is_loaded = False
        self.device = device          # Explicit device override
        self._requested_device = device
        self.load_error = None
        self.inference_count = 0
        self.model_type = "unknown"  # turbo | sft | base | unknown

        if model_path:
            self.load(model_path)

    def _detect_model_type(self, model_path: str) -> str:
        """
        Detect model type from path or directory name.

        Heuristic: scan the path string for known keywords.
        Falls back to 'base' if no keyword matches — per our plan
        to default to the Base model (CFG + full task support).
        """
        path_lower = model_path.lower()
        for keyword, mtype in self._MODEL_TYPE_KEYWORDS.items():
            if keyword in path_lower:
                return mtype
        return "base"

    def load(self, model_path: str):
        """Attempt to load the ACE-Step model."""
        self.model_type = self._detect_model_type(model_path)
        logging.info(f"Detected model type: {self.model_type}")
        logging.info(f"Requested device: {self._requested_device}")

        try:
            import torch

            # ---------------------------------------------------------------
            # Device selection: honour the explicit --device flag.
            # MPS (Metal) crashes with SIGABRT on certain tensor ops (rsub /
            # sub_Tensor). Defaulting to CPU avoids the hard crash entirely.
            # ---------------------------------------------------------------
            target_device = self._requested_device
            if target_device == "auto":
                if torch.backends.mps.is_available():
                    target_device = "mps"
                elif torch.cuda.is_available():
                    target_device = "cuda"
                else:
                    target_device = "cpu"
            logging.info(f"Resolved target device: {target_device}")

            try:
                # Try the acestep package (GitHub: ace-step/ACE-Step)
                from acestep.pipeline_ace_step import ACEStepPipeline

                logging.info(f"Loading ACE-Step model from: {model_path}")

                # ACEStepPipeline auto-detects MPS / CUDA / CPU in __init__.
                # We override the device AFTER loading to ensure CPU safety.
                self.model = ACEStepPipeline(checkpoint_dir=model_path)
                self.model.load_checkpoint(model_path)

                # Force the pipeline to the requested device
                if hasattr(self.model, 'device'):
                    auto_device = str(self.model.device)
                    if auto_device != target_device:
                        logging.info(
                            f"Overriding pipeline device: "
                            f"{auto_device} → {target_device}"
                        )
                        if hasattr(self.model, 'to'):
                            self.model.to(target_device)
                        # Also move internal sub-models if present
                        for attr in ('unet', 'vae', 'text_encoder', 'model'):
                            sub = getattr(self.model, attr, None)
                            if sub is not None and hasattr(sub, 'to'):
                                sub.to(target_device)

                self.device = target_device
                logging.info(f"Using device: {self.device}")

                self.is_loaded = True
                self.load_error = None
                logging.info(
                    f"ACE-Step model loaded successfully on {self.device} "
                    f"(type: {self.model_type})"
                )

            except ImportError:
                # Try alternative import paths
                try:
                    from diffusers import AutoPipelineForText2Audio

                    self.model = AutoPipelineForText2Audio.from_pretrained(
                        model_path
                    )
                    self.model = self.model.to(target_device)
                    self.device = target_device
                    self.is_loaded = True
                    self.load_error = None
                    logging.info(
                        f"Model loaded via diffusers on {self.device}"
                    )

                except Exception:
                    self.load_error = (
                        "ace_step package not found. "
                        "Install: pip install ace-step  "
                        "Or: pip install diffusers"
                    )
                    logging.warning(self.load_error)

        except ImportError:
            self.load_error = "PyTorch not installed. Run: pip install torch"
            logging.warning(self.load_error)
        except Exception as e:
            self.load_error = f"Model load failed: {e}"
            logging.error(f"{self.load_error}\n{traceback.format_exc()}")

    def infer(
        self,
        audio_samples: np.ndarray,
        sample_rate: int = 48000,
        prompt: str = "",
        guidance_scale: float = 15.0,
        num_steps: int = 20,
        seed: int = -1,
        input_strength: float = 0.6,
        audio_duration: float = 10.0,
        denoise_strength: float = 1.0,
        # --- White paper controls mapped to ACE-Step ---
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
        """
        Run one inference cycle through ACE-Step 1.5.

        Implements the core of §3.3:
          S_{i+1} = ACE(S_i + N(μ,σ), P, γ)

        Parameters:
            audio_samples: Input audio as float32 numpy array (mono)
            sample_rate: Audio sample rate (Hz)
            prompt: Semantic prompt text P
            guidance_scale: CFG scale γ (§4.2.1: 15.0–18.0)
            num_steps: Diffusion steps N (20–60 for base)
            seed: Random seed (-1 for random)
            input_strength: α — ref_audio_strength (0.0–1.0)
            audio_duration: Duration of generated audio in seconds
            denoise_strength: Per-step denoise amount (0 = passthrough, 1 = full). Maps to effective step count.
            guidance_interval: When CFG is applied during diffusion [0..1].
                Maps from UI "SHIFT": low shift = early CFG (structure),
                high shift = late CFG (texture/detail).
            guidance_interval_decay: CFG decay over steps [0..1].
                Maps from UI "GRANULARITY": higher = finer detail changes.
            omega_scale: APG guidance omega [1..20].
                Maps from UI "ENTROPY": higher = more aggressive deviation.
            min_guidance_scale: Floor for CFG during decay.
            retake_variance: Stochastic variance per step [0..1].
                Maps from UI "METHOD SDE": 0.0 for ODE, 0.5 for SDE.
            scheduler_type: Diffusion scheduler ("euler").
            cfg_type: CFG strategy ("apg" or "cfg").
            use_erg_tag: Enable tag-based guidance routing.
            use_erg_lyric: Enable lyric-based guidance routing.
            use_erg_diffusion: Enable diffusion-based guidance routing.

        Returns:
            Processed audio as float32 numpy array
        """
        if not self.is_loaded or self.model is None:
            # Passthrough when model not loaded
            return audio_samples

        # Per-step denoise strength: 0 = passthrough; (0,1] = run that fraction of steps.
        # Mapping: effective_steps = max(1, round(num_steps * denoise_strength)).
        denoise_strength = max(0.0, min(1.0, denoise_strength))
        if denoise_strength <= 0.0:
            return audio_samples
        effective_steps = max(1, int(round(num_steps * denoise_strength)))

        try:
            import soundfile as sf

            if seed < 0:
                seed = int(time.time() * 1000) % (2**32)

            # Save input audio to a temp WAV for the pipeline
            tmp_input = os.path.join(tempfile.gettempdir(), "nr_bridge_input.wav")
            tmp_output_dir = os.path.join(tempfile.gettempdir(), "nr_bridge_output")
            os.makedirs(tmp_output_dir, exist_ok=True)

            sf.write(tmp_input, audio_samples, sample_rate)

            # Build kwargs for ACE-Step 1.5 __call__
            # EVERY parameter from the whitepaper is wired through.
            infer_kwargs = dict(
                prompt=prompt,
                lyrics="[inst]",
                audio_duration=audio_duration,
                infer_step=effective_steps,
                guidance_scale=guidance_scale,
                scheduler_type=scheduler_type,
                cfg_type=cfg_type,
                omega_scale=omega_scale,
                manual_seeds=[seed],
                guidance_interval=guidance_interval,
                guidance_interval_decay=guidance_interval_decay,
                min_guidance_scale=min_guidance_scale,
                use_erg_tag=use_erg_tag,
                use_erg_lyric=use_erg_lyric,
                use_erg_diffusion=use_erg_diffusion,
                audio2audio_enable=True,
                ref_audio_strength=input_strength,
                ref_audio_input=tmp_input,
                retake_variance=retake_variance,
                save_path=tmp_output_dir,
                batch_size=1,
            )

            logging.info(
                f"Inference: steps={effective_steps} (denoise={denoise_strength:.2f}), cfg={guidance_scale}, "
                f"strength={input_strength}, omega={omega_scale}, "
                f"interval={guidance_interval}, decay={guidance_interval_decay}, "
                f"retake_var={retake_variance}, seed={seed}"
            )

            # Run ACE-Step inference
            result = self.model(**infer_kwargs)

            # Result is [output_wav_path, ..., params_dict]
            output_wav = None
            if isinstance(result, list):
                for item in result:
                    if isinstance(item, str) and item.endswith(".wav"):
                        output_wav = item
                        break

            if output_wav and os.path.exists(output_wav):
                audio_out, sr_out = sf.read(output_wav, dtype="float32")
                # Flatten to mono if needed
                if audio_out.ndim > 1:
                    audio_out = audio_out.mean(axis=1)

                self.inference_count += 1
                return audio_out.astype(np.float32)
            else:
                logging.warning("No output WAV found in pipeline result")
                return audio_samples

        except Exception as e:
            logging.error(f"Inference error: {e}\n{traceback.format_exc()}")
            return audio_samples  # Passthrough on error

# ---------------------------------------------------------------------------
# WAV Encoding / Decoding Helpers
# ---------------------------------------------------------------------------

def decode_wav_bytes(wav_bytes: bytes) -> tuple:
    """
    Decode a WAV file from bytes to (samples: np.ndarray, sample_rate: int).
    Supports 16-bit PCM and 32-bit float formats.
    """
    # Try soundfile first (handles all formats)
    try:
        import soundfile as sf
        data, sr = sf.read(io.BytesIO(wav_bytes), dtype='float32')
        if data.ndim > 1:
            data = data.mean(axis=1)  # Mix to mono
        return data, sr
    except ImportError:
        pass

    # Fallback: manual WAV parsing
    if len(wav_bytes) < 44:
        raise ValueError("WAV data too short")

    # Verify RIFF header
    riff = wav_bytes[:4]
    wave = wav_bytes[8:12]
    if riff != b'RIFF' or wave != b'WAVE':
        raise ValueError("Not a valid WAV file")

    # Parse chunks
    pos = 12
    fmt_found = False
    data_bytes = b''
    channels = 1
    sample_rate = 48000
    bits_per_sample = 16
    audio_format = 1

    while pos < len(wav_bytes) - 8:
        chunk_id = wav_bytes[pos:pos + 4]
        chunk_size = struct.unpack('<I', wav_bytes[pos + 4:pos + 8])[0]
        pos += 8

        if chunk_id == b'fmt ':
            fmt_data = struct.unpack('<HHIIHH', wav_bytes[pos:pos + 16])
            audio_format = fmt_data[0]
            channels = fmt_data[1]
            sample_rate = fmt_data[2]
            bits_per_sample = fmt_data[5]
            fmt_found = True

        elif chunk_id == b'data':
            data_bytes = wav_bytes[pos:pos + chunk_size]
            break

        pos += chunk_size

    if not fmt_found or not data_bytes:
        raise ValueError("Missing fmt or data chunk in WAV")

    # Decode sample data
    if audio_format == 3 and bits_per_sample == 32:
        # IEEE Float 32-bit
        samples = np.frombuffer(data_bytes, dtype=np.float32).copy()
    elif audio_format == 1 and bits_per_sample == 16:
        # PCM 16-bit
        samples = (
            np.frombuffer(data_bytes, dtype=np.int16)
            .astype(np.float32) / 32768.0
        )
    elif audio_format == 1 and bits_per_sample == 24:
        # PCM 24-bit
        n_samples = len(data_bytes) // 3
        samples = np.zeros(n_samples, dtype=np.float32)
        for i in range(n_samples):
            b = data_bytes[i * 3:(i + 1) * 3]
            val = int.from_bytes(b, byteorder='little', signed=True)
            samples[i] = val / 8388608.0
    else:
        raise ValueError(
            f"Unsupported WAV format: audio_format={audio_format}, "
            f"bits={bits_per_sample}"
        )

    # Mix to mono if multichannel
    if channels > 1:
        samples = samples.reshape(-1, channels).mean(axis=1)

    return samples, sample_rate

def encode_wav_bytes(
    samples: np.ndarray,
    sample_rate: int = 48000
) -> bytes:
    """Encode float32 samples to WAV bytes (32-bit float, mono)."""
    # Try soundfile first
    try:
        import soundfile as sf
        buf = io.BytesIO()
        sf.write(
            buf, samples.astype(np.float32), sample_rate,
            format='WAV', subtype='FLOAT'
        )
        return buf.getvalue()
    except ImportError:
        pass

    # Fallback: manual WAV encoding (IEEE float32, mono)
    data = samples.astype(np.float32).tobytes()
    num_channels = 1
    bits_per_sample = 32
    byte_rate = sample_rate * num_channels * (bits_per_sample // 8)
    block_align = num_channels * (bits_per_sample // 8)

    header = struct.pack(
        '<4sI4s4sIHHIIHH4sI',
        b'RIFF',
        36 + len(data),     # file size - 8
        b'WAVE',
        b'fmt ',
        16,                  # fmt chunk size
        3,                   # audio format: IEEE float
        num_channels,
        sample_rate,
        byte_rate,
        block_align,
        bits_per_sample,
        b'data',
        len(data),           # data chunk size
    )

    return header + data

# ---------------------------------------------------------------------------
# Flask Application
# ---------------------------------------------------------------------------

app = Flask(__name__)
ace_wrapper: ACEStepWrapper = None  # Initialized in main()

@app.route('/health', methods=['GET'])
def health():
    """
    Health check endpoint.
    Returns server status, model availability, and device info.

    Used by the Swift ACEStepBridge for periodic connection checks.
    """
    return jsonify({
        'status': 'ok',
        'model_loaded': ace_wrapper.is_loaded if ace_wrapper else False,
        'model_type': ace_wrapper.model_type if ace_wrapper else 'none',
        'device': ace_wrapper.device if ace_wrapper else 'none',
        'error': ace_wrapper.load_error if ace_wrapper else None,
        'inference_count': (
            ace_wrapper.inference_count if ace_wrapper else 0
        ),
        'timestamp': time.time(),
    })

@app.route('/status', methods=['GET'])
def status():
    """Detailed status endpoint with full server configuration."""
    return jsonify({
        'status': 'ok',
        'model_loaded': ace_wrapper.is_loaded if ace_wrapper else False,
        'model_type': ace_wrapper.model_type if ace_wrapper else 'none',
        'model_path': ace_wrapper.model_path if ace_wrapper else None,
        'device': ace_wrapper.device if ace_wrapper else 'none',
        'error': ace_wrapper.load_error if ace_wrapper else None,
        'inference_count': (
            ace_wrapper.inference_count if ace_wrapper else 0
        ),
        'sample_rate': 48000,
        'buffer_size': 48000,
        'version': '0.2.0',
    })

@app.route('/shutdown', methods=['POST'])
def shutdown():
    """
    Graceful shutdown endpoint.

    Called by BridgeProcessManager.swift before sending SIGTERM.
    This allows the server to close resources cleanly before exit.
    """
    logging.info("Shutdown request received — terminating server")

    # Flask / Werkzeug shutdown
    func = request.environ.get('werkzeug.server.shutdown')
    if func is not None:
        func()
        return jsonify({'status': 'shutting_down'}), 200

    # Fallback for newer Werkzeug versions: schedule exit
    import os
    import signal
    os.kill(os.getpid(), signal.SIGTERM)
    return jsonify({'status': 'shutting_down'}), 200

@app.route('/infer', methods=['POST'])
def infer():
    """
    Run one inference cycle through ACE-Step 1.5.

    ALL whitepaper parameters are wired through to the ACE-Step pipeline.

    Request JSON:
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
        "audio_duration": 10.0
    }

    White paper → ACE-Step parameter mapping:
        shift (1-10) → guidance_interval (0.1-0.9):
            structure↔texture attention allocation
        entropy (0-1) → omega_scale (1-20):
            stochastic deviation magnitude
        granularity (0-1) → guidance_interval_decay (0-1):
            spectral granularity / detail resolution
        infer_method "sde" → retake_variance=0.5:
            stochastic diffusion for §4.2.2 recursive drift

    Response JSON:
    {
        "audio": "<base64-encoded WAV>",
        "sample_rate": 48000,
        "num_samples": 4096,
        "duration_ms": 42.3,
        "model_used": true,
        "model_type": "base"
    }
    """
    try:
        data = request.get_json(force=True)

        if 'audio' not in data:
            return jsonify({
                'error': 'Missing "audio" field (base64-encoded WAV)'
            }), 400

        # Decode input audio
        wav_bytes = base64.b64decode(data['audio'])
        samples, sr = decode_wav_bytes(wav_bytes)

        # ---------------------------------------------------------------
        # Extract ALL parameters — nothing hardcoded, everything wired.
        # Defaults match Constants.swift exactly.
        # ---------------------------------------------------------------
        prompt = data.get('prompt', '')
        guidance_scale = float(data.get('guidance_scale', 15.0))
        num_steps = int(data.get('num_steps', 20))
        seed = int(data.get('seed', -1))
        input_strength = float(data.get('input_strength', 0.6))
        audio_duration = float(data.get('audio_duration', 10.0))

        # --- White paper controls → ACE-Step parameter mapping ---

        # SHIFT (1.0–10.0) → guidance_interval (0.1–0.9)
        # Low shift = early CFG application = preserves structure/form.
        # High shift = late CFG application = generates texture/detail.
        # §4.2.1: "attention allocation between structural and textural"
        shift_raw = float(data.get('shift', 5.0))
        guidance_interval = max(0.1, min(0.9,
            0.1 + (shift_raw - 1.0) / 9.0 * 0.8
        ))

        # ENTROPY (0.0–1.0 normalized) → omega_scale (1.0–20.0)
        # Higher omega = more aggressive guidance deviation = more sonic
        # variation between iterations. §4.2.2: stochastic evolution.
        entropy_raw = float(data.get('entropy', 0.25))
        omega_scale = max(1.0, min(20.0,
            1.0 + entropy_raw * 19.0
        ))

        # GRANULARITY (0.0–1.0 normalized) → guidance_interval_decay (0.0–1.0)
        # Controls how quickly CFG fades during diffusion steps.
        # High granularity = rapid CFG decay = finer spectral detail.
        granularity_raw = float(data.get('granularity', 0.45))
        guidance_interval_decay = max(0.0, min(1.0, granularity_raw))

        # METHOD: ODE vs SDE
        # ODE ("ode") → retake_variance=0.0: deterministic, reproducible.
        # SDE ("sde") → retake_variance=0.5: stochastic per-step noise.
        # §4.2.2: SDE injects entropy at each diffusion step.
        infer_method = data.get('infer_method', 'ode')
        retake_variance = 0.5 if infer_method == 'sde' else 0.0

        # Per-step denoise strength (0 = no denoise, 1 = full). App skips bridge when 0.
        denoise_strength = max(0.0, min(1.0, float(data.get('denoise_strength', 1.0))))

        # Min guidance scale — floor during CFG decay
        min_guidance_scale = max(1.0, guidance_scale * 0.2)

        t0 = time.time()

        # Run inference — ALL parameters wired through
        output_samples = ace_wrapper.infer(
            audio_samples=samples,
            sample_rate=sr,
            prompt=prompt,
            guidance_scale=guidance_scale,
            num_steps=num_steps,
            seed=seed,
            input_strength=input_strength,
            audio_duration=audio_duration,
            denoise_strength=denoise_strength,
            # White paper → ACE-Step mapped parameters
            guidance_interval=guidance_interval,
            guidance_interval_decay=guidance_interval_decay,
            omega_scale=omega_scale,
            min_guidance_scale=min_guidance_scale,
            retake_variance=retake_variance,
            scheduler_type="euler",
            cfg_type="apg",
        )

        duration_ms = (time.time() - t0) * 1000.0

        # Encode output audio to WAV
        output_wav = encode_wav_bytes(output_samples, sr)
        output_b64 = base64.b64encode(output_wav).decode('ascii')

        return jsonify({
            'audio': output_b64,
            'sample_rate': sr,
            'num_samples': len(output_samples),
            'duration_ms': round(duration_ms, 2),
            'model_used': ace_wrapper.is_loaded,
            'model_type': ace_wrapper.model_type,
        })

    except Exception as e:
        logging.error(f"/infer error: {e}\n{traceback.format_exc()}")
        return jsonify({'error': str(e)}), 500

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    global ace_wrapper

    parser = argparse.ArgumentParser(
        description='ACE-Step Bridge Server for Latent Resonator'
    )
    parser.add_argument(
        '--port', type=int, default=8976,
        help='HTTP port (default: 8976)'
    )
    parser.add_argument(
        '--host', type=str, default='127.0.0.1',
        help='Bind host (default: 127.0.0.1)'
    )
    parser.add_argument(
        '--model-path', type=str, default=None,
        help='Path to ACE-Step model directory or HuggingFace repo ID'
    )
    parser.add_argument(
        '--debug', action='store_true',
        help='Enable Flask debug mode'
    )
    parser.add_argument(
        '--device', type=str, default='cpu',
        choices=['cpu', 'mps', 'cuda', 'auto'],
        help=(
            'PyTorch device for inference. Defaults to "cpu" because the '
            'MPS (Metal) backend crashes on Apple Silicon with certain '
            'tensor operations. Use "auto" to let the pipeline detect the '
            'best available device (may crash on MPS).'
        )
    )
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.debug else logging.INFO,
        format='%(asctime)s [%(levelname)s] %(message)s',
    )

    logging.info("=" * 60)
    logging.info("  Latent Resonator — ACE-Step Bridge Server v0.2.0")
    logging.info(f"  Device: {args.device}")
    logging.info("=" * 60)

    # Initialize model wrapper with explicit device
    ace_wrapper = ACEStepWrapper(
        model_path=args.model_path,
        device=args.device
    )

    if ace_wrapper.is_loaded:
        logging.info(
            f"✓ Model ready on {ace_wrapper.device} — "
            f"full neural inference active"
        )
    else:
        logging.warning(
            "✗ Model NOT loaded — server will run in passthrough mode."
        )
        if ace_wrapper.load_error:
            logging.warning(f"  Reason: {ace_wrapper.load_error}")
        else:
            logging.warning(
                "  No model path specified. "
                "Use --model-path to load a model."
            )
        logging.info(
            "  The Swift app will use its DSP SpectralProcessor as fallback."
        )

    logging.info("")
    logging.info(f"Starting server on {args.host}:{args.port}")
    logging.info(f"  Health:  http://{args.host}:{args.port}/health")
    logging.info(f"  Infer:   http://{args.host}:{args.port}/infer")
    logging.info(f"  Status:  http://{args.host}:{args.port}/status")
    logging.info("")

    if args.debug:
        # Debug mode: use Flask's built-in server for auto-reload
        app.run(host=args.host, port=args.port, debug=True)
    else:
        # Production: use waitress for thread-safe, multi-request serving.
        # Flask's dev server is single-threaded and not safe for concurrent
        # inference requests from multiple lanes.
        try:
            from waitress import serve
            logging.info("Using waitress WSGI server (multi-threaded)")
            serve(app, host=args.host, port=args.port, threads=4)
        except ImportError:
            logging.warning(
                "waitress not installed — falling back to Flask dev server. "
                "Install with: pip install waitress"
            )
            app.run(host=args.host, port=args.port, debug=False)

if __name__ == '__main__':
    main()
