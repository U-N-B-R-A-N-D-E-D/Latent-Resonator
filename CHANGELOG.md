# Changelog

All notable changes to Latent Resonator are documented here.

## [2.0.0] — 2026-04-03

### Added — Major Architecture Evolution

**Three-Mode Interface:**
- **PATCH mode** — Visual node graph editor (React Flow in WKWebView) for dataflow programming
- **SETUP mode** — Full mixer with real-time audio visualizer (waveform + FFT in DRIFT FIELD)
- **PERFORM mode** — Auto-generated control surface from exposed parameters

**Shell Integration:**
- **Terminal Console** — Real-time Python bridge logs in PATCH view (Mecha Metal phosphor green aesthetic)
- **Dynamic sub-process management** — App spawns and controls Python bridge automatically
- **Performance mode flags** — `--low-latency` flag passed to bridge in PERFORM mode (caps inference steps to 6)
- **Status indicators** — RUNNING / LAUNCHING / ERROR states visible in terminal
- **Auto-scroll toggle** — Follow latest output or scroll freely through 100-line history

**Audio Visualizer:**
- **Canvas 2D + WebAudio integration** — Waveform and FFT display in SETUP mode's DRIFT FIELD
- **Touch-reactive** — Still controls Texture/Chaos macros via drag
- **Lightweight implementation** — ~20KB memory, 30fps throttled updates
- **Fade trails** — Visual feedback of parameter changes
- **`ResonatorLane.waveformSnapshot`** — 256-sample downsampled buffer for visualizer

**v2.0 Node Graph Architecture (Foundational):**
- **`NodeGraph`** — Source of truth for all graph state, validation, serialization
- **`MacroNode`** — Encapsulated subgraphs (will replace LanePresets in Phase 6)
- **`ControlGraphEvaluator`** — 60Hz control-rate signal evaluation
- **`WebViewBridge`** — Bidirectional Swift ↔ JavaScript message protocol
- **`PatchViewCoordinator`** — WKWebView integration for React Flow canvas
- **`PerformLayoutEngine`** — Auto-generates PERFORM control surface from exposedControls

**Bridge Improvements:**
- **`BridgeProcessManager.realtimeLog`** — Publishes stdout/stderr for terminal UI
- **`launchServer(performanceMode: Bool)`** — Dynamic flag injection
- **`LOW_LATENCY_MODE`** — Server-side logic to cap inference steps

### Changed

- **RootView** — Now manages 3-mode cycle (SETUP → PATCH → PERFORM) with Tab key
- **LatentResonatorView** — Replaced traditional XY pad with AudioVisualizerXYPad
- **ace_bridge_server.py** — Accepts `--low-latency` flag, caps num_steps when enabled
- **Tab shortcut** — Cycles through 3 modes instead of toggling between 2

### Technical Debt Paid

- **Eliminated legacy references** — Removed all mentions of "2-mode" system from docs
- **Project structure updated** — Added Graph/, WebView/, new View components
- **Skills aligned** — Updated architecture and bridge skills with current patterns
- **Version bump** — README badge updated from v1.0.3 to v2.0.0

### Notes

- v2.0 Node Graph is **foundational work** — PATCH mode visual canvas in early implementation
- Macro-node migration (Phase 6) will replace hardcoded LanePresets with expandable graph blocks
- Full v2.0 feature set documented in `docs/ARCHITECTURE_v2_NODAL.md`
- Gap analysis between code and docs: `docs/GAP_ANALYSIS_2026-04-03.md`

---

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
