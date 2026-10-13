#!/usr/bin/env python3
"""
Benchmark harness for the ACE-Step bridge.

Sends synthetic audio of several durations to a running bridge server and
prints a markdown table with wall time, real-time factor (wall seconds per
second of audio; lower is better) and, when the server reports them, the
per-phase timings from the `timings` field of the /infer response.

Usage:
    python bench_bridge.py --url http://127.0.0.1:8981 \
        --durations 3,10,30 --steps 8 --repeat 3
"""

import argparse
import base64
import json
import math
import os
import statistics
import struct
import sys
import time
import urllib.error
import urllib.request

SAMPLE_RATE = 48000


def make_wav_b64(duration_s: float, channels: int = 1, sr: int = SAMPLE_RATE) -> str:
    """Build a 32-bit float WAV (sine plus a slow amplitude ramp) as base64."""
    n = int(duration_s * sr)
    frames = bytearray()
    for i in range(n):
        v = 0.3 * math.sin(2.0 * math.pi * 220.0 * i / sr) * (0.5 + 0.5 * math.sin(i / sr))
        frames += struct.pack("<f", v) * channels
    data = bytes(frames)
    block_align = 4 * channels
    header = struct.pack(
        "<4sI4s4sIHHIIHH4sI",
        b"RIFF",
        36 + len(data),
        b"WAVE",
        b"fmt ",
        16,
        3,
        channels,
        sr,
        sr * block_align,
        block_align,
        32,
        b"data",
        len(data),
    )
    return base64.b64encode(header + data).decode("ascii")


def http_json(url: str, payload=None, timeout: float = 900.0):
    body = None if payload is None else json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        url, data=body, headers={"Content-Type": "application/json"} if body else {}
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.loads(e.read().decode("utf-8"))
        except ValueError:
            return e.code, {}


def run_once(base_url, duration, steps, channels, prompt, strength):
    payload = {
        "audio": make_wav_b64(duration, channels),
        "prompt": prompt,
        "num_steps": steps,
        "input_strength": strength,
        "audio_duration": duration,
        "seed": 42,
    }
    t0 = time.perf_counter()
    status, body = http_json(base_url + "/infer", payload)
    wall = time.perf_counter() - t0
    return status, body, wall


def fmt(x, nd=1):
    return "-" if x is None else f"{x:.{nd}f}"


def main():
    ap = argparse.ArgumentParser(description="Benchmark the ACE-Step bridge")
    ap.add_argument("--url", default="http://127.0.0.1:8976", help="Bridge base URL")
    ap.add_argument("--durations", default="3,10", help="Comma-separated clip lengths (s)")
    ap.add_argument("--steps", type=int, default=8, help="num_steps sent to /infer")
    ap.add_argument("--repeat", type=int, default=3, help="Runs per duration")
    ap.add_argument("--channels", type=int, default=1, choices=[1, 2], help="Input channels")
    ap.add_argument("--strength", type=float, default=0.6, help="input_strength")
    ap.add_argument("--prompt", default="warm ambient pad, slow evolving texture")
    ap.add_argument("--skip-first", action="store_true", help="Discard the first run per duration")
    args = ap.parse_args()

    base = args.url.rstrip("/")
    status, health = http_json(base + "/health", timeout=10)
    if status != 200:
        print(f"Server not healthy at {base} (HTTP {status})", file=sys.stderr)
        return 1
    print(
        f"Server: model_loaded={health.get('model_loaded')} "
        f"type={health.get('model_type')} device={health.get('device')}"
    )
    try:
        print(f"Load average at start: {', '.join(f'{v:.1f}' for v in os.getloadavg())}")
    except OSError:
        pass

    durations = [float(d) for d in args.durations.split(",") if d.strip()]
    rows = []
    phase_keys = []
    for dur in durations:
        for i in range(args.repeat):
            status, body, wall = run_once(
                base, dur, args.steps, args.channels, args.prompt, args.strength
            )
            timings = body.get("timings") if isinstance(body, dict) else None
            if isinstance(timings, dict):
                for k in timings:
                    if k not in phase_keys:
                        phase_keys.append(k)
            rows.append(
                dict(
                    dur=dur,
                    run=i + 1,
                    status=status,
                    wall=wall,
                    timings=timings or {},
                    server_ms=body.get("duration_ms") if isinstance(body, dict) else None,
                    err=body.get("error") if isinstance(body, dict) else None,
                )
            )
            print(
                f"  {dur:g}s run {i + 1}/{args.repeat}: HTTP {status} {wall:.1f}s", file=sys.stderr
            )

    header = ["audio s", "run", "HTTP", "wall s", "RTF"] + [f"{k} s" for k in phase_keys]
    print()
    print("| " + " | ".join(header) + " |")
    print("|" + "|".join(["---"] * len(header)) + "|")
    for r in rows:
        rtf = r["wall"] / r["dur"] if r["status"] == 200 else None
        cells = [f"{r['dur']:g}", str(r["run"]), str(r["status"]), fmt(r["wall"]), fmt(rtf)]
        cells += [fmt(r["timings"].get(k), 2) for k in phase_keys]
        print("| " + " | ".join(cells) + " |")

    print()
    print("| audio s | ok runs | median wall s | best wall s | median RTF | best RTF |")
    print("|---|---|---|---|---|---|")
    for dur in durations:
        ok = [r["wall"] for r in rows if r["dur"] == dur and r["status"] == 200]
        if args.skip_first and len(ok) > 1:
            ok = ok[1:]
        if ok:
            med, best = statistics.median(ok), min(ok)
            row = [f"{dur:g}", str(len(ok)), f"{med:.1f}", f"{best:.1f}"]
            row += [f"{med / dur:.1f}", f"{best / dur:.1f}"]
            print("| " + " | ".join(row) + " |")
        else:
            print(f"| {dur:g} | 0 | - | - | - | - |")
    try:
        print(f"\nLoad average at end: {', '.join(f'{v:.1f}' for v in os.getloadavg())}")
    except OSError:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
