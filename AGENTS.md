# AGENTS.md — Latent Resonator

> Guide for contributors and coding agents. Tool-agnostic.

## What this is
A recursive neural resampler: it captures audio, runs it through the ACE-Step music
model, feeds the result back in, and repeats — accumulating the model's own timbral
tendencies. It ships as a custom module inside a fork of Bespoke Synth.

## Layout
- `bespoke-migration/module/` — C++ module registered in Bespoke Synth as `latentresonator`; neural inference is isolated from the audio and UI threads. Build notes in `BUILD_VERIFICATION.md`.
- `bespoke-migration/ace-bridge/` — standalone Python HTTP bridge wrapping ACE-Step; binds to `127.0.0.1` only.
- `docs/` — whitepaper, migration notes, testing notes, legacy Swift learnings.
- `demos/` — demo generation script.
- `scripts/` — macOS packaging for the standalone zip.
- `.github/workflows/` — CI (`ci.yml`) and release (`release.yml`).

## Build, test, run
- Install (bridge): `cd bespoke-migration/ace-bridge && ./setup_ace_bridge.sh --with-model` (Python 3.12 venv; downloads weights, never bundled).
- Test (bridge): `pytest bespoke-migration/ace-bridge/test_bridge.py -v` — must pass before any PR. Needs `numpy pytest flask soundfile`.
- Lint (bridge): `black --check bespoke-migration/ace-bridge` and `flake8 bespoke-migration/ace-bridge` (see `.flake8`).
- Audit (bridge): `pip-audit -r bespoke-migration/ace-bridge/requirements_bridge.txt`.
- Build module: compiled into the host binary; the exact registration steps are in `bespoke-migration/module/BUILD_VERIFICATION.md`.
- Package: `scripts/package_macos.sh` assembles `LatentResonator-<version>-macOS-arm64.zip`.

## Conventions
- Branching: `main` is stable; work on `feat/*`, `fix/*`, `docs/*`; open a PR.
- Style: `black` + `flake8` for the bridge. Commit messages: imperative mood with an `area: summary` prefix.
- Do not commit secrets, local paths, hostnames or IP addresses; use placeholders (`example.local`, `<HOST>`).
- Never bundle or commit model weights: `.gitignore` blocks `*.safetensors`, `*.pt`, `*.ckpt`, `*.bin` and the model checkouts.

## Pointers
- Docs: `docs/` · Changelog: `CHANGELOG.md` · Contributing: `CONTRIBUTING.md` · License: `LICENSE` (see also `NOTICE`).
