# Demo and experiment generator

`make_demo.py` drives the ACE-Step Python bridge with real inference. It is both an
end-to-end validation of the bridge and the generator of the audio demo pack.

## Run

Start the bridge (see `bespoke-migration/ace-bridge/`), then:

```
python demos/make_demo.py --url http://127.0.0.1:8983 --out demos/out
```

Requirements: Python 3 with numpy (matplotlib is optional and only used for plots).
Useful options: `--iterations/-n` (default 8), `--duration` (source seconds, default 8),
`--sigma` (noise added before each iteration, default 0.01), `--seed`, `--steps`,
`--guidance`, `--input-strength`, `--sources`, `--prompts`, `--sweep-strengths`,
`--sweep-iterations`, `--no-sweep`. A full default run takes roughly 15-30 minutes
depending on the machine.

## What is generated

- Sources are synthesised by the script itself (FM bell, Euclidean E(5,13) impulse train
  with noise tail, band-passed noise burst, two-note drone), so no third-party audio is involved.
- For each source and prompt, a recursive loop `S(i+1) = ACE(S(i) + N(0, sigma), prompt)` with
  fixed seeds. Every iteration is saved as `iterNN_raw.wav` (untouched, float32) and
  `iterNN_norm.wav` (peak-normalised to -3 dBFS for listening).
- `metrics.csv`: per-iteration wall time, RMS, peak, spectral centroid and flatness, correlation
  to S(0) and S(i-1), spectral cosine similarity to S(i-1), and the contraction ratio
  `||S(i+1)-S(i)|| / ||S(i)-S(i-1)||` computed on STFT magnitude spectra.
- `<run>/recipe.json`: seed, steps, guidance, input_strength, denoise_strength, prompt, sigma,
  sample rate and bridge version/dtype.
- A small `input_strength` sweep (0.2, 0.4, 0.6, 0.8) on one source, same seed. It provides
  first data points only; it does not establish a critical value.
- `INDEX.md` listing every audio file with its recipe, and `plots_*.png` if matplotlib is present.

`demos/out/` is gitignored: audio outputs are not committed and ship as release assets.
