# Latent Resonator Architecture Expert

**Trigger phrases:** "add feature", "implement", "audio processing", "DSP", "neural inference", "node graph", "modulation", "sequencer", "spectral", "whitepaper", "recursive feedback"

**Purpose:** Orient AI agents to the *current* architecture before they touch it. Latent Resonator finished its v1.x → v2.0 migration: fixed per-lane topology is gone, the node graph is the only architecture. This file describes what exists in code today. If a doc under `docs/` contradicts this file or the source, the doc is stale — code is truth.

---

## LOAD THIS SKILL WHEN

- User wants to add/modify audio processing features
- User mentions "feedback loop", "inference", "spectral", "node"
- User needs to understand system architecture before making a change
- User is debugging audio issues, threading problems, or performance

For anything specifically about the render engine (`DSPNode`, `GraphAudioEngine`, `ExecutionPlan`) or adding a new node type, load `v2-node-graph` alongside this — it has the copy-paste pattern.

---

## STEP 1: WHAT THIS APP IS, IN ONE SCREEN

- A single `NodeGraph` (`Graph/NodeGraph.swift`) is the source of truth for every node, edge, exposed control, and macro binding.
- `NeuralEngine` (`NeuralEngine.swift`) owns the `NodeGraph`, the `AVAudioEngine` (used only for I/O — see `v2-node-graph`), the `ACEStepBridge`, `SceneManager`, `SequencerEngine`, and MIDI/OSC input routing.
- Two UI modes, not three: **CANVAS** (`RootView` → `PatchCanvasView`, native SwiftUI patch editor + live performance in one surface, gated by a lock toggle) and **PERFORM** (`PerformanceMotherbaseView`, scenes/step-grid/crossfader). See `enum AppMode` in `RootView.swift`.
- Real-time audio runs through a **pull-render graph**: one `AVAudioSourceNode` walks a pre-built `ExecutionPlan` calling `DSPNode.render(...)` on each participating node. Full detail in the `v2-node-graph` skill.
- Neural inference (ACE-Step 1.5) runs out-of-process, over HTTP, via `ace_bridge_server.py` + `ACEStepBridge.swift`. It is async and optional — the app is a complete instrument without it (DSP-only passthrough).

**Ask yourself before changing anything:**

1. **Which clock does this touch?** Real-time DSP path (`DSPNode.render`, <5ms budget) vs. async inference (`Task`, seconds) vs. UI/control (`@Published`, main thread).
2. **Does a file for this already exist?** This codebase has been through several rewrites; half-migrated or now-legacy code paths exist. Check "STEP 2" below before assuming a fresh implementation is needed.
3. **Does this require whitepaper alignment?** Load the `whitepaper-alignment` skill if you're adding a research-flavored feature.

---

## STEP 2: FILE MAP (CURRENT, NOT ASPIRATIONAL)

```
Config/
  Constants.swift          — ALL parameters, ranges, defaults, design tokens (LRConstants.DS)
  PerformanceState.swift   — Scenes, step grid, P-Locks, persistence
  ParameterRouter.swift    — MIDI CC mapping
  LaneRole.swift, PatternChain.swift, TopologyTemplates.swift

Core (top-level LatentResonator/):
  NeuralEngine.swift        — Owns NodeGraph, GraphAudioEngine, ACEStepBridge, scenes, MIDI/OSC
  SequencerEngine.swift     — Step timer / advance logic across all SequencerNodes
  SceneManager.swift        — Scene bank, apply/capture, crossfade
  ModulationEngine.swift    — Polyadic modulation (Agitation, Control, Peak) — v1.x-era, still used
  SignalGenerator.swift     — Excitation sources (noise, sine, Koenig seed, silence)
  KoenigSeedGenerator.swift — Euclidean rhythm E(k,n) generator
  SpectralProcessor.swift   — Monolithic FFT chain — used internally by SpectralChainNode only
  CircularAudioBuffer.swift — Lock-free SPSC ring buffer (os_unfair_lock-guarded positions)

Neural bridge:
  ACEStepBridge.swift       — Swift async HTTP client (health polling + /infer)
  BridgeProcessManager.swift — Python server process lifecycle (venv, launch, logs)
  CoreMLInference.swift     — On-device VAE/DiT pipeline; **not instantiated** — canonical inference is `ACEStepBridge` + `ace_bridge_server.py` (see file header)
  WAVCodec.swift            — WAV encode/decode for HTTP transport
  Scripts/ace_bridge_server.py — Python server; ACEStepWrapper wraps the real ACE-Step 1.5 pipeline

Graph/ (the v2.0 engine — see the `v2-node-graph` skill for the render pipeline)
  NodeGraph.swift, GraphNode.swift, GraphEdge.swift, MacroNode.swift, ImplicitGraphBuilder.swift
  GraphHistory.swift, NodeGraphStore.swift, ControlGraphEvaluator.swift (60Hz CV routing — wired in NeuralEngine)
  ImplicitGraphBuilder.swift — clones `seed-feedback-flat` + overlays `LanePreset` params for MacroNode factory presets
  Engine/
    DSPNode.swift, GraphAudioEngine.swift, ExecutionPlan.swift, BufferPool.swift, AudioBuffer.swift
  Nodes/
    SourceNodes.swift, SpectralNodes.swift, FilterEffectNodes.swift, NeuralNodes.swift,
    ControlNodes.swift, RoutingNodes.swift, SequencerNodes.swift, AnalysisNodes.swift, ReverbNode.swift

Views/
  LRComponents.swift             — Reusable SwiftUI primitives (LRToggle, LRParamSlider, ...)
  Patch/                          — PatchCanvasView (native canvas), CableLayer, NodeCardFactory, PatchTypes
  PerformanceMotherbaseView.swift — PERFORM mode: scenes, step grid, crossfader
  PerformLayoutEngine.swift       — Auto-layout for exposedControls in PERFORM
  RetroKnob.swift, LatentXYPad.swift, SceneCrossfaderView.swift, TerminalConsoleView.swift
  AudioVisualizerXYPad.swift      — WKWebView waveform/FFT visualizer used inside PERFORM
                                     (unrelated to the patch canvas — do not confuse the two)
  MacroBindingsPanel.swift, RecipeBanner.swift

(WebViewBridge.swift, PatchViewCoordinator.swift, AudioVisualizerHTML.swift, and the bundled
 PatchEditor React/TypeScript project — the pre-native-canvas WKWebView patch editor — have
 were removed from the repo entirely on 2026-07-27 (recoverable from git history).
 Don't recreate them.)
```

### For Audio/DSP Features (new node types)

Load the `v2-node-graph` skill. Copy `DelayLineNode` in `Graph/Nodes/FilterEffectNodes.swift`.

### For Neural Inference

- `ACEStepBridge.swift` (HTTP client, matches `Scripts/ace_bridge_server.py` field-for-field)
- `Graph/Nodes/NeuralNodes.swift` — `FeedbackLoopNode` (the only neural-adjacent `DSPNode`) and `ACEStepInferenceNode` (parameter surface)
- `CircularAudioBuffer.swift` (audio thread ↔ inference `Task` communication)
- Load the `python-bridge` skill for the Python side.

### For Modulation / Legacy Control System

- `ModulationEngine.swift` (polyadic modulation, predates the node graph's own control-rate nodes in `Graph/Nodes/ControlNodes.swift`; both currently exist — check which one a given feature actually reads before adding to either)
- `Config/ParameterRouter.swift` (MIDI CC mapping)

### For UI

- `Views/LRComponents.swift`, `Views/Patch/*`, `Views/PerformanceMotherbaseView.swift`, `Config/Constants.swift` (`LRConstants.DS` design tokens)

---

## STEP 3: ARCHITECTURAL CONSTRAINTS

### Constraint 1: Dual-Clock Separation

**Real-time DSP path** (anything reached from `DSPNode.render`):

```swift
✓ Pre-allocate all buffers at init
✓ @inline(__always) for hot per-sample functions
✓ No heap allocations, no locks held across the call, no blocking I/O, no print
✓ Use vDSP for vector operations
✓ Parameter smoothing (1-pole LP) for anti-click on abrupt changes
```

**Async inference path** (anything reached from a `Task` talking to `ACEStepBridge`):

```swift
✓ Task(priority: .utility) or similar, spawned by a trigger condition — never an
  unconditional loop in init() that polls every N ms
✓ Snapshot parameters into a Sendable struct before crossing into the Task
✓ CircularAudioBuffer for audio-thread ⇄ inference-thread handoff
✓ Update @Published state via `await MainActor.run { ... }`
```

See the `audio-thread-safety` skill for the full real-time checklist and the current `os_unfair_lock_trylock` plan-swap pattern used by `GraphAudioEngine`.

### Constraint 2: Constants-First Development

Before adding any parameter: check `Config/Constants.swift` (`LRConstants`) first. If it's missing, add it there with type, range, default, and a comment — never a bare literal scattered through node code.

### Constraint 3: Design System Compliance

All UI code uses `LRConstants.DS.*` tokens (fonts, colors, spacing) and `LRComponents` primitives (`LRToggle`, `LRParamSlider`, `LRSectionHeader`, ...). No hardcoded `Color`/`Font`/`CGFloat` in view code.

### Constraint 4: No New Files (10x Check Rule)

Before creating a new file, verify: does this belong in an existing file (a new node type still goes in the matching `Graph/Nodes/*.swift` file, not a new one)? Is this already implemented but needs fixing? Could this be a private extension instead of a new type? Consult this file and `v2-node-graph` before assuming nothing exists yet.

---

## STEP 4: THREADING / SAFETY CHECKLISTS

### Audio Thread (inside `DSPNode.render`)

- [ ] No allocations, no `Array`/`Dictionary`/`String` construction
- [ ] All buffers pre-allocated at init
- [ ] Parameters read via `getParam`/computed vars smoothed with 1-pole LP where abrupt changes would click
- [ ] No NaN/Inf propagation — clamp/guard before writing `output`
- [ ] Cross-thread communication is lock-free (`CircularAudioBuffer`) or `os_unfair_lock_trylock`, never a blocking lock

### Main Thread / Combine

- [ ] `@Published` properties written on the main thread (or `MainActor.run` from a `Task`)
- [ ] Audio thread never reads `NodeGraph`/`@Published` state directly — it reads through the frozen `ExecutionPlan` snapshot
- [ ] Plan rebuilds go through `NeuralEngine.rebuildAudioGraphIfNeeded()` → `GraphAudioEngine.adopt(_:)`, never ad-hoc `AVAudioEngine.connect`/`.detach` calls on graph-internal nodes

### Constants / Design System

- [ ] No magic numbers — `LRConstants`
- [ ] No hardcoded UI values — `LRConstants.DS` + `LRComponents`

---

## STEP 5: WHITEPAPER ALIGNMENT

If implementing a whitepaper-derived concept (recursive formula, Koenig seed, spectral phases, entropy/granularity), cite the section in a comment (`// Whitepaper §4.2.2 — ...`) and load the `whitepaper-alignment` skill to check the feature actually serves the research goals rather than being generic feature drift.

---

## MARKED DELETED / SUPERSEDED — DO NOT RESURRECT

- **`ResonatorLane`** — replaced by `MacroNode` + flat `Graph/Nodes/*` node types.
- **`AudioGraphMapper`** — replaced by `GraphAudioEngine` + `ExecutionPlan` (atomic plan swap).
- **WKWebView / React-Flow patch editor** (`PatchViewCoordinator.swift`, `WebViewBridge.swift`, `AudioVisualizerHTML.swift`, the bundled `PatchEditor` project) — replaced by native `PatchCanvasView`; removed from the Xcode target entirely.
- **`LatentResonatorView.swift`, `LaneStripView.swift`** — deleted; SETUP mode no longer exists (folded into CANVAS/PERFORM).
- Full detail and the reasoning lives in the `v2-node-graph` skill — read it before implementing anything graph-shaped.

---

## FINAL CHECKLIST BEFORE SUBMITTING

- [ ] Read the actual current file before modifying it (things move fast in this repo; comments and docs lag)
- [ ] No new files created unless the `v2-node-graph` "adding a node" checklist genuinely requires one (it usually doesn't — add to the existing category file)
- [ ] All parameters in `Constants.swift`; all UI values use design tokens
- [ ] No allocations/locks/blocking calls in `DSPNode.render`
- [ ] Whitepaper citations in comments where applicable
- [ ] Builds clean: `xcodebuild -project LatentResonator/LatentResonator.xcodeproj -scheme LatentResonator -destination 'platform=macOS' build`

**The node graph is the architecture, not a migration target. Build on what's there.**
