# Changelog

All notable changes to Latent Resonator are documented here.

## [1.0.3] — 2026-02-20

### Added

- **Settings > Config** — Configurable ACE-Step model path and recording output directory. Defaults: `~/Documents/LatentResonatorModels/` and `~/Documents/LatentResonator/`. Browse and Reset buttons.
- **Drum Lane preset** — 808-focused preset with entropy/granularity caps, DrumVoice prompts, Euclidean E(4,8).
- **Perform UI clarity** — Lane headers (CHANNELS → CONTROLLING, DRIFT), ACTIVE badge on focus lane, muted/soloed visual states.

### Changed

- **Sequencer** — Step timer uses first time-mode lane (fixes lane-switch breaking sequencer).
- **Model discovery** — Documents directory checked first; Application Support second.
- **Design system** — LRComponents, RetroKnob, LatentXYPad, SceneCrossfaderView use centralized tokens.

### Fixed

- Lane switching no longer breaks step sequencer timing.
- Drum Lane parameters capped to preserve punch (entropy/granularity ≤ 28).

---

## [1.0.2] — 2026-02-19

### Added

- **SequencerEngine** — Extracted step grid state, advance modes, BPM, and chain length from NeuralEngine.
- **SceneManager** — Dedicated scene bank, apply/capture, and crossfade blending logic.
- **SceneCrossfaderView** — Standalone scene A/B crossfader with load buttons.
- **AudioRecorder** — Master recording to WAV in `~/Documents/LatentResonator/`.
- **Python tooling** — `pyproject.toml` for black, flake8, pylint; `.flake8` config.

### Changed

- **NeuralEngine** — Delegates sequencer and scene logic to SequencerEngine and SceneManager; main-thread assertion for lane mutation.
- **PerformanceMotherbaseView** — Split FocusLaneStripView; RetroKnob calls formatted for line length.
- **SwiftLint** — Fixed `for_where`, `line_length`, `statement_position`, `unused_enumerated`, `non_optional_string_data_conversion`; removed `force_unwrapping` config warning.
- **Bridge** — Clarified local-only use; no local path exposure in docs.

### Fixed

- Indentation in SceneManager `applyScene`.

---

## [1.0.1]

Initial public release. See README for full feature set.
