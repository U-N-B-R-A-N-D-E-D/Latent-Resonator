#!/usr/bin/env python3
"""
Unit tests for ACE-Step Bridge Server helpers.

Tests the WAV encode/decode functions in isolation — no model,
no Flask server, no GPU required. Only needs numpy.

Run:
    pytest test_bridge.py -v
"""

import sys
import os

import numpy as np
import pytest

# Import the bridge module from the same directory
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ace_bridge_server import encode_wav_bytes, decode_wav_bytes


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


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
