# Contributing to Latent Resonator

Thank you for your interest in contributing to Latent Resonator. This project explores recursive neural audio synthesis as a compositional tool, and we welcome contributions that extend or improve the system.

## How to Contribute

1. **Fork** this repository.
2. **Create a branch** from `main` for your change (`git checkout -b feature/your-feature`).
3. **Make your changes** following the guidelines below.
4. **Test thoroughly** -- ensure the app builds and your changes do not break existing functionality.
5. **Open a Pull Request** against `main` with a clear description of what you changed and why.

## What We Accept

- Bug fixes with a clear description of the problem and solution.
- Performance improvements backed by measurements.
- New excitation modes, DSP effects, or spectral processing algorithms that align with the project's aesthetic (generative degradation, recursive feedback, stochastic synthesis).
- Core ML model integration improvements.
- Documentation improvements, typo fixes, and clarifications.
- Accessibility improvements for the macOS interface.

## What We Do Not Accept

- Changes that introduce third-party Swift dependencies (the project uses only Apple system frameworks).
- UI redesigns that deviate from the established design system (`LRConstants.DS`).
- Features that require network access beyond the local bridge server (127.0.0.1).
- Code that introduces memory leaks or unbounded allocations in the audio path.

## Code Guidelines

### Architecture

- **No new files** unless explicitly necessary. Prefer modifying existing files.
- **Constants in config**, not scattered. All tuning parameters belong in `Config/Constants.swift`.
- **No magic numbers**. Use `LRConstants` for ranges, defaults, and thresholds.
- **Design tokens** for all UI values. Typography, colors, spacing, and radii must reference `LRConstants.DS`.

### Swift Style

- Follow the existing `.swiftlint.yml` configuration.
- Use `MARK:` comments to organize sections within files.
- Document non-obvious logic with inline comments. Reference whitepaper sections where applicable (e.g., `// Whitepaper §3.3`).
- Keep functions focused. Avoid functions longer than 100 lines when possible.
- All `@Published` properties, `Binding` paths, and `ObservableObject` wiring changes require careful review -- these affect the entire reactive chain.

### Audio Path Constraints

- **No allocations** in the audio render callback (`combinedSourceNode` install tap block).
- **No blocking calls** (network, disk I/O, locks) on the audio thread.
- Use `CircularAudioBuffer` for cross-thread audio communication.
- Validate that DSP changes do not produce NaN or Inf values under stress (see the stress test pattern in the test suite).

### Python Bridge

- The bridge server (`ace_bridge_server.py`) must remain compatible with Python 3.9--3.12.
- All JSON payloads between Swift and Python use snake_case keys.
- The bridge must function in passthrough mode (no model loaded) without errors.
- Python code must pass `black --check`, `flake8`, and `pylint`. Config: `pyproject.toml`, `.flake8`.

## Whitepaper Alignment

This project implements the methodology described in [docs/whitepaper.md](docs/whitepaper.md). Contributions should be consistent with the theoretical framework:

- The recursive formula: `S(i+1) = ACE(S(i) + N(mu,sigma), P, gamma)`
- The Koenig Seed: Euclidean rhythm E(5,13) with Dirac impulses
- The Non-Linear Spectral Processor as a semantic filter
- Generative degradation as an aesthetic goal, not a defect

## Git: Avoid Co-authored-by in Commits

Cursor adds `Co-authored-by: Cursor <cursoragent@cursor.com>` to commits made from the IDE. **Disable it:** Cursor Settings → Agents → Attribution → toggle OFF.

To keep the repo clean, also install the hook:

```bash
cp scripts/prepare-commit-msg .git/hooks/prepare-commit-msg && chmod +x .git/hooks/prepare-commit-msg
```

This strips Co-authored-by before each commit. To fix an existing commit, run `scripts/fix_commit_coauthor.sh` from Terminal.app (outside Cursor).

## Pull Request Process

1. Ensure your code builds without warnings (`xcodebuild build`).
2. Run SwiftLint: `swiftlint lint --config .swiftlint.yml`.
3. Run Python quality checks: `black --check LatentResonator/LatentResonator/Scripts/`, `flake8 LatentResonator/LatentResonator/Scripts/`, `pylint LatentResonator/LatentResonator/Scripts/*.py`.
4. Run Python bridge tests: `pytest LatentResonator/LatentResonator/Scripts/test_bridge.py`.
5. Describe what whitepaper section(s) your change relates to, if applicable.
6. A maintainer will review your PR. Expect feedback and iteration -- this is normal.

## License

By contributing, you agree that your contributions will be licensed under the [MIT License](LICENSE).

## Code of Conduct

Be respectful, constructive, and collaborative. We are building an instrument for artistic exploration -- the same spirit of openness should apply to how we work together.
