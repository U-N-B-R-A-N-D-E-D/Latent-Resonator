#!/usr/bin/env python3
"""
ACE-Step Bridge Server
=======================

A standalone HTTP bridge around ACE-Step 1.5 inference. Any client that
speaks its JSON/HTTP API can send audio + parameters and receive processed
audio back — the server has no dependency on a particular host application.

Receives an audio chunk plus generation parameters as a JSON request with a
base64-encoded WAV payload, runs inference, and returns the processed audio
the same way.

Endpoints:
  GET  /health     — connection check + model status
  GET  /status     — detailed model and server status
  POST /infer      — run one inference cycle
  POST /shutdown   — graceful shutdown

The server degrades gracefully:
  - If an ACE-Step model is loaded → full neural inference
  - If no model is loaded          → passthrough (echoes audio back unchanged),
    so a host can still apply its own processing chain as a fallback.

Usage:
  python ace_bridge_server.py [--port 8976] [--model-path PATH]

Parameter mapping reference:
  Originally derived from the Latent Resonator project's design notes
  (recursive formula S_{i+1} = ACE(S_i + N(mu, sigma), P, gamma); the model
  treated as a "black box resonator"). See the /infer docstring below for
  how each request parameter maps onto the underlying ACE-Step arguments.
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
# MPS configuration for ACE-Step 1.5 v0.1.0+
# ---------------------------------------------------------------------------
# ACE-Step 1.5 officially supports Apple Silicon (MPS) but requires disabling
# the memory watermark to avoid spurious "MPS backend out of memory" errors.
# Must be set before torch is imported anywhere.
os.environ["PYTORCH_MPS_HIGH_WATERMARK_RATIO"] = "0.0"

# Enable the CPU fallback for ops not yet implemented on MPS.
os.environ["PYTORCH_ENABLE_MPS_FALLBACK"] = "1"

# ---------------------------------------------------------------------------
# Force CPU when LATENT_RESONATOR_FORCE_CPU=1
# ---------------------------------------------------------------------------
# Some PyTorch/MPS combinations crash with SIGABRT on certain tensor ops
# (e.g. rsub) via a Metal validation abort. This env var lets a host disable
# MPS entirely as a hard safety valve; it must run before torch is imported
# anywhere else in the process.
if os.environ.get("LATENT_RESONATOR_FORCE_CPU") == "1":
    import torch

    try:
        torch.set_default_device("cpu")
    except AttributeError:
        pass  # PyTorch < 2.1
    if hasattr(torch.backends, "mps"):
        torch.backends.mps.is_available = lambda: False
        torch.backends.mps.is_built = lambda: False


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
    Wraps ACE-Step 1.5 for single-chunk inference.

    When a model is loaded, audio is processed through the full ACE-Step
    pipeline (LLM + Diffusion Transformer). When no model is loaded, the
    wrapper operates in passthrough mode, returning the input audio
    unmodified so a host can fall back to its own processing chain.

    Model types and their capabilities (per the ACE-Step 1.5 documentation):
      - turbo:  8 steps, no CFG support, fast
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
        self.device = device
        self._requested_device = device
        self.load_error = None
        self.inference_count = 0
        self.model_type = "unknown"  # turbo | sft | base | unknown

        if model_path:
            self.load(model_path)

    def _detect_model_type(self, model_path: str) -> str:
        """
        Detect the model type from the path or directory name.

        Scans the path string for known keywords and falls back to "base"
        if none match, since base offers the fullest CFG and task support.
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

            # Device selection: honour the explicit --device flag. MPS
            # (Metal) crashes with SIGABRT on certain tensor ops (rsub /
            # sub_Tensor), so defaulting to CPU avoids the hard crash.
            # A host can set LATENT_RESONATOR_FORCE_CPU=1 to force CPU.
            if os.environ.get("LATENT_RESONATOR_FORCE_CPU") == "1":
                target_device = "cpu"
            else:
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
                # The acestep package (GitHub: ace-step/ACE-Step)
                from acestep.pipeline_ace_step import ACEStepPipeline

                logging.info(f"Loading ACE-Step model from: {model_path}")

                # ACEStepPipeline auto-detects MPS / CUDA / CPU in __init__;
                # override the device afterwards to guarantee our choice wins.
                self.model = ACEStepPipeline(checkpoint_dir=model_path)
                self.model.load_checkpoint(model_path)

                if hasattr(self.model, "device"):
                    auto_device = str(self.model.device)
                    if auto_device != target_device:
                        logging.info(
                            f"Overriding pipeline device: {auto_device} -> {target_device}"
                        )
                        if hasattr(self.model, "to"):
                            self.model.to(target_device)
                        # Also move internal sub-models, if present.
                        for attr in ("unet", "vae", "text_encoder", "model"):
                            sub = getattr(self.model, attr, None)
                            if sub is not None and hasattr(sub, "to"):
                                sub.to(target_device)

                self.device = target_device
                logging.info(f"Using device: {self.device}")

                # Ensure new tensors (e.g. scheduler state) are created on
                # CPU when running in CPU mode.
                if target_device == "cpu":
                    try:
                        torch.set_default_device("cpu")
                    except AttributeError:
                        pass

                self.is_loaded = True
                self.load_error = None
                logging.info(
                    f"ACE-Step model loaded successfully on {self.device} "
                    f"(type: {self.model_type})"
                )

            except ImportError:
                # Try an alternative import path.
                try:
                    from diffusers import AutoPipelineForText2Audio

                    self.model = AutoPipelineForText2Audio.from_pretrained(model_path)
                    self.model = self.model.to(target_device)
                    self.device = target_device
                    self.is_loaded = True
                    self.load_error = None
                    logging.info(f"Model loaded via diffusers on {self.device}")

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

        Parameters:
            audio_samples: Input audio as a float32 numpy array (mono)
            sample_rate: Audio sample rate (Hz)
            prompt: Semantic prompt text
            guidance_scale: CFG scale (typical range 15.0-18.0)
            num_steps: Diffusion steps (20-60 for the base model)
            seed: Random seed (-1 for random)
            input_strength: Reference-audio strength (0.0-1.0)
            audio_duration: Duration of generated audio in seconds
            denoise_strength: Per-step denoise amount (0 = passthrough,
                1 = full). Maps to an effective step count.
            guidance_interval: When CFG is applied during diffusion [0..1].
                Low values apply CFG early (structure); high values apply
                it late (texture/detail).
            guidance_interval_decay: CFG decay over steps [0..1]. Higher
                values mean finer detail changes.
            omega_scale: APG guidance omega [1..20]. Higher values mean
                more aggressive deviation between iterations.
            min_guidance_scale: Floor for CFG during decay.
            retake_variance: Stochastic variance per step [0..1]. 0.0 for
                a deterministic (ODE) run, 0.5 for a stochastic (SDE) run.
            scheduler_type: Diffusion scheduler ("euler").
            cfg_type: CFG strategy ("apg" or "cfg").
            use_erg_tag: Enable tag-based guidance routing.
            use_erg_lyric: Enable lyric-based guidance routing.
            use_erg_diffusion: Enable diffusion-based guidance routing.

        Returns:
            Processed audio as a float32 numpy array
        """
        if not self.is_loaded or self.model is None:
            return audio_samples

        # Effective steps = max(1, round(num_steps * denoise_strength)).
        # denoise_strength of 0 means "do nothing" (passthrough).
        denoise_strength = max(0.0, min(1.0, denoise_strength))
        if denoise_strength <= 0.0:
            return audio_samples
        effective_steps = max(1, int(round(num_steps * denoise_strength)))

        try:
            import soundfile as sf

            if seed < 0:
                seed = int(time.time() * 1000) % (2**32)

            with tempfile.TemporaryDirectory() as tmp_dir:
                tmp_input = os.path.join(tmp_dir, "input.wav")
                sf.write(tmp_input, audio_samples, sample_rate)

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
                    save_path=tmp_dir,
                    batch_size=1,
                )

                logging.info(
                    f"Inference: steps={effective_steps} (denoise={denoise_strength:.2f}), cfg={guidance_scale}, "
                    f"strength={input_strength}, omega={omega_scale}, "
                    f"interval={guidance_interval}, decay={guidance_interval_decay}, "
                    f"retake_var={retake_variance}, seed={seed}"
                )

                result = self.model(**infer_kwargs)

                output_wav = None
                if isinstance(result, list):
                    for item in result:
                        if isinstance(item, str) and item.endswith(".wav"):
                            output_wav = item
                            break

                if output_wav and os.path.exists(output_wav):
                    audio_out, sr_out = sf.read(output_wav, dtype="float32")
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
    # Prefer soundfile: it handles far more formats than the manual parser
    # below and is more forgiving of nonstandard chunk layouts.
    try:
        import soundfile as sf

        data, sr = sf.read(io.BytesIO(wav_bytes), dtype="float32")
        if data.ndim > 1:
            data = data.mean(axis=1)
        return data, sr
    except ImportError:
        pass

    # Fallback: manual WAV parsing, used only if soundfile is unavailable.
    if len(wav_bytes) < 44:
        raise ValueError("WAV data too short")

    riff = wav_bytes[:4]
    wave = wav_bytes[8:12]
    if riff != b"RIFF" or wave != b"WAVE":
        raise ValueError("Not a valid WAV file")

    pos = 12
    fmt_found = False
    data_bytes = b""
    channels = 1
    sample_rate = 48000
    bits_per_sample = 16
    audio_format = 1

    while pos < len(wav_bytes) - 8:
        chunk_id = wav_bytes[pos : pos + 4]
        chunk_size = struct.unpack("<I", wav_bytes[pos + 4 : pos + 8])[0]
        pos += 8

        if chunk_id == b"fmt ":
            fmt_data = struct.unpack("<HHIIHH", wav_bytes[pos : pos + 16])
            audio_format = fmt_data[0]
            channels = fmt_data[1]
            sample_rate = fmt_data[2]
            bits_per_sample = fmt_data[5]
            fmt_found = True

        elif chunk_id == b"data":
            data_bytes = wav_bytes[pos : pos + chunk_size]
            break

        pos += chunk_size

    if not fmt_found or not data_bytes:
        raise ValueError("Missing fmt or data chunk in WAV")

    if audio_format == 3 and bits_per_sample == 32:
        # IEEE float, 32-bit
        samples = np.frombuffer(data_bytes, dtype=np.float32).copy()
    elif audio_format == 1 and bits_per_sample == 16:
        # PCM, 16-bit
        samples = np.frombuffer(data_bytes, dtype=np.int16).astype(np.float32) / 32768.0
    elif audio_format == 1 and bits_per_sample == 24:
        # PCM, 24-bit — no native numpy dtype, so unpack byte-by-byte.
        n_samples = len(data_bytes) // 3
        samples = np.zeros(n_samples, dtype=np.float32)
        for i in range(n_samples):
            b = data_bytes[i * 3 : (i + 1) * 3]
            val = int.from_bytes(b, byteorder="little", signed=True)
            samples[i] = val / 8388608.0
    else:
        raise ValueError(
            f"Unsupported WAV format: audio_format={audio_format}, bits={bits_per_sample}"
        )

    if channels > 1:
        samples = samples.reshape(-1, channels).mean(axis=1)

    return samples, sample_rate


def encode_wav_bytes(samples: np.ndarray, sample_rate: int = 48000) -> bytes:
    """Encode float32 samples to WAV bytes (32-bit float, mono)."""
    try:
        import soundfile as sf

        buf = io.BytesIO()
        sf.write(buf, samples.astype(np.float32), sample_rate, format="WAV", subtype="FLOAT")
        return buf.getvalue()
    except ImportError:
        pass

    # Fallback: manual WAV encoding (IEEE float32, mono), used only if
    # soundfile is unavailable.
    data = samples.astype(np.float32).tobytes()
    num_channels = 1
    bits_per_sample = 32
    byte_rate = sample_rate * num_channels * (bits_per_sample // 8)
    block_align = num_channels * (bits_per_sample // 8)

    header = struct.pack(
        "<4sI4s4sIHHIIHH4sI",
        b"RIFF",
        36 + len(data),  # file size - 8
        b"WAVE",
        b"fmt ",
        16,  # fmt chunk size
        3,  # audio format: IEEE float
        num_channels,
        sample_rate,
        byte_rate,
        block_align,
        bits_per_sample,
        b"data",
        len(data),  # data chunk size
    )

    return header + data


# ---------------------------------------------------------------------------
# Payload Limits (DoS protection)
# ---------------------------------------------------------------------------
# Max base64 string length (~1.3 MB -> ~1 MB decoded). Covers ~10s mono float32.
MAX_AUDIO_B64_LEN = 1_400_000
# Max WAV bytes after decode. ~10s at 48 kHz mono float32.
MAX_WAV_BYTES = 2_000_000


# ---------------------------------------------------------------------------
# Flask Application
# ---------------------------------------------------------------------------

app = Flask(__name__)
ACE_WRAPPER: ACEStepWrapper = None  # Initialized in main()


@app.route("/health", methods=["GET"])
def health():
    """
    Health check endpoint.

    Returns server status, model availability, and device info. Intended
    for periodic polling by any client to confirm the bridge is reachable
    and to learn whether neural inference is currently active.
    """
    return jsonify(
        {
            "status": "ok",
            "model_loaded": ACE_WRAPPER.is_loaded if ACE_WRAPPER else False,
            "model_type": ACE_WRAPPER.model_type if ACE_WRAPPER else "none",
            "device": ACE_WRAPPER.device if ACE_WRAPPER else "none",
            "error": ACE_WRAPPER.load_error if ACE_WRAPPER else None,
            "inference_count": (ACE_WRAPPER.inference_count if ACE_WRAPPER else 0),
            "timestamp": time.time(),
        }
    )


@app.route("/status", methods=["GET"])
def status():
    """Detailed status endpoint with full server configuration."""
    return jsonify(
        {
            "status": "ok",
            "model_loaded": ACE_WRAPPER.is_loaded if ACE_WRAPPER else False,
            "model_type": ACE_WRAPPER.model_type if ACE_WRAPPER else "none",
            "model_path": ACE_WRAPPER.model_path if ACE_WRAPPER else None,
            "device": ACE_WRAPPER.device if ACE_WRAPPER else "none",
            "error": ACE_WRAPPER.load_error if ACE_WRAPPER else None,
            "inference_count": (ACE_WRAPPER.inference_count if ACE_WRAPPER else 0),
            "sample_rate": 48000,
            "buffer_size": 48000,
            "version": "0.2.0",
        }
    )


@app.route("/shutdown", methods=["POST"])
def shutdown():
    """
    Graceful shutdown endpoint.

    Intended to be called by the host process before it sends SIGTERM, so
    the server can release resources cleanly before exiting.
    """
    logging.info("Shutdown request received - terminating server")

    func = request.environ.get("werkzeug.server.shutdown")
    if func is not None:
        func()
        return jsonify({"status": "shutting_down"}), 200

    # Newer Werkzeug versions do not expose a shutdown hook; fall back to
    # signalling our own process.
    import signal

    os.kill(os.getpid(), signal.SIGTERM)
    return jsonify({"status": "shutting_down"}), 200


@app.route("/infer", methods=["POST"])
def infer():
    """
    Run one inference cycle through ACE-Step 1.5.

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
        "audio_duration": 10.0,
        "denoise_strength": 1.0
    }

    All fields except "audio" are optional and fall back to the defaults
    shown above. Several request fields are expressed in a normalized,
    UI-friendly range and are remapped onto the underlying ACE-Step
    arguments before inference:

        shift (1-10) -> guidance_interval (0.1-0.9):
            structure vs. texture attention allocation
        entropy (0-1) -> omega_scale (1-20):
            stochastic deviation magnitude
        granularity (0-1) -> guidance_interval_decay (0-1):
            spectral granularity / detail resolution
        infer_method "sde" -> retake_variance=0.5:
            stochastic per-step diffusion instead of the deterministic
            "ode" default

    Response JSON:
    {
        "audio": "<base64-encoded WAV>",
        "sample_rate": 48000,
        "num_samples": 4096,
        "duration_ms": 42.3,
        "model_used": true,
        "model_type": "base"
    }

    On error, responds with {"error": "<message>"} and an appropriate
    4xx/5xx status code.
    """
    try:
        data = request.get_json(force=True, silent=True)
        if not isinstance(data, dict):
            return jsonify({"error": "Request body must be valid JSON object"}), 400

        if "audio" not in data:
            return jsonify({"error": 'Missing "audio" field (base64-encoded WAV)'}), 400

        audio_b64 = data["audio"]
        if not isinstance(audio_b64, str) or len(audio_b64) > MAX_AUDIO_B64_LEN:
            return (
                jsonify({"error": f'"audio" exceeds max size ({MAX_AUDIO_B64_LEN} chars)'}),
                413,
            )

        try:
            wav_bytes = base64.b64decode(audio_b64)
        except (ValueError, TypeError) as e:
            return jsonify({"error": f'Invalid base64 in "audio" field: {e}'}), 400

        if len(wav_bytes) > MAX_WAV_BYTES:
            return (
                jsonify({"error": f"Decoded WAV exceeds max size ({MAX_WAV_BYTES} bytes)"}),
                413,
            )

        try:
            samples, sr = decode_wav_bytes(wav_bytes)
        except (ValueError, KeyError) as e:
            return jsonify({"error": f'Invalid WAV in "audio" field: {e}'}), 400

        def safe_float(val, default: float) -> float:
            if val is None:
                return default
            try:
                return float(val)
            except (ValueError, TypeError):
                return default

        def safe_int(val, default: int) -> int:
            if val is None:
                return default
            try:
                return int(val)
            except (ValueError, TypeError):
                return default

        prompt = data.get("prompt") if isinstance(data.get("prompt"), str) else ""
        guidance_scale = safe_float(data.get("guidance_scale"), 15.0)
        num_steps = safe_int(data.get("num_steps"), 20)
        seed = safe_int(data.get("seed"), -1)
        input_strength = safe_float(data.get("input_strength"), 0.6)
        audio_duration = safe_float(data.get("audio_duration"), 10.0)

        shift_raw = safe_float(data.get("shift"), 5.0)
        guidance_interval = max(0.1, min(0.9, 0.1 + (shift_raw - 1.0) / 9.0 * 0.8))

        # entropy (0-1) -> omega_scale (1-20): higher omega means more
        # aggressive guidance deviation, i.e. more variation between runs.
        entropy_raw = safe_float(data.get("entropy"), 0.25)
        omega_scale = max(1.0, min(20.0, 1.0 + entropy_raw * 19.0))

        # granularity (0-1) -> guidance_interval_decay (0-1): controls how
        # quickly CFG fades across diffusion steps; higher decays faster,
        # yielding finer spectral detail.
        granularity_raw = safe_float(data.get("granularity"), 0.45)
        guidance_interval_decay = max(0.0, min(1.0, granularity_raw))

        # infer_method "ode" -> deterministic, reproducible; "sde" injects
        # stochastic per-step noise via retake_variance.
        infer_method = data.get("infer_method", "ode")
        retake_variance = 0.5 if infer_method == "sde" else 0.0

        # Per-step denoise strength (0 = no denoise, 1 = full effect).
        denoise_strength = max(0.0, min(1.0, safe_float(data.get("denoise_strength"), 1.0)))

        # Floor for CFG during decay.
        min_guidance_scale = max(1.0, guidance_scale * 0.2)

        t0 = time.time()

        output_samples = ACE_WRAPPER.infer(
            audio_samples=samples,
            sample_rate=sr,
            prompt=prompt,
            guidance_scale=guidance_scale,
            num_steps=num_steps,
            seed=seed,
            input_strength=input_strength,
            audio_duration=audio_duration,
            denoise_strength=denoise_strength,
            guidance_interval=guidance_interval,
            guidance_interval_decay=guidance_interval_decay,
            omega_scale=omega_scale,
            min_guidance_scale=min_guidance_scale,
            retake_variance=retake_variance,
            scheduler_type="euler",
            cfg_type="apg",
        )

        duration_ms = (time.time() - t0) * 1000.0

        output_wav = encode_wav_bytes(output_samples, sr)
        output_b64 = base64.b64encode(output_wav).decode("ascii")

        return jsonify(
            {
                "audio": output_b64,
                "sample_rate": sr,
                "num_samples": len(output_samples),
                "duration_ms": round(duration_ms, 2),
                "model_used": ACE_WRAPPER.is_loaded,
                "model_type": ACE_WRAPPER.model_type,
            }
        )

    except Exception as e:
        logging.error(f"/infer error: {e}\n{traceback.format_exc()}")
        return jsonify({"error": str(e)}), 500


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def main():
    global ACE_WRAPPER

    parser = argparse.ArgumentParser(description="ACE-Step Bridge Server")
    parser.add_argument("--port", type=int, default=8976, help="HTTP port (default: 8976)")
    parser.add_argument(
        "--host", type=str, default="127.0.0.1", help="Bind host (default: 127.0.0.1)"
    )
    parser.add_argument(
        "--model-path",
        type=str,
        default=None,
        help="Path to ACE-Step model directory or HuggingFace repo ID",
    )
    parser.add_argument("--debug", action="store_true", help="Enable Flask debug mode")
    parser.add_argument(
        "--device",
        type=str,
        default="auto",
        choices=["cpu", "mps", "cuda", "auto"],
        help=(
            'PyTorch device for inference. Defaults to "auto". '
            "ACE-Step v0.1.0+ supports Apple Silicon (MPS) properly."
        ),
    )
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.debug else logging.INFO,
        format="%(asctime)s [%(levelname)s] %(message)s",
    )

    logging.info("=" * 60)
    logging.info("  ACE-Step Bridge Server v0.2.0")
    logging.info(f"  Device: {args.device}")
    logging.info("=" * 60)

    ACE_WRAPPER = ACEStepWrapper(model_path=args.model_path, device=args.device)

    if ACE_WRAPPER.is_loaded:
        logging.info(f"Model ready on {ACE_WRAPPER.device} - full neural inference active")
    else:
        logging.warning("Model NOT loaded - server will run in passthrough mode.")
        if ACE_WRAPPER.load_error:
            logging.warning(f"  Reason: {ACE_WRAPPER.load_error}")
        else:
            logging.warning("  No model path specified. Use --model-path to load a model.")
        logging.info("  Input audio will be returned unmodified; the calling host can apply")
        logging.info("  its own processing chain as a fallback.")

    logging.info("")
    logging.info(f"Starting server on {args.host}:{args.port}")
    logging.info(f"  Health:  http://{args.host}:{args.port}/health")
    logging.info(f"  Infer:   http://{args.host}:{args.port}/infer")
    logging.info(f"  Status:  http://{args.host}:{args.port}/status")
    logging.info("")

    if args.debug:
        app.run(host=args.host, port=args.port, debug=True)
    else:
        # Production: use waitress for thread-safe, multi-request serving.
        # Flask's built-in dev server is single-threaded and not safe for
        # concurrent inference requests.
        try:
            from waitress import serve

            logging.info("Using waitress WSGI server (multi-threaded)")
            # 6 threads covers a few concurrent inference requests plus
            # health-check polling without saturating the queue.
            serve(app, host=args.host, port=args.port, threads=6)
        except ImportError:
            logging.warning(
                "waitress not installed - falling back to Flask dev server. "
                "Install with: pip install waitress"
            )
            app.run(host=args.host, port=args.port, debug=False)


if __name__ == "__main__":
    main()
