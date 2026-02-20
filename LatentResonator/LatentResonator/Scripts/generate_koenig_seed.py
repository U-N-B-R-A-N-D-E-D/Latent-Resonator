#!/usr/bin/env python3
"""
Koenig Seed Generator
=====================

Generates a WAV file containing Dirac impulses arranged in a
Euclidean rhythm E(5,13) — the "Koenig Seed" for the Latent Resonator.

Each impulse is followed by a 20ms tail of Gaussian white noise
to provide nucleation sites for the diffusion model's denoiser.

Output: koenig_seed.wav (48kHz, 16-bit, stereo, 10 seconds)

Usage:
    python generate_koenig_seed.py
    python generate_koenig_seed.py --duration 5.0 --output seed.wav

Requirements:
    pip install numpy
"""

import argparse
import os
import struct
import wave

import numpy as np


def euclidean_rhythm(pulses: int, steps: int) -> list:
    """
    Compute a Euclidean rhythm using Bjorklund's algorithm.

    Distributes `pulses` ones as evenly as possible across `steps` positions.
    Prime step counts (like 13) avoid Western metric symmetry.

    E(5,13) -> [1, 0, 0, 1, 0, 1, 0, 0, 1, 0, 1, 0, 0]
    """
    if pulses >= steps:
        return [1] * steps
    if pulses == 0:
        return [0] * steps

    pattern = [[1]] * pulses
    remainder = [[0]] * (steps - pulses)

    while len(remainder) > 1:
        take = min(len(pattern), len(remainder))
        merged = [pattern[i] + remainder[i] for i in range(take)]

        leftover_pattern = pattern[take:]
        leftover_remainder = remainder[take:]

        pattern = merged
        remainder = leftover_pattern + leftover_remainder

    result = []
    for group in pattern + remainder:
        result.extend(group)

    return result


def generate_koenig_seed(
    duration: float = 10.0,
    sample_rate: int = 48000,
    pulses: int = 5,
    steps: int = 13,
    noise_tail_ms: float = 20.0,
    noise_amplitude: float = 0.01,
    output_path: str = "koenig_seed.wav",
):
    """
    Generate the Koenig Seed WAV file.

    The seed contains Dirac impulses (containing all frequencies at equal
    energy) arranged in a Euclidean rhythm, with Gaussian noise tails
    acting as nucleation sites for the diffusion denoiser.
    """
    total_samples = int(duration * sample_rate)
    rhythm = euclidean_rhythm(pulses, steps)

    print(f"Euclidean Rhythm E({pulses},{steps}): {rhythm}")
    print(f"Duration: {duration}s | Sample Rate: {sample_rate}Hz")
    print(f"Total Samples: {total_samples:,}")

    # Create silent buffer
    audio = np.zeros(total_samples, dtype=np.float32)

    # Calculate positions
    samples_per_step = total_samples // steps
    noise_tail_samples = int(noise_tail_ms / 1000.0 * sample_rate)

    print(f"Samples per step: {samples_per_step:,}")
    print(f"Noise tail: {noise_tail_samples} samples ({noise_tail_ms}ms)")

    # Place Dirac impulses at pulse positions
    impulse_count = 0
    for step_idx, is_pulse in enumerate(rhythm):
        if not is_pulse:
            continue

        sample_pos = step_idx * samples_per_step
        if sample_pos >= total_samples:
            continue

        # Dirac impulse — infinite amplitude approximated by digital 1.0
        audio[sample_pos] = 1.0
        impulse_count += 1

        # Gaussian noise tail — gives the denoiser "something to chew on"
        tail_end = min(sample_pos + 1 + noise_tail_samples, total_samples)
        tail_length = tail_end - sample_pos - 1
        if tail_length > 0:
            noise = np.random.normal(0, noise_amplitude, tail_length)
            audio[sample_pos + 1 : tail_end] = noise.astype(np.float32)

    # Convert to 16-bit PCM
    audio_clipped = np.clip(audio, -1.0, 1.0)
    audio_int16 = (audio_clipped * 32767).astype(np.int16)

    # Write stereo WAV (duplicate mono to both channels)
    with wave.open(output_path, "w") as wav_file:
        wav_file.setnchannels(2)  # Stereo
        wav_file.setsampwidth(2)  # 16-bit
        wav_file.setframerate(sample_rate)

        # Interleave L/R
        stereo = np.column_stack([audio_int16, audio_int16])
        wav_file.writeframes(stereo.tobytes())

    file_size = os.path.getsize(output_path)
    print(f"\n--- Koenig Seed Generated ---")
    print(f"  File: {output_path}")
    print(f"  Size: {file_size / 1024:.1f} KB")
    print(f"  Format: {sample_rate}Hz / 16-bit / Stereo")
    print(f"  Impulses: {impulse_count} in E({pulses},{steps})")
    print(f"  Rhythm: {''.join(str(b) for b in rhythm)}")


def main():
    parser = argparse.ArgumentParser(
        description="Generate Koenig Seed WAV file for Latent Resonator"
    )
    parser.add_argument("--duration", type=float, default=10.0, help="Duration in seconds")
    parser.add_argument("--sample-rate", type=int, default=48000, help="Sample rate in Hz")
    parser.add_argument("--pulses", type=int, default=5, help="Euclidean pulses (k)")
    parser.add_argument("--steps", type=int, default=13, help="Euclidean steps (n)")
    parser.add_argument(
        "--noise-tail-ms", type=float, default=20.0, help="Noise tail duration (ms)"
    )
    parser.add_argument("--noise-amplitude", type=float, default=0.01, help="Noise tail amplitude")
    parser.add_argument("--output", type=str, default="koenig_seed.wav", help="Output file path")

    args = parser.parse_args()

    generate_koenig_seed(
        duration=args.duration,
        sample_rate=args.sample_rate,
        pulses=args.pulses,
        steps=args.steps,
        noise_tail_ms=args.noise_tail_ms,
        noise_amplitude=args.noise_amplitude,
        output_path=args.output,
    )


if __name__ == "__main__":
    main()
