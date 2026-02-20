# Latent Resonator v1.0.2 — Testing

## Quick start

1. **Open the app** — Double-click `LatentResonator.app`
2. **If macOS blocks it** — Right-click → Open → Open
3. **Press START** — The app will set up the ACE-Step bridge (venv, deps) if needed

## With ACE-Step (neural inference)

- Install [ACE-Step 1.5](https://github.com/facebookresearch/ace-step) per their repo
- In Latent Resonator: **Settings** → point to your model path (or use default)
- Press **START** in PERFORM — first run may take a minute to create venv and load the model

## Without ACE-Step (DSP only)

- The app runs standalone: filters, delay, resonator, excitation sources
- Use **SILENCE** excitation + DSP for feedback-loop testing without neural inference

## Contents

- `LatentResonator.app` — The application
- `README.md` — Full documentation
- `docs/whitepaper.md` — Technical spec
- `docs/screenshots/` — Setup and Perform views

## Requirements

- macOS 14+
- For ACE-Step: Python 3.9–3.12, PyTorch, model weights
