# Contributing to Latent Resonator

Latent Resonator is a recursive neural audio resonator built as a Bespoke Synth module (`bespoke-migration/module/`) that talks to a local Python bridge around ACE-Step (`bespoke-migration/ace-bridge/`). Contributions are welcome.

## Workflow

1. Fork the repository and branch from `main`.
2. Make a focused change; explain what and why in the pull request.
3. Run the checks below.
4. Open a pull request against `main`.

## Structure

- `bespoke-migration/module/` -- C++ Bespoke Synth module (`ModuleACEResonator`).
- `bespoke-migration/ace-bridge/` -- Python HTTP bridge and its tests.
- `bespoke-migration/patches/` -- pinned upstream Bespoke base and the JUCE build patch.
- `scripts/` -- `apply_module.sh` and `package_macos.sh`.
- `demos/` -- reproducible demo and experiment generator.
- `docs/` -- documentation, whitepaper and the distilled notes from the retired Swift app.

## Guidelines

### Module (C++)

- No allocation, locking, disk or network I/O on the audio thread.
- Guard against NaN/Inf in DSP changes.
- Follow Bespoke Synth's coding conventions and keep the upstream license header.

### Python bridge

- Must run on Python 3.9--3.12 and work in passthrough mode (no model loaded).
- The bridge listens on 127.0.0.1 only.
- Code must pass `black --check`, `flake8` and `pylint` (config: `pyproject.toml`, `.flake8`).

## Checks

```bash
pytest bespoke-migration/ace-bridge/test_bridge.py -v
```

Also run `black --check`, `flake8` and `pylint` on the bridge sources.

## Security and privacy

- No secrets, tokens or API keys in commits.
- No personal paths (for example `/Users/<name>/`) or personal data in code, docs or logs.
- Do not commit model weights or generated audio.

## License

- Contributions to `bespoke-migration/module/` are licensed under GPL-3.0-or-later (see `bespoke-migration/module/LICENSE`), matching Bespoke Synth.
- Contributions to everything else are licensed under the MIT License (see `LICENSE`).

Third-party components are listed in `NOTICE`.

## Code of Conduct

Be respectful, constructive and collaborative.
