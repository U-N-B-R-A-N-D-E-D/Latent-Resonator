# Changelog

All notable changes to Latent Resonator are documented here.

## [Unreleased] — 2026-07-27

Working-tree summary ahead of owner commit. Shipped v2 pull-render architecture (`GraphAudioEngine` → `ExecutionPlan` → `DSPNode`, native `PatchCanvasView`); this entry closes the perimeter roadmap (`docs/ROADMAP_PERIMETER_2026-07-21.md`) and documents concurrent canvas/PERFORM work.

### Perimeter engine wiring

- **`SpectralAnalyzerNode`** — Conforms `DSPNode`; participates in `ExecutionPlan` (live centroid/flatness/flux for cybernetic feedback).
- **`AudioInputNode`**, **`MarkovSequencerNode`**, **`GestureRecorderNode`** — Wired into execution + UI; control-node category override fix in graph validation/factory.
- **`MacroNode.render`** — Honors external `portMappings` (macro chaining / external-audio input slots).
- **`ExecutionPlan.Step.controls`** — Removed; single control contract via `ControlGraphEvaluator` + `setParam`.
- **`CoreMLInference.swift`** — Header marked **ARCHIVED / ROADMAP**; canonical inference remains `ACEStepBridge` + Python server.
- **`presetFallbackProfiles`** — Removed from `Config/Constants.swift` (dead configuration).

### Canvas (PATCH)

- Pan/zoom/drag architecture aligned with a Max-style editing model: undo/redo (`GraphHistory`), multi-select and marquee, subgraph clipboard, cable re-route, snap/fit on `PatchCanvasView`.
- Macro expand/collapse via **`MacroCard`** double-click gesture.

### PERFORM

- Curated exposure pipeline for perform controls; fixed-dense pagination in **`PerformLayoutEngine`**.
- Generic parameter lock (p-lock) with scene-morph gating; macro VU metering and envelope curve views where exposed.

### Fixed

- **`SpectralPipeline`** — FFT overlap buffer overflow (SIGSEGV) under extreme frame sizes.
- Control-node misclassification in graph validation (Markov/Gesture routing).
- Macro external-input routing order relative to internal plan steps.

### Tests

~12 new or registered suites in `LatentResonatorTests`, including: `SpectralAnalyzerNodeTests`, `AudioInputNodeTests`, `MarkovSequencerNodeTests`, `GestureRecorderNodeTests`, `MacroNodeRoutingTests`, `MacroCardGestureTests`, `AudioPipelineValidatorTests`, `GraphHistoryIntegrationTests`, `SubgraphClipboardTests`, `ExposureCurationTests`, `SpectralPipelineOverlapAddTests`, `SceneManagerCrossfadeTests` (plus `GraphNodeParamTests`, `ParameterRouterTests`, `MacroMixerControllerTests`, `InferenceParamsTests`, `NodeGraphExpandTests`, `MaterialityTests`, `ApplyMacroStepLocksTests`).

### Notes

- Agent docs: `.cursor/AGENTS.md` v1.x file references updated to live v2 graph paths (2026-07-27 pass).
- Superseded RFC docs unchanged; code under `LatentResonator/LatentResonator/Graph/` remains source of truth.

---

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
- Full v2.0 feature set documented in `docs/ARCHITECTURE_v2_NODAL.md` *(superseded RFC — not the shipped pull-render architecture; see 2026-07 note below)*
- Gap analysis between code and docs: `docs/GAP_ANALYSIS_2026-04-03.md`
- **2026-07 note:** the WKWebView/React Flow PATCH mode and `AudioGraphMapper` described above were abandoned before shipping. The v2.0 that actually shipped (commit `2c2d62a`, 2026-05-17, "Complete migration to lane-free node-graph architecture") is pull-render + native canvas (`GraphAudioEngine` → `ExecutionPlan` → `DSPNode`, `PatchCanvasView`, CANVAS \| PERFORM modes) and never got its own changelog entry. Superseded docs: `docs/ARCHITECTURE_v2_NODAL.md`, `docs/E2E_COHESION_ANALYSIS.md`, `docs/IMPLEMENTATION_VERIFICATION.md` — **source of truth:** `LatentResonator/LatentResonator/Graph/NodeGraph.swift`, plus `README.md` and `.cursor/skills/v2-node-graph/SKILL.md`.

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
