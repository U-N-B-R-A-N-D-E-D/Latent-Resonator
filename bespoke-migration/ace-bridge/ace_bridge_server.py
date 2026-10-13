#!/usr/bin/env python3
"""
ACE-Step Bridge Server
=======================

A standalone HTTP bridge around ACE-Step 1.5 inference. Any client that
speaks its JSON/HTTP API can send audio plus generation parameters and get
processed audio back — the server has no dependency on any particular
host application.

Receives an audio chunk plus generation parameters as a JSON request with a
base64-encoded WAV payload, runs inference, and returns the processed audio
the same way.

Endpoints:
  GET  /health     — connection check + model status
  GET  /status     — detailed model and server status
  GET  /progress   — step-level progress of the running request
  POST /infer      — run one inference cycle
  POST /shutdown   — graceful shutdown

The server degrades gracefully:
  - If an ACE-Step model is loaded → full neural inference
  - If no model is loaded          → passthrough (echoes audio back
    unchanged), so a caller can still fall back to its own processing.

Usage:
  python ace_bridge_server.py [--port 8976] [--model-path PATH]
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
import threading
import time
import traceback
from collections import OrderedDict
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
# (e.g. rsub) via a Metal validation abort. This env var lets a caller
# disable MPS entirely as a hard safety valve; it must run before torch is
# imported anywhere else in the process.
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
# Public API
# ---------------------------------------------------------------------------

__all__ = [
    "ACEStepWrapper",
    "encode_wav_bytes",
    "decode_wav_bytes",
    "main",
]

# ---------------------------------------------------------------------------
# Progress tracking and timing
# ---------------------------------------------------------------------------

# Set ACE_BRIDGE_TIMING=1 to log per-phase timings for every /infer call.
TIMING_LOG = os.environ.get("ACE_BRIDGE_TIMING") == "1"

# Number of prompt embeddings kept in the text-encoder cache.
TEXT_CACHE_SIZE = 32

# Run a full garbage collection every N inferences instead of every call.
GC_EVERY_N_CALLS = 10


class ProgressTracker:
    """Thread-safe progress state for the request currently being served."""

    def __init__(self):
        self._lock = threading.Lock()
        self._state = "idle"
        self._phase = "idle"
        self._step = 0
        self._total = 0
        self._t0 = 0.0
        self._step_t0 = 0.0
        self._first_step_done_at = 0.0

    @property
    def phase(self) -> str:
        return self._phase

    def begin(self, total_steps: int):
        with self._lock:
            self._state = "busy"
            self._phase = "starting"
            self._step = 0
            self._total = max(0, int(total_steps))
            self._t0 = time.perf_counter()
            self._first_step_done_at = 0.0

    def set_phase(self, phase: str):
        with self._lock:
            if self._state == "busy":
                self._phase = phase

    def set_total(self, total_steps: int):
        with self._lock:
            self._total = max(0, int(total_steps))

    def set_step(self, step: int):
        with self._lock:
            self._step = int(step)
            if step >= 1 and not self._first_step_done_at:
                self._first_step_done_at = time.perf_counter()

    def end(self):
        with self._lock:
            self._state = "idle"
            self._phase = "idle"
            self._step = 0
            self._total = 0

    def snapshot(self) -> dict:
        with self._lock:
            busy = self._state == "busy"
            elapsed = time.perf_counter() - self._t0 if busy else 0.0
            eta = None
            if busy and self._phase == "diffusion" and 1 < self._step < self._total:
                per_step = (time.perf_counter() - self._first_step_done_at) / (self._step - 1)
                eta = round(per_step * (self._total - self._step), 2)
            return {
                "state": self._state,
                "phase": self._phase,
                "step": self._step,
                "total_steps": self._total,
                "elapsed_s": round(elapsed, 3),
                "eta_s": eta,
            }


PROGRESS = ProgressTracker()


def _device_sync(device: str):
    """Block until queued device work finishes so phase timings are accurate."""
    try:
        import torch

        if device.startswith("mps"):
            torch.mps.synchronize()
        elif device.startswith("cuda"):
            torch.cuda.synchronize()
    except Exception:
        pass


# ---------------------------------------------------------------------------
# ACE-Step Model Wrapper
# ---------------------------------------------------------------------------


class ACEStepWrapper:
    """
    Wraps ACE-Step 1.5 for single-chunk inference.

    When a model is loaded, audio is processed through the full ACE-Step
    pipeline (LLM + Diffusion Transformer). When no model is loaded, the
    wrapper operates in passthrough mode, returning the input audio
    unmodified so a caller can fall back to its own processing chain.

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

    def __init__(self, model_path: str = None, device: str = "cpu", dtype: str = "auto"):
        self.model = None
        self.dtype_request = dtype
        # The pipeline is not re-entrant: serialise inference calls.
        self._infer_lock = threading.Lock()
        self._timings: dict = {}
        self.last_timings: dict = {}
        self.model_path = model_path
        self.is_loaded = False
        self.device = device  # Explicit device override
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
            # A caller can set LATENT_RESONATOR_FORCE_CPU=1 to force CPU.
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
                # Try the acestep package (GitHub: ace-step/ACE-Step)
                from acestep.pipeline_ace_step import ACEStepPipeline

                logging.info(f"Loading ACE-Step model from: {model_path}")

                # ACEStepPipeline auto-detects MPS / CUDA / CPU in __init__.
                # We override the device AFTER loading to ensure CPU safety.
                # The pipeline reads its dtype from this variable; on MPS it
                # otherwise forces float32.
                # "auto" picks float16 on MPS (measured: correlation 0.88 with
                # float32 for the same seed; bfloat16 diverges) and leaves the
                # ACE-Step default elsewhere. An existing ACE_PIPELINE_DTYPE wins.
                requested = self.dtype_request
                explicit = requested not in (None, "", "auto")
                if not explicit:
                    requested = "float16" if target_device == "mps" else None
                if requested and (explicit or not os.environ.get("ACE_PIPELINE_DTYPE")):
                    os.environ["ACE_PIPELINE_DTYPE"] = requested
                self.model = ACEStepPipeline(checkpoint_dir=model_path)
                self.model.load_checkpoint(model_path)

                # Force the pipeline to the requested device
                if hasattr(self.model, "device"):
                    auto_device = str(self.model.device)
                    if auto_device != target_device:
                        logging.info(
                            f"Overriding pipeline device: " f"{auto_device} → {target_device}"
                        )
                        if hasattr(self.model, "to"):
                            self.model.to(target_device)
                        # Also move internal sub-models if present
                        for attr in ("unet", "vae", "text_encoder", "model"):
                            sub = getattr(self.model, attr, None)
                            if sub is not None and hasattr(sub, "to"):
                                sub.to(target_device)

                self.device = target_device
                logging.info(f"Using device: {self.device}")

                # Ensure new tensors (e.g. scheduler) are created on CPU when in CPU mode
                if target_device == "cpu":
                    try:
                        torch.set_default_device("cpu")
                    except AttributeError:
                        pass

                self._instrument_pipeline()
                self.is_loaded = True
                self.load_error = None
                logging.info(
                    f"ACE-Step model loaded successfully on {self.device} "
                    f"(type: {self.model_type}, dtype: {getattr(self.model, 'dtype', '?')})"
                )

            except ImportError as import_err:
                # Detailed import error logging for debugging
                logging.error(
                    f"[IMPORT ERROR] Failed to import acestep.pipeline_ace_step: {import_err}"
                )
                logging.error(f"[IMPORT ERROR] Python path: {sys.path}")
                try:
                    import acestep

                    logging.info(f"[IMPORT DEBUG] acestep package found at: {acestep.__file__}")
                    logging.info(f"[IMPORT DEBUG] acestep contents: {dir(acestep)}")
                except ImportError as acestep_err:
                    logging.error(f"[IMPORT ERROR] Cannot import acestep at all: {acestep_err}")
                # Try alternative import paths
                try:
                    import ace_step

                    logging.info(
                        f"[IMPORT DEBUG] ace_step (with underscore) found at: {ace_step.__file__}"
                    )
                except ImportError:
                    logging.error("[IMPORT ERROR] ace_step (with underscore) not found")
                # Fall through to alternative loader below

            except ImportError:
                # Try alternative import paths
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

    # ------------------------------------------------------------------
    # Pipeline instrumentation (wrapper-side; ACE-Step source is untouched)
    # ------------------------------------------------------------------

    def _add_timing(self, label: str, seconds: float):
        self._timings[label] = self._timings.get(label, 0.0) + seconds

    def _wrap_phase(self, obj, name: str, label: str, phase: str = None):
        """Time a pipeline method and (optionally) publish the current phase."""
        orig = getattr(obj, name, None)
        if orig is None:
            return

        def wrapped(*args, **kwargs):
            if phase:
                PROGRESS.set_phase(phase)
            t = time.perf_counter()
            try:
                return orig(*args, **kwargs)
            finally:
                _device_sync(self.device)
                self._add_timing(label, time.perf_counter() - t)

        setattr(obj, name, wrapped)

    def _wrap_text_cache(self, name: str):
        """Cache text-encoder outputs keyed by (texts, args)."""
        orig = getattr(self.model, name, None)
        if orig is None:
            return
        cache: OrderedDict = OrderedDict()

        def cached(texts, *args, **kwargs):
            key = (tuple(texts), args, tuple(sorted(kwargs.items())))
            hit = cache.get(key)
            if hit is not None:
                cache.move_to_end(key)
                self._add_timing("text_cache_hits", 1)
                return hit
            value = orig(texts, *args, **kwargs)
            cache[key] = value
            while len(cache) > TEXT_CACHE_SIZE:
                cache.popitem(last=False)
            return value

        setattr(self.model, name, cached)

    def _instrument_pipeline(self):
        """
        Attach timing, progress and caching around ACEStepPipeline methods.

        Everything is done on the instance (and the tqdm name of the pipeline
        module), so the ACE-Step package itself is never modified.
        """
        model = self.model
        self._wrap_text_cache("get_text_embeddings")
        self._wrap_text_cache("get_text_embeddings_null")
        self._wrap_phase(model, "get_text_embeddings", "text_encode", "text_encode")
        self._wrap_phase(model, "get_text_embeddings_null", "text_encode", "text_encode")
        self._wrap_phase(model, "infer_latents", "vae_encode", "vae_encode")
        self._wrap_phase(model, "text2music_diffusion_process", "diffusion", "diffusion")
        self._wrap_phase(model, "flowedit_diffusion_process", "diffusion", "diffusion")
        self._wrap_phase(model, "latents2audio", "vae_decode", "vae_decode")
        transformer = getattr(model, "ace_step_transformer", None)
        if transformer is not None:
            self._wrap_phase(transformer, "encode", "cond_encode")

        # The pipeline runs gc.collect() after every call (0.5-1 s with the
        # model resident). Do it every GC_EVERY_N_CALLS calls instead.
        def cleanup_memory():
            if self.inference_count % GC_EVERY_N_CALLS == 0:
                import gc

                gc.collect()

        model.cleanup_memory = cleanup_memory

        # Step-level progress: the diffusion loops iterate through
        # tqdm(enumerate(timesteps), total=N). Replace the pipeline module's
        # tqdm with a generator that reports the step counter.
        try:
            import acestep.pipeline_ace_step as pipeline_module

            original_tqdm = pipeline_module.tqdm

            def tracking_tqdm(iterable=None, *args, **kwargs):
                total = kwargs.get("total")
                if PROGRESS.phase == "diffusion" and total:
                    PROGRESS.set_total(total)

                    def gen():
                        for i, item in enumerate(iterable):
                            PROGRESS.set_step(i)
                            yield item
                        PROGRESS.set_step(total)

                    return gen()
                return original_tqdm(iterable, *args, **kwargs)

            pipeline_module.tqdm = tracking_tqdm
        except Exception as e:
            logging.warning(f"Progress hook unavailable, using step estimates only: {e}")

    def warmup(self, duration_s: float = 3.0, sample_rate: int = 48000, steps: int = 6):
        """
        Run one short throw-away inference so kernel compilation and memory
        allocation happen at startup instead of on the first real request.
        With input_strength=0.5 the audio2audio path runs steps // 2 diffusion
        steps, so the default exercises the guided transformer forward pass.
        """
        if not self.is_loaded:
            return
        t = time.perf_counter()
        n = int(duration_s * sample_rate)
        tone = (0.2 * np.sin(2 * np.pi * 220.0 * np.arange(n) / sample_rate)).astype(np.float32)
        self.infer_with_timings(
            tone,
            sample_rate=sample_rate,
            prompt="warmup",
            num_steps=steps,
            input_strength=0.5,
            audio_duration=duration_s,
            seed=0,
        )
        self.inference_count = 0
        logging.info(f"Warm-up finished in {time.perf_counter() - t:.1f}s")

    def infer(self, audio_samples: np.ndarray, *args, **kwargs) -> np.ndarray:
        """Run one inference cycle; see infer_with_timings for parameters."""
        return self.infer_with_timings(audio_samples, *args, **kwargs)[0]

    def infer_with_timings(
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
        # --- Parameters mapped onto the underlying ACE-Step call ---
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
        # --- LM-bypass switch + task routing ---
        # `thinking`: when False, bypass the LM planner by disabling all
        # three ERG guidance channels — the prompt reaches the diffusion
        # transformer unmediated instead of being routed through it.
        # `task_type`: a small vocabulary mapped onto ACE-Step's `task` param.
        #   "cover"    → audio2audio (default; ref_audio feedback loop)
        #   "repaint"  → repaint (src_audio + repaint_start/end window)
        #   "extend"   → extend (continues past src_audio end)
        #   "edit"     → edit (edit_target_prompt rewrites a segment)
        #   "lego"/"extract"/"complete" → reserved (log + fall back to cover)
        thinking: bool = True,
        task_type: str = "cover",
    ) -> np.ndarray:
        """
        Run one inference cycle through ACE-Step 1.5.

        Applies one step of the recursive feedback pattern this bridge is
        built around: the output of a previous call can be fed back in as
        the next call's input audio, with prompt and guidance parameters
        steering each iteration (S_next = ACE(S_prev + noise, prompt, cfg)).

        Parameters:
            audio_samples: Input audio as float32 numpy array (mono)
            sample_rate: Audio sample rate (Hz)
            prompt: Semantic prompt text P
            guidance_scale: CFG scale γ (typical range 15.0-18.0)
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
            thinking: When False, all three ERG channels are disabled so the
                prompt reaches the diffusion transformer unmediated by the LM
                planner. Overrides the per-channel flags above.
            task_type: A small vocabulary mapped onto ACE-Step's `task` param.
                "cover" (default) runs audio2audio with ref_audio feedback.
                "repaint" / "extend" / "edit" route to the matching ACE-Step
                task using the input audio as `src_audio`. Other values are
                reserved and fall back to "cover" with a warning.

        Returns:
            Tuple of (processed float32 audio, per-phase timings in seconds).
            The timings dict is empty on passthrough.
        """
        if not self.is_loaded or self.model is None:
            # Passthrough when model not loaded
            return audio_samples, {}

        # thinking=False bypasses the LM planner by disabling all ERG
        # guidance channels; the prompt is injected directly into the
        # diffusion transformer instead.
        if not thinking:
            use_erg_tag = False
            use_erg_lyric = False
            use_erg_diffusion = False

        # task_type vocabulary → ACE-Step task param.
        # "cover" keeps audio2audio (the feedback-loop pattern); repaint/
        # extend/edit route to their native ACE-Step paths using the input
        # audio as src_audio.
        _TASK_MAP = {
            "cover": None,  # audio2audio auto-set below
            "repaint": "repaint",
            "extend": "extend",
            "edit": "edit",
        }
        resolved_task = _TASK_MAP.get(task_type)
        if resolved_task is None and task_type != "cover":
            logging.warning(
                f"task_type='{task_type}' is reserved (no ACE-Step mapping yet); "
                "falling back to 'cover' (audio2audio)."
            )
        use_repaint_path = resolved_task in ("repaint", "extend", "edit")

        # Per-step denoise strength: 0 = passthrough; (0,1] = run that fraction of steps.
        # Mapping: effective_steps = max(1, round(num_steps * denoise_strength)).
        denoise_strength = max(0.0, min(1.0, denoise_strength))
        if denoise_strength <= 0.0:
            return audio_samples, {}
        effective_steps = max(1, int(round(num_steps * denoise_strength)))

        with self._infer_lock:
            return self._run_pipeline(
                audio_samples=audio_samples,
                sample_rate=sample_rate,
                prompt=prompt,
                guidance_scale=guidance_scale,
                effective_steps=effective_steps,
                seed=seed,
                input_strength=input_strength,
                audio_duration=audio_duration,
                denoise_strength=denoise_strength,
                guidance_interval=guidance_interval,
                guidance_interval_decay=guidance_interval_decay,
                omega_scale=omega_scale,
                min_guidance_scale=min_guidance_scale,
                retake_variance=retake_variance,
                scheduler_type=scheduler_type,
                cfg_type=cfg_type,
                use_erg_tag=use_erg_tag,
                use_erg_lyric=use_erg_lyric,
                use_erg_diffusion=use_erg_diffusion,
                thinking=thinking,
                task_type=task_type,
                resolved_task=resolved_task,
                use_repaint_path=use_repaint_path,
            )

    def _run_pipeline(
        self,
        audio_samples,
        sample_rate,
        prompt,
        guidance_scale,
        effective_steps,
        seed,
        input_strength,
        audio_duration,
        denoise_strength,
        guidance_interval,
        guidance_interval_decay,
        omega_scale,
        min_guidance_scale,
        retake_variance,
        scheduler_type,
        cfg_type,
        use_erg_tag,
        use_erg_lyric,
        use_erg_diffusion,
        thinking,
        task_type,
        resolved_task,
        use_repaint_path,
    ):
        """Execute one pipeline call while holding the inference lock."""
        self._timings = {}
        t_total = time.perf_counter()
        # audio2audio noises the reference and runs only (1 - strength) of the steps.
        estimated_steps = (
            effective_steps
            if use_repaint_path
            else max(1, int(effective_steps * (1.0 - input_strength)))
        )
        PROGRESS.begin(estimated_steps)
        try:
            import soundfile as sf

            if seed < 0:
                seed = int(time.time() * 1000) % (2**32)

            with tempfile.TemporaryDirectory() as tmp_dir:
                tmp_input = os.path.join(tmp_dir, "input.wav")
                t = time.perf_counter()
                sf.write(tmp_input, audio_samples, sample_rate)
                self._add_timing("input_write", time.perf_counter() - t)

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
                    retake_variance=retake_variance,
                    save_path=tmp_dir,
                    batch_size=1,
                )

                if use_repaint_path:
                    # repaint/extend/edit use src_audio_path + task; they do NOT
                    # set audio2audio_enable (which would override task="audio2audio").
                    infer_kwargs["task"] = resolved_task
                    infer_kwargs["src_audio_path"] = tmp_input
                    if resolved_task == "repaint":
                        infer_kwargs["repaint_start"] = 0
                        infer_kwargs["repaint_end"] = int(audio_duration)
                else:
                    # "cover" — the feedback-loop pattern. audio2audio_enable +
                    # ref_audio auto-set task="audio2audio" inside
                    # ACEStepPipeline.__call__.
                    infer_kwargs["audio2audio_enable"] = True
                    infer_kwargs["ref_audio_strength"] = input_strength
                    infer_kwargs["ref_audio_input"] = tmp_input

                logging.info(
                    f"Inference: task='{task_type}'→{resolved_task or 'audio2audio'}, "
                    f"thinking={thinking}, steps={effective_steps} (denoise={denoise_strength:.2f}), "
                    f"cfg={guidance_scale}, strength={input_strength}, omega={omega_scale}, "
                    f"interval={guidance_interval}, decay={guidance_interval_decay}, "
                    f"retake_var={retake_variance}, seed={seed}"
                )

                t_pipeline = time.perf_counter()
                result = self.model(**infer_kwargs)
                pipeline_s = time.perf_counter() - t_pipeline

                t = time.perf_counter()
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
                    self._add_timing("output_read", time.perf_counter() - t)
                    self.inference_count += 1
                    timings = self._finish_timings(t_total, pipeline_s)
                    return audio_out.astype(np.float32), timings
                else:
                    logging.warning("No output WAV found in pipeline result")
                    return audio_samples, {}

        except Exception as e:
            logging.error(f"Inference error: {e}\n{traceback.format_exc()}")
            return audio_samples, {}  # Passthrough on error
        finally:
            PROGRESS.end()

    def _finish_timings(self, t_total: float, pipeline_s: float) -> dict:
        """Derive the reported phase breakdown from the raw accumulators."""
        raw = self._timings
        cond = raw.get("cond_encode", 0.0)
        diffusion = raw.get("diffusion", 0.0)
        phases = {
            "input_write": raw.get("input_write", 0.0),
            "text_encode": raw.get("text_encode", 0.0),
            "vae_encode": raw.get("vae_encode", 0.0),
            "cond_encode": cond,
            "diffusion_loop": max(0.0, diffusion - cond),
            "vae_decode": raw.get("vae_decode", 0.0),
            "output_read": raw.get("output_read", 0.0),
        }
        accounted = sum(phases.values()) - phases["input_write"] - phases["output_read"]
        phases["other"] = max(0.0, pipeline_s - accounted)
        phases["total"] = time.perf_counter() - t_total
        phases = {k: round(v, 3) for k, v in phases.items()}
        if TIMING_LOG:
            logging.info(
                "Timings: "
                + ", ".join(f"{k}={v:.2f}s" for k, v in phases.items())
                + f", text_cache_hits={int(raw.get('text_cache_hits', 0))}"
            )
        self.last_timings = phases
        return phases


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

        data, sr = sf.read(io.BytesIO(wav_bytes), dtype="float32")
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
    if riff != b"RIFF" or wave != b"WAVE":
        raise ValueError("Not a valid WAV file")

    # Parse chunks
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

    # Decode sample data
    if audio_format == 3 and bits_per_sample == 32:
        # IEEE Float 32-bit
        samples = np.frombuffer(data_bytes, dtype=np.float32).copy()
    elif audio_format == 1 and bits_per_sample == 16:
        # PCM 16-bit
        samples = np.frombuffer(data_bytes, dtype=np.int16).astype(np.float32) / 32768.0
    elif audio_format == 1 and bits_per_sample == 24:
        # PCM 24-bit
        n_samples = len(data_bytes) // 3
        samples = np.zeros(n_samples, dtype=np.float32)
        for i in range(n_samples):
            b = data_bytes[i * 3 : (i + 1) * 3]
            val = int.from_bytes(b, byteorder="little", signed=True)
            samples[i] = val / 8388608.0
    else:
        raise ValueError(
            f"Unsupported WAV format: audio_format={audio_format}, " f"bits={bits_per_sample}"
        )

    # Mix to mono if multichannel
    if channels > 1:
        samples = samples.reshape(-1, channels).mean(axis=1)

    return samples, sample_rate


def encode_wav_bytes(samples: np.ndarray, sample_rate: int = 48000) -> bytes:
    """Encode float32 samples to WAV bytes (32-bit float, mono)."""
    # Try soundfile first
    try:
        import soundfile as sf

        buf = io.BytesIO()
        sf.write(buf, samples.astype(np.float32), sample_rate, format="WAV", subtype="FLOAT")
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
# Max WAV bytes after decode. 12 MB covers 30 s of 48 kHz stereo float32
# (11.52 MB) or 60 s mono; 3 s of stereo is only ~1.15 MB.
MAX_WAV_BYTES = 12_000_000
# Max base64 string length: ceil(MAX_WAV_BYTES / 3) * 4 plus slack.
MAX_AUDIO_B64_LEN = 16_100_000


# ---------------------------------------------------------------------------
# Flask Application
# ---------------------------------------------------------------------------

app = Flask(__name__)
ACE_WRAPPER: ACEStepWrapper = None  # Initialized in main()
LOW_LATENCY_MODE: bool = False  # Set in main() from --low-latency or --performance-mode flag
PERF_CONFIG: dict = {}  # Performance config: max_steps, quantization


@app.route("/health", methods=["GET"])
def health():
    """
    Health check endpoint.
    Returns server status, model availability, and device info.

    Intended for periodic polling by a client to confirm the server is
    reachable and to check whether neural inference is currently active.
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
            "dtype": str(getattr(ACE_WRAPPER.model, "dtype", "unknown")) if ACE_WRAPPER else "none",
            "max_wav_bytes": MAX_WAV_BYTES,
            "progress": PROGRESS.snapshot(),
            "sample_rate": 48000,
            "buffer_size": 48000,
            "version": "0.2.0",
        }
    )


@app.route("/progress", methods=["GET"])
def progress():
    """
    Progress of the request currently being served.

    Returns {state: idle|busy, phase, step, total_steps, elapsed_s, eta_s}.
    `step` counts completed diffusion steps; `total_steps` is an estimate until
    the pipeline reports the real count. `eta_s` is null until it can be
    extrapolated from at least two completed steps.
    """
    return jsonify(PROGRESS.snapshot())


@app.route("/shutdown", methods=["POST"])
def shutdown():
    """
    Graceful shutdown endpoint.

    Lets a caller ask the server to close resources cleanly before it is
    terminated, as an alternative to sending SIGTERM directly.
    """
    logging.info("Shutdown request received — terminating server")

    # Flask / Werkzeug shutdown
    func = request.environ.get("werkzeug.server.shutdown")
    if func is not None:
        func()
        return jsonify({"status": "shutting_down"}), 200

    # Fallback for newer Werkzeug versions: schedule exit
    import os
    import signal

    os.kill(os.getpid(), signal.SIGTERM)
    return jsonify({"status": "shutting_down"}), 200


@app.route("/infer", methods=["POST"])
def infer():
    """
    Run one inference cycle through ACE-Step 1.5.

    Every parameter accepted by this endpoint is wired through to the
    underlying ACE-Step pipeline call.

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

    Normalized request parameter → ACE-Step parameter mapping:
        shift (1-10) → guidance_interval (0.1-0.9):
            structure↔texture attention allocation
        entropy (0-1) → omega_scale (1-20):
            stochastic deviation magnitude
        granularity (0-1) → guidance_interval_decay (0-1):
            spectral granularity / detail resolution
        infer_method "sde" → retake_variance=0.5:
            stochastic diffusion, for recursive drift across iterations

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

        # Low-latency mode: cap inference steps for real-time performance.
        # Honors an explicit --max-steps if the server was launched with
        # one, otherwise falls back to a conservative default of 6.
        if LOW_LATENCY_MODE:
            step_cap = PERF_CONFIG.get("max_steps") or 6
            num_steps = min(num_steps, step_cap)
            logging.info(f"Low-latency mode: capped steps to {num_steps}")

        shift_raw = safe_float(data.get("shift"), 5.0)
        guidance_interval = max(0.1, min(0.9, 0.1 + (shift_raw - 1.0) / 9.0 * 0.8))

        # ENTROPY (0.0–1.0 normalized) → omega_scale (1.0–20.0)
        # Higher omega = more aggressive guidance deviation = more sonic
        # variation between iterations.
        entropy_raw = safe_float(data.get("entropy"), 0.25)
        omega_scale = max(1.0, min(20.0, 1.0 + entropy_raw * 19.0))

        # GRANULARITY (0.0–1.0 normalized) → guidance_interval_decay (0.0–1.0)
        # Controls how quickly CFG fades during diffusion steps.
        # High granularity = rapid CFG decay = finer spectral detail.
        granularity_raw = safe_float(data.get("granularity"), 0.45)
        guidance_interval_decay = max(0.0, min(1.0, granularity_raw))

        # METHOD: ODE vs SDE
        # ODE ("ode") → retake_variance=0.0: deterministic, reproducible.
        # SDE ("sde") → retake_variance=0.5: stochastic per-step noise,
        # injecting entropy at each diffusion step.
        infer_method = data.get("infer_method", "ode")
        retake_variance = 0.5 if infer_method == "sde" else 0.0

        # Per-step denoise strength (0 = no denoise, 1 = full). A caller can
        # skip calling this endpoint entirely when it would be 0.
        denoise_strength = max(0.0, min(1.0, safe_float(data.get("denoise_strength"), 1.0)))

        # thinking=False bypasses the LM planner (see ACEStepWrapper.infer).
        # Defaults to True to preserve ACE-Step's native behavior unless a
        # caller explicitly requests the bypass.
        thinking = data.get("thinking", True)
        if not isinstance(thinking, bool):
            thinking = safe_int(thinking, 1) != 0

        # task_type vocabulary → ACE-Step task routing (see ACEStepWrapper.infer).
        task_type = data.get("task_type") if isinstance(data.get("task_type"), str) else "cover"

        # Min guidance scale — floor during CFG decay
        min_guidance_scale = max(1.0, guidance_scale * 0.2)

        t0 = time.time()

        # Run inference — ALL parameters wired through
        output_samples, timings = ACE_WRAPPER.infer_with_timings(
            audio_samples=samples,
            sample_rate=sr,
            prompt=prompt,
            guidance_scale=guidance_scale,
            num_steps=num_steps,
            seed=seed,
            input_strength=input_strength,
            audio_duration=audio_duration,
            denoise_strength=denoise_strength,
            # Normalized-parameter mappings computed above
            guidance_interval=guidance_interval,
            guidance_interval_decay=guidance_interval_decay,
            omega_scale=omega_scale,
            min_guidance_scale=min_guidance_scale,
            retake_variance=retake_variance,
            scheduler_type="euler",
            cfg_type="apg",
            thinking=thinking,
            task_type=task_type,
        )

        duration_ms = (time.time() - t0) * 1000.0

        # Encode output audio to WAV
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
                "timings": timings,
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
    parser.add_argument(
        "--low-latency",
        action="store_true",
        help="Performance mode: reduce inference steps to 4-6 for live performance (legacy)",
    )
    parser.add_argument(
        "--performance-mode",
        action="store_true",
        help="Enable performance mode (reduced steps, quantization) for live performance",
    )
    parser.add_argument(
        "--max-steps",
        type=int,
        default=None,
        help="Maximum inference steps (performance mode: 4-8, studio: 20)",
    )
    parser.add_argument(
        "--dtype",
        type=str,
        default="auto",
        choices=["auto", "float32", "float16", "bfloat16"],
        help=(
            "Model dtype. auto = float16 on MPS, ACE-Step default elsewhere. "
            "Use float32 for the previous MPS behaviour."
        ),
    )
    parser.add_argument(
        "--warmup",
        action="store_true",
        help="Run one short inference after loading so the first request is not cold",
    )
    parser.add_argument(
        "--quantization",
        type=str,
        default=None,
        choices=["q8", "fp16", "fp32"],
        help="Quantization mode: q8 (fast), fp16 (balanced), fp32 (quality)",
    )
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.debug else logging.INFO,
        format="%(asctime)s [%(levelname)s] %(message)s",
    )

    logging.info("=" * 60)
    logging.info("  ACE-Step Bridge Server v0.2.0")
    logging.info(f"  Device: {args.device}")

    # Performance mode: legacy --low-latency or new --performance-mode
    is_performance_mode = args.low_latency or args.performance_mode

    if is_performance_mode:
        perf_info = []
        if args.max_steps:
            perf_info.append(f"{args.max_steps} steps")
        if args.quantization:
            perf_info.append(f"quant={args.quantization}")
        if not perf_info:
            perf_info.append("4-6 steps")
        logging.info(f"  Mode: PERFORMANCE ({', '.join(perf_info)})")
    logging.info("=" * 60)

    # Store performance mode flag in global
    global LOW_LATENCY_MODE
    LOW_LATENCY_MODE = is_performance_mode

    # Store performance configuration
    global PERF_CONFIG
    PERF_CONFIG = {"max_steps": args.max_steps, "quantization": args.quantization}

    # Initialize model wrapper with explicit device
    ACE_WRAPPER = ACEStepWrapper(model_path=args.model_path, device=args.device, dtype=args.dtype)
    if args.warmup and ACE_WRAPPER.is_loaded:
        ACE_WRAPPER.warmup()

    if ACE_WRAPPER.is_loaded:
        logging.info(f"✓ Model ready on {ACE_WRAPPER.device} — " f"full neural inference active")
    else:
        logging.warning("✗ Model NOT loaded — server will run in passthrough mode.")
        if ACE_WRAPPER.load_error:
            logging.warning(f"  Reason: {ACE_WRAPPER.load_error}")
        else:
            logging.warning("  No model path specified. " "Use --model-path to load a model.")
        logging.info(
            "  Callers will receive passthrough audio from /infer until a model is loaded."
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
            # 6 threads: 2+ lanes × inference + health checks; reduces "Task queue depth" warnings
            serve(app, host=args.host, port=args.port, threads=6)
        except ImportError:
            logging.warning(
                "waitress not installed — falling back to Flask dev server. "
                "Install with: pip install waitress"
            )
            app.run(host=args.host, port=args.port, debug=False)


if __name__ == "__main__":
    main()
