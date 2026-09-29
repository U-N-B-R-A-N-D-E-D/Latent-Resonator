#!/usr/bin/env python3
"""Reproducible demo + experiment generator for the ACE-Step Python bridge.

Synthesises its own source sounds (no third-party audio), runs recursive
loops S(i+1) = ACE(S(i) + N(0, sigma), prompt) against a running bridge, logs
per-iteration metrics and recipes, runs an input_strength sweep and writes an
INDEX.md.  Stdlib + numpy only (matplotlib optional, for plots).

    python demos/make_demo.py --url http://127.0.0.1:8983 --out demos/out
"""
import argparse
import base64
import csv
import json
import os
import struct
import sys
import time
import urllib.request
import wave

import numpy as np

# --------------------------------------------------------------------------
# WAV I/O
# --------------------------------------------------------------------------


def write_wav(path, x, sr, float32=False):
    x = np.asarray(x, dtype=np.float32)
    if float32:
        data = x.tobytes()
        hdr = b"RIFF" + struct.pack("<I", 36 + len(data)) + b"WAVE"
        hdr += b"fmt " + struct.pack("<IHHIIHH", 16, 3, 1, sr, sr * 4, 4, 32)
        hdr += b"data" + struct.pack("<I", len(data))
        with open(path, "wb") as f:
            f.write(hdr + data)
    else:
        pcm = (np.clip(x, -1, 1) * 32767.0).astype("<i2")
        with wave.open(path, "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(sr)
            w.writeframes(pcm.tobytes())


def wav_bytes(x, sr):
    import io

    x = np.clip(np.asarray(x, dtype=np.float32), -1, 1)
    data = x.tobytes()
    b = io.BytesIO()
    b.write(b"RIFF" + struct.pack("<I", 36 + len(data)) + b"WAVE")
    b.write(b"fmt " + struct.pack("<IHHIIHH", 16, 3, 1, sr, sr * 4, 4, 32))
    b.write(b"data" + struct.pack("<I", len(data)) + data)
    return b.getvalue()


def read_wav_bytes(buf):
    """Parse PCM16/24/32 and float32/64 WAV (incl. WAVE_FORMAT_EXTENSIBLE); returns mono float32, sr."""
    assert buf[:4] == b"RIFF" and buf[8:12] == b"WAVE", "not a RIFF/WAVE"
    pos, fmt, data = 12, None, None
    while pos + 8 <= len(buf):
        cid = buf[pos:pos + 4]
        size = struct.unpack("<I", buf[pos + 4:pos + 8])[0]
        body = buf[pos + 8:pos + 8 + size]
        if cid == b"fmt ":
            tag, ch, sr, _, _, bits = struct.unpack("<HHIIHH", body[:16])
            if tag == 0xFFFE and len(body) >= 26:
                tag = struct.unpack("<H", body[24:26])[0]
            fmt = (tag, ch, sr, bits)
        elif cid == b"data":
            data = body
        pos += 8 + size + (size & 1)
    tag, ch, sr, bits = fmt
    if tag == 3:
        x = np.frombuffer(data, dtype="<f4" if bits == 32 else "<f8").astype(np.float32)
    elif bits == 16:
        x = np.frombuffer(data, dtype="<i2").astype(np.float32) / 32768.0
    elif bits == 24:
        b = np.frombuffer(data, dtype=np.uint8).reshape(-1, 3)
        v = b[:, 0].astype(np.int32) | (b[:, 1].astype(np.int32) << 8) | (b[:, 2].astype(np.int32) << 16)
        v = np.where(v & 0x800000, v - 0x1000000, v)
        x = v.astype(np.float32) / 8388608.0
    elif bits == 32:
        x = np.frombuffer(data, dtype="<i4").astype(np.float32) / 2147483648.0
    else:
        raise ValueError(f"unsupported wav format tag={tag} bits={bits}")
    if ch > 1:
        x = x[: len(x) // ch * ch].reshape(-1, ch).mean(axis=1)
    return x, sr


# --------------------------------------------------------------------------
# Source synthesis
# --------------------------------------------------------------------------


def _norm(x, peak=0.7):
    return (x / (np.max(np.abs(x)) + 1e-12) * peak).astype(np.float32)


def fm_bell(dur, sr, f0=220.0, ratio=3.5, index=4.0, decay=1.2, hits=(0.0, 2.5, 5.0)):
    n = int(dur * sr)
    out = np.zeros(n)
    for t0 in hits:
        i0 = int(t0 * sr)
        if i0 >= n:
            continue
        t = np.arange(n - i0) / sr
        env = np.exp(-t / decay)
        mod = index * np.exp(-t / (decay * 0.5)) * np.sin(2 * np.pi * f0 * ratio * t)
        out[i0:] += env * np.sin(2 * np.pi * f0 * t + mod)
    return _norm(out)


def euclid(k, n):
    return [((i * k) % n) < k for i in range(n)]


def koenig_seed(dur, sr, rng, k=5, n=13, step=0.16):
    """Pulsed Euclidean impulse train E(k,n) (each pulse a short decaying click) + short noise tail."""
    total = int(dur * sr)
    out = np.zeros(total)
    pat = euclid(k, n)
    idx, pos = 0, 0.0
    click_len = int(0.02 * sr)
    tt = np.arange(click_len) / sr
    click = np.exp(-tt / 0.004) * np.sin(2 * np.pi * 1800 * tt)
    while pos < dur - 1.5:
        if pat[idx % n]:
            i0 = int(pos * sr)
            out[i0:i0 + click_len] += click[: max(0, min(click_len, total - i0))]
        idx += 1
        pos += step
    tail_start = int(pos * sr)
    tail_n = total - tail_start
    if tail_n > 0:
        env = np.exp(-np.arange(tail_n) / (0.5 * sr))
        out[tail_start:] += 0.15 * rng.standard_normal(tail_n) * env
    return _norm(out)


def noise_burst(dur, sr, rng, lo=800.0, hi=3000.0):
    n = int(dur * sr)
    x = np.zeros(n)
    blen = int(min(1.5, dur / 3) * sr)
    spec = np.fft.rfft(rng.standard_normal(blen))
    f = np.fft.rfftfreq(blen, 1 / sr)
    spec[(f < lo) | (f > hi)] = 0
    burst = np.fft.irfft(spec, blen)
    burst *= np.hanning(blen)
    x[int(0.5 * sr):int(0.5 * sr) + blen] = burst[: n - int(0.5 * sr)]
    return _norm(x)


def drone(dur, sr, f1=110.0, f2=164.81):
    t = np.arange(int(dur * sr)) / sr
    x = np.zeros_like(t)
    for f in (f1, f2):
        for h, a in ((1, 1.0), (2, 0.4), (3, 0.2)):
            x += a * np.sin(2 * np.pi * f * h * t + 0.3 * h)
    x *= np.minimum(1.0, t / 0.3) * np.minimum(1.0, (t[-1] - t) / 0.5)
    return _norm(x)


def make_sources(dur, sr, seed=0):
    rng = np.random.default_rng(seed)
    return {
        "bell": (fm_bell(dur, sr), "Decaying FM bell, three strikes (220 Hz carrier)."),
        "koenig": (koenig_seed(dur, sr, rng), "Euclidean E(5,13) click train with short noise tail (the 'Koenig seed')."),
        "noiseburst": (noise_burst(dur, sr, rng), "Band-passed (0.8-3 kHz) noise burst with Hann envelope."),
        "drone": (drone(dur, sr), "Two-note drone (A2 + E3) with three harmonics each."),
    }


# --------------------------------------------------------------------------
# Metrics
# --------------------------------------------------------------------------

NFFT, HOP = 2048, 1024


def stft_mag(x, n_fft=NFFT, hop=HOP):
    x = np.asarray(x, dtype=np.float64)
    if len(x) < n_fft:
        x = np.pad(x, (0, n_fft - len(x)))
    win = np.hanning(n_fft)
    nfr = 1 + (len(x) - n_fft) // hop
    idx = np.arange(n_fft)[None, :] + hop * np.arange(nfr)[:, None]
    return np.abs(np.fft.rfft(x[idx] * win, axis=1))  # (frames, bins)


def corr(a, b):
    n = min(len(a), len(b))
    a, b = a[:n] - a[:n].mean(), b[:n] - b[:n].mean()
    d = np.linalg.norm(a) * np.linalg.norm(b)
    return float(a @ b / d) if d > 0 else float("nan")


def cosine(a, b):
    d = np.linalg.norm(a) * np.linalg.norm(b)
    return float(np.sum(a * b) / d) if d > 0 else float("nan")


def features(x, sr):
    m = stft_mag(x)
    mean_spec = m.mean(axis=0)
    f = np.fft.rfftfreq(NFFT, 1 / sr)
    power = mean_spec ** 2
    centroid = float((f * mean_spec).sum() / (mean_spec.sum() + 1e-12))
    flat = float(np.exp(np.mean(np.log(power + 1e-12))) / (np.mean(power) + 1e-12))
    return {
        "rms": float(np.sqrt(np.mean(np.square(x, dtype=np.float64)))),
        "peak": float(np.max(np.abs(x))),
        "centroid_hz": centroid,
        "flatness": flat,
    }, m


# --------------------------------------------------------------------------
# Bridge client
# --------------------------------------------------------------------------


def http_json(url, payload=None, timeout=900):
    if payload is None:
        req = urllib.request.Request(url)
    else:
        req = urllib.request.Request(url, data=json.dumps(payload).encode(), headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read())


def infer(url, x, sr, params):
    body = dict(params)
    body["audio"] = base64.b64encode(wav_bytes(x, sr)).decode("ascii")
    body["audio_duration"] = len(x) / sr
    t0 = time.time()
    resp = http_json(url + "/infer", body)
    wall = time.time() - t0
    y, sr_out = read_wav_bytes(base64.b64decode(resp["audio"]))
    return y, sr_out, wall


# --------------------------------------------------------------------------
# Recursive loop
# --------------------------------------------------------------------------

CSV_FIELDS = [
    "run", "source", "prompt", "iter", "wall_s", "rms", "peak", "centroid_hz", "flatness",
    "corr_s0", "corr_prev", "spec_cos_prev", "contraction", "input_strength",
]


def run_loop(url, status, out, run_id, src_name, s0, sr, prompt, n_iter, args, input_strength, rows, index, desc):
    rundir = os.path.join(out, run_id)
    os.makedirs(rundir, exist_ok=True)
    params = {
        "prompt": prompt,
        "guidance_scale": args.guidance,
        "num_steps": args.steps,
        "seed": args.seed,
        "input_strength": input_strength,
        "denoise_strength": args.denoise,
    }
    recipe = {
        "run": run_id, "source": src_name, "description": desc, "prompt": prompt,
        "seed": args.seed, "num_steps": args.steps, "guidance_scale": args.guidance,
        "input_strength": input_strength, "denoise_strength": args.denoise,
        "sigma": args.sigma, "iterations": n_iter, "sample_rate": sr,
        "noise_seed": args.seed, "source_duration_s": len(s0) / sr,
        "bridge_status": {k: status.get(k) for k in ("version", "dtype", "device", "model_type", "model_path", "sample_rate")},
        "task_type": "cover (bridge default)",
    }
    rng = np.random.default_rng(args.seed)
    cur = s0
    feat0, m0 = features(s0, sr)
    prev, m_prev, m_prev2 = s0, m0, None
    write_wav(os.path.join(rundir, "iter00_raw.wav"), s0, sr, float32=True)
    write_wav(os.path.join(rundir, "iter00_norm.wav"), _norm(s0, 10 ** (-3 / 20)), sr)
    for i in range(1, n_iter + 1):
        noisy = cur + args.sigma * rng.standard_normal(len(cur)).astype(np.float32)
        y, sr_out, wall = infer(url, noisy, sr, params)
        if sr_out != sr:
            raise RuntimeError(f"bridge returned sr={sr_out}, expected {sr}")
        if len(y) != len(s0):
            y = np.pad(y, (0, max(0, len(s0) - len(y))))[: len(s0)]
        f, m = features(y, sr)
        contraction = float("nan")
        if m_prev2 is not None:
            den = np.linalg.norm(m_prev - m_prev2)
            contraction = float(np.linalg.norm(m - m_prev) / den) if den > 0 else float("nan")
        row = {
            "run": run_id, "source": src_name, "prompt": prompt, "iter": i, "wall_s": round(wall, 2),
            **{k: round(v, 6) for k, v in f.items()},
            "corr_s0": round(corr(y, s0), 6), "corr_prev": round(corr(y, prev), 6),
            "spec_cos_prev": round(cosine(m, m_prev), 6), "contraction": round(contraction, 6),
            "input_strength": input_strength,
        }
        rows.append(row)
        write_wav(os.path.join(rundir, f"iter{i:02d}_raw.wav"), y, sr, float32=True)
        write_wav(os.path.join(rundir, f"iter{i:02d}_norm.wav"), _norm(y, 10 ** (-3 / 20)), sr)
        print(f"[{run_id}] iter {i}/{n_iter} {wall:5.1f}s rms={f['rms']:.3f} cent={f['centroid_hz']:.0f} "
              f"flat={f['flatness']:.3f} c0={row['corr_s0']:.3f} contr={contraction:.3f}", flush=True)
        prev, m_prev2, m_prev, cur = y, m_prev, m, y
    with open(os.path.join(rundir, "recipe.json"), "w") as fh:
        json.dump(recipe, fh, indent=2)
    index.append(recipe)


def write_index(out, index, sweep_ids, total_s, plots):
    L = ["# Demo pack index", "",
         f"Generated by `demos/make_demo.py`; total wall time {total_s / 60:.1f} min. "
         "Sources are synthesised; `*_norm.wav` are peak-normalised to -3 dBFS for listening, "
         "`*_raw.wav` are the untouched bridge outputs (float32).", ""]
    for r in index:
        tag = "sweep" if r["run"] in sweep_ids else "loop"
        L += [f"## {r['run']} ({tag})", "",
              f"- Source: {r['source']} - {r['description']}",
              f"- Recipe: prompt `{r['prompt']}`, seed {r['seed']}, steps {r['num_steps']}, guidance {r['guidance_scale']}, "
              f"input_strength {r['input_strength']}, denoise_strength {r['denoise_strength']}, sigma {r['sigma']}, "
              f"{r['iterations']} iterations, {r['sample_rate']} Hz, dtype {r['bridge_status'].get('dtype')}, "
              f"bridge {r['bridge_status'].get('version')} (`{r['run']}/recipe.json`)", ""]
        for i in range(r["iterations"] + 1):
            what = "synthesised source S(0)" if i == 0 else f"S({i}) = ACE(S({i - 1}) + noise, \"{r['prompt']}\")"
            L.append(f"- `{r['run']}/iter{i:02d}_norm.wav` / `iter{i:02d}_raw.wav`: {what}")
        L.append("")
    if plots:
        L += ["## Plots", ""] + [f"- `{p}`" for p in plots] + [""]
    L += ["Sources: `sources/*.wav`. Metrics: `metrics.csv`."]
    with open(os.path.join(out, "INDEX.md"), "w") as fh:
        fh.write("\n".join(L) + "\n")


def make_plots(out, rows):
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except Exception:
        print("matplotlib not available; skipping plots")
        return []
    made = []
    for group, pred in (("loops", lambda r: not r["run"].startswith("sweep")), ("sweep", lambda r: r["run"].startswith("sweep"))):
        sel = [r for r in rows if pred(r)]
        if not sel:
            continue
        fig, axes = plt.subplots(1, 3, figsize=(15, 4))
        for run in dict.fromkeys(r["run"] for r in sel):
            rr = [r for r in sel if r["run"] == run]
            it = [r["iter"] for r in rr]
            axes[0].plot(it, [r["centroid_hz"] for r in rr], marker="o", label=run)
            axes[1].plot(it, [r["flatness"] for r in rr], marker="o")
            c = [r["contraction"] for r in rr]
            axes[2].plot(it, c, marker="o")
        for ax, t in zip(axes, ("spectral centroid (Hz)", "spectral flatness", "contraction ratio")):
            ax.set_title(t)
            ax.set_xlabel("iteration")
        axes[2].axhline(1.0, color="gray", ls="--", lw=0.8)
        axes[0].legend(fontsize=6)
        fig.tight_layout()
        p = f"plots_{group}.png"
        fig.savefig(os.path.join(out, p), dpi=110)
        plt.close(fig)
        made.append(p)
    return made


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--url", default="http://127.0.0.1:8983")
    ap.add_argument("--out", default="demos/out")
    ap.add_argument("--iterations", "-n", type=int, default=8)
    ap.add_argument("--duration", type=float, default=8.0, help="source duration in seconds")
    ap.add_argument("--sigma", type=float, default=0.01, help="std of Gaussian noise added before each iteration")
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--steps", type=int, default=20)
    ap.add_argument("--guidance", type=float, default=15.0)
    ap.add_argument("--input-strength", type=float, default=0.6)
    ap.add_argument("--denoise", type=float, default=1.0)
    ap.add_argument("--sources", default="bell,koenig,noiseburst,drone")
    ap.add_argument("--prompts", default="tibetan horns,metallic resonance,granular texture")
    ap.add_argument("--sweep-source", default="bell")
    ap.add_argument("--sweep-prompt", default="metallic resonance")
    ap.add_argument("--sweep-strengths", default="0.2,0.4,0.6,0.8")
    ap.add_argument("--sweep-iterations", type=int, default=6)
    ap.add_argument("--no-sweep", action="store_true")
    args = ap.parse_args()

    try:
        status = http_json(args.url + "/status", timeout=30)
    except Exception as e:
        sys.exit(f"cannot reach bridge at {args.url}: {e}")
    if not status.get("model_loaded"):
        sys.exit(f"bridge has no model loaded: {status.get('error')}")
    sr = int(status.get("sample_rate", 48000))
    print(f"bridge {status.get('version')} dtype={status.get('dtype')} device={status.get('device')} sr={sr}")

    out = args.out
    os.makedirs(os.path.join(out, "sources"), exist_ok=True)
    srcs = make_sources(args.duration, sr, seed=args.seed)
    for name, (x, _) in srcs.items():
        write_wav(os.path.join(out, "sources", f"{name}.wav"), x, sr)

    rows, index, sweep_ids = [], [], set()
    t_start = time.time()
    slug = lambda s: s.replace(" ", "-")
    for sname in args.sources.split(","):
        for prompt in args.prompts.split(","):
            x, desc = srcs[sname]
            run_loop(args.url, status, out, f"{sname}__{slug(prompt)}", sname, x, sr, prompt,
                     args.iterations, args, args.input_strength, rows, index, desc)
    if not args.no_sweep:
        x, desc = srcs[args.sweep_source]
        for s in (float(v) for v in args.sweep_strengths.split(",")):
            rid = f"sweep_{args.sweep_source}__is{s:.1f}"
            sweep_ids.add(rid)
            run_loop(args.url, status, out, rid, args.sweep_source, x, sr, args.sweep_prompt,
                     args.sweep_iterations, args, s, rows, index, desc)

    with open(os.path.join(out, "metrics.csv"), "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=CSV_FIELDS)
        w.writeheader()
        w.writerows(rows)
    plots = make_plots(out, rows)
    total = time.time() - t_start
    write_index(out, index, sweep_ids, total, plots)
    print(f"done in {total / 60:.1f} min; {len(rows)} takes; output in {out}")


if __name__ == "__main__":
    main()
