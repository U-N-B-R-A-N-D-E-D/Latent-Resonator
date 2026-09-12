#!/usr/bin/env python3
"""
Unit tests for ACE-Step Bridge Server helpers and Flask endpoints.

WAV codec tests need only numpy. Flask endpoint tests use the test client
and do NOT require GPU/model. Real /infer with a loaded model is opt-in:
set ACE_BRIDGE_LIVE_INFER=1 (and optionally ACE_BRIDGE_MODEL_PATH) to run
a short live inference against a running server, or the in-process wrapper
when ACE_BRIDGE_MODEL_PATH points at a valid checkpoint.

Run:
    pytest test_bridge.py -v
"""

import base64
import os
import sys

import numpy as np
import pytest

# Import the bridge module from the same directory
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ace_bridge_server as bridge
from ace_bridge_server import encode_wav_bytes, decode_wav_bytes

__all__ = [
    "TestWAVCodecRoundTrip",
    "TestWAVCodecInvalid",
    "TestWAVCodecHeader",
    "TestFlaskEndpointsNoModel",
    "TestLiveInfer",
]


# ---------------------------------------------------------------------------
# WAV codec (no Flask / no model)
# ---------------------------------------------------------------------------


class TestWAVCodecRoundTrip:
    """WAV encode → decode round-trip integrity."""

    def test_basic_roundtrip(self):
        samples = np.array([0.0, 0.25, 0.5, 0.75, 1.0, -0.5, -1.0], dtype=np.float32)
        encoded = encode_wav_bytes(samples, sample_rate=48000)
        decoded, sr = decode_wav_bytes(encoded)

        assert sr == 48000
        assert len(decoded) == len(samples)
        np.testing.assert_allclose(decoded, samples, atol=1e-6)

    def test_silent_signal(self):
        samples = np.zeros(100, dtype=np.float32)
        encoded = encode_wav_bytes(samples)
        decoded, sr = decode_wav_bytes(encoded)

        assert len(decoded) == 100
        np.testing.assert_allclose(decoded, samples, atol=1e-7)

    def test_single_sample(self):
        samples = np.array([0.42], dtype=np.float32)
        encoded = encode_wav_bytes(samples)
        decoded, sr = decode_wav_bytes(encoded)

        assert len(decoded) == 1
        np.testing.assert_allclose(decoded, samples, atol=1e-6)

    def test_large_buffer(self):
        """48000 samples = 1 second at 48kHz."""
        t = np.arange(48000, dtype=np.float32) / 48000.0
        samples = np.sin(2.0 * np.pi * 440.0 * t).astype(np.float32)

        encoded = encode_wav_bytes(samples, sample_rate=48000)
        decoded, sr = decode_wav_bytes(encoded)

        assert sr == 48000
        assert len(decoded) == 48000
        np.testing.assert_allclose(decoded, samples, atol=1e-5)

    def test_negative_values(self):
        samples = np.array([-1.0, -0.5, -0.25, -0.1], dtype=np.float32)
        encoded = encode_wav_bytes(samples)
        decoded, _ = decode_wav_bytes(encoded)

        np.testing.assert_allclose(decoded, samples, atol=1e-6)


class TestWAVCodecInvalid:
    """Invalid input handling."""

    def test_too_short_raises(self):
        with pytest.raises((ValueError, Exception)):
            decode_wav_bytes(b"short")

    def test_not_riff_raises(self):
        with pytest.raises((ValueError, Exception)):
            decode_wav_bytes(b"NOT_RIFF" + b"\x00" * 40)


class TestWAVCodecHeader:
    """Validate WAV header structure."""

    def test_riff_header(self):
        samples = np.array([0.1, 0.2, 0.3], dtype=np.float32)
        encoded = encode_wav_bytes(samples)

        assert encoded[:4] == b"RIFF"
        assert encoded[8:12] == b"WAVE"

    def test_data_size_correct(self):
        n = 100
        samples = np.zeros(n, dtype=np.float32)
        encoded = encode_wav_bytes(samples)

        # WAV payload must contain at least 44-byte header + n*4 data bytes.
        # Some backends (soundfile) add extra chunks (fact, PEAK), so the
        # file may be larger than the bare minimum.
        min_size = 44 + n * 4
        assert len(encoded) >= min_size


# ---------------------------------------------------------------------------
# Flask endpoints without GPU/model
# ---------------------------------------------------------------------------


@pytest.fixture
def flask_client_passthrough():
    """
    Flask test client with an unloaded ACEStepWrapper (passthrough mode).
    Does not load torch models or touch GPU.
    """
    previous = bridge.ACE_WRAPPER
    bridge.ACE_WRAPPER = bridge.ACEStepWrapper(model_path=None, device="cpu")
    bridge.LOW_LATENCY_MODE = False
    try:
        bridge.app.config["TESTING"] = True
        with bridge.app.test_client() as client:
            yield client
    finally:
        bridge.ACE_WRAPPER = previous


def _sine_wav_b64(duration_s: float = 0.25, sr: int = 48000, freq: float = 220.0) -> str:
    n = int(sr * duration_s)
    t = np.arange(n, dtype=np.float32) / float(sr)
    samples = (0.4 * np.sin(2.0 * np.pi * freq * t)).astype(np.float32)
    return base64.b64encode(encode_wav_bytes(samples, sample_rate=sr)).decode("ascii")


class TestFlaskEndpointsNoModel:
    """
    /health, /status, /infer (passthrough), and /shutdown shape checks.
    No model required — must never fake a model_loaded=true pass.
    """

    def test_health_ok_model_not_loaded(self, flask_client_passthrough):
        r = flask_client_passthrough.get("/health")
        assert r.status_code == 200
        body = r.get_json()
        assert body["status"] == "ok"
        assert body["model_loaded"] is False
        assert "device" in body
        assert "inference_count" in body
        assert "timestamp" in body

    def test_status_ok_includes_paths(self, flask_client_passthrough):
        r = flask_client_passthrough.get("/status")
        assert r.status_code == 200
        body = r.get_json()
        assert body["status"] == "ok"
        assert body["model_loaded"] is False
        assert body["sample_rate"] == 48000
        assert body["version"] == "0.2.0"
        assert "model_path" in body

    def test_infer_passthrough_echoes_audio(self, flask_client_passthrough):
        audio_b64 = _sine_wav_b64(0.1)
        r = flask_client_passthrough.post(
            "/infer",
            json={
                "audio": audio_b64,
                "prompt": "ferrofluid texture",
                "guidance_scale": 15.0,
                "num_steps": 4,
                "seed": 42,
                "input_strength": 0.6,
                "denoise_strength": 1.0,
            },
        )
        assert r.status_code == 200
        body = r.get_json()
        assert body["model_used"] is False, "passthrough must not claim model_used"
        assert "audio" in body and len(body["audio"]) > 0
        assert body["num_samples"] > 0
        assert "duration_ms" in body

        out, sr = decode_wav_bytes(base64.b64decode(body["audio"]))
        assert sr == 48000
        assert len(out) > 0

    def test_infer_missing_audio_400(self, flask_client_passthrough):
        r = flask_client_passthrough.post("/infer", json={"prompt": "x"})
        assert r.status_code == 400
        assert "error" in r.get_json()

    def test_infer_invalid_json_400(self, flask_client_passthrough):
        r = flask_client_passthrough.post(
            "/infer", data="not-json", content_type="application/json"
        )
        assert r.status_code == 400

    def test_shutdown_returns_shutting_down(self, flask_client_passthrough):
        """
        Under Flask test client, werkzeug.server.shutdown is absent and the
        handler falls through to os.kill(SIGTERM). Catch that so the suite
        does not tear down the pytest process.
        """
        import signal
        from unittest.mock import patch

        with patch("os.kill") as kill_mock:
            r = flask_client_passthrough.post("/shutdown")
            assert r.status_code == 200
            body = r.get_json()
            assert body["status"] == "shutting_down"
            # Either werkzeug shutdown ran (no kill) or SIGTERM was scheduled.
            if kill_mock.called:
                assert kill_mock.call_args[0][1] == signal.SIGTERM


# ---------------------------------------------------------------------------
# Optional live /infer (real model) — skip clearly when unavailable
# ---------------------------------------------------------------------------


def _default_model_path() -> str | None:
    env = os.environ.get("ACE_BRIDGE_MODEL_PATH")
    if env and os.path.isdir(env):
        return env

    # Resolve from repo root relative to this file:
    # ace-bridge/ -> bespoke-migration/ -> <repo root>/
    repo_root = os.path.abspath(
        os.path.join(os.path.dirname(__file__), "..", "..")
    )
    base_dir = os.path.join(repo_root, "models", "ace-step-v1.5-base")

    # Two layouts are accepted:
    #   (a) ACE-Step v1-3.5B HF snapshot (manual download / older auto-download):
    #       models/ace-step-v1.5-base/models--ACE-Step--ACE-Step-v1-3.5B/snapshots/<hash>/
    #       required subdirs: music_dcae_f8c8, music_vocoder, ace_step_transformer, umt5-base
    #   (b) ACE-Step 1.5 direct layout (a direct snapshot_download of
    #       ACE-Step/Ace-Step1.5 into local_dir):
    #       models/ace-step-v1.5-base/
    #       required subdirs: vae, acestep-v15-turbo, acestep-5Hz-lm-1.7B, Qwen3-Embedding-0.6B
    candidates: list[str] = []

    # (a) snapshot layout — scan all snapshots under the v1-3.5B cache dir
    snap_root = os.path.join(
        base_dir, "models--ACE-Step--ACE-Step-v1-3.5B", "snapshots"
    )
    if os.path.isdir(snap_root):
        for entry in sorted(os.listdir(snap_root)):
            candidates.append(os.path.join(snap_root, entry))

    # (b) direct v1.5 layout
    candidates.append(base_dir)

    # Per-layout required subdirs. A candidate matches if it satisfies ANY set.
    required_sets = (
        ("music_dcae_f8c8", "music_vocoder", "ace_step_transformer", "umt5-base"),
        ("vae", "acestep-v15-turbo", "acestep-5Hz-lm-1.7B", "Qwen3-Embedding-0.6B"),
    )
    for path in candidates:
        path = os.path.abspath(path)
        for required in required_sets:
            if all(os.path.isdir(os.path.join(path, d)) for d in required):
                # Require at least one non-empty weight blob behind the transformer.
                weight = os.path.join(
                    path, "ace_step_transformer", "diffusion_pytorch_model.safetensors"
                )
                if os.path.exists(weight) and os.path.getsize(weight) > 1_000_000:
                    return path
                # v1.5 layout: transformer weights live under acestep-v15-turbo/
                weight_v15 = os.path.join(
                    path, "acestep-v15-turbo", "diffusion_pytorch_model.safetensors"
                )
                if os.path.exists(weight_v15) and os.path.getsize(weight_v15) > 1_000_000:
                    return path
    return None


def _live_infer_reason() -> str | None:
    """Return skip reason, or None if live infer should run."""
    if os.environ.get("ACE_BRIDGE_LIVE_INFER") != "1":
        return (
            "Set ACE_BRIDGE_LIVE_INFER=1 to run real inference "
            "(requires ACE-Step checkpoint + torch)"
        )
    if _default_model_path() is None:
        return (
            "No usable ACE-Step-v1-3.5B checkpoint found. "
            "Expected models/ace-step-v1.5-base/models--ACE-Step--ACE-Step-v1-3.5B/"
            "snapshots/<hash> with music_dcae_f8c8, music_vocoder, "
            "ace_step_transformer, umt5-base. "
            "Or set ACE_BRIDGE_MODEL_PATH."
        )
    return None


@pytest.mark.skipif(
    _live_infer_reason() is not None, reason=_live_infer_reason() or "live infer off"
)
class TestLiveInfer:
    """
    Real short inference when ACE_BRIDGE_LIVE_INFER=1 and a checkpoint exists.
    Fails (does not skip) if the model path is set but load/infer fails.
    """

    def test_real_infer_changes_or_produces_audio(self):
        model_path = _default_model_path()
        assert model_path is not None

        wrapper = bridge.ACEStepWrapper(model_path=model_path, device="auto")
        assert wrapper.is_loaded, (
            f"Model failed to load from {model_path}: {wrapper.load_error}"
        )

        sr = 48000
        n = sr // 4  # 0.25 s — keep wall time bounded
        t = np.arange(n, dtype=np.float32) / float(sr)
        samples = (0.4 * np.sin(2.0 * np.pi * 220.0 * t)).astype(np.float32)

        out = wrapper.infer(
            audio_samples=samples,
            sample_rate=sr,
            prompt="ferrofluid texture, recursive drift",
            guidance_scale=15.0,
            num_steps=4,
            seed=42,
            input_strength=0.6,
            audio_duration=2.0,
            denoise_strength=1.0,
        )

        assert out is not None and len(out) > 0
        assert wrapper.inference_count >= 1
        # Measurable energy — silence would indicate a broken pipeline.
        rms = float(np.sqrt(np.mean(out.astype(np.float64) ** 2)))
        assert rms > 1e-6, f"output RMS too low ({rms}); likely silent failure"


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
