# Latent Resonator v2.0 — Dataflow Architecture

> **Superseded.** This RFC specifies a WKWebView/React-Flow canvas and an `AudioGraphMapper`-rebuilds-AVAudioEngine model. Neither was implemented as written. **Source of truth:** `LatentResonator/LatentResonator/Graph/` (start at `NodeGraph.swift`) — pull-render + native canvas (`GraphAudioEngine` → `ExecutionPlan` → `DSPNode`, `PatchCanvasView`, CANVAS \| PERFORM modes). See also `README.md` and `.cursor/skills/v2-node-graph/SKILL.md`.

## Technical Specification: Fixed-Topology to Node-Graph Migration

**Version**: 0.2
**Date**: 2026-04-02
**Status**: RFC (Request for Comments)

---

## 1. System Overview

Latent Resonator v2.0 replaces the fixed signal-chain topology with a **dataflow programming model**. Users construct, modify, and perform arbitrary signal processing graphs through visual node interconnection while the native audio engine (AVAudioEngine + Accelerate vDSP + ACE-Step 1.5 inference bridge) handles all real-time DSP.

### 1.1 Design Constraints

**DC-1: Native Audio Path.** All audio processing remains in Swift/C (AVAudioEngine, Accelerate framework). The node editor is a visual control surface only — it never touches audio buffers.

**DC-2: Dual-Clock Architecture.** Real-time DSP path (< 5ms latency) and async neural inference path (2–30s per cycle) operate independently. The graph model must represent both without conflating them.

**DC-3: Strict Mode Separation.** Three UI modes map to three distinct cognitive tasks:
- **PATCH** — Graph topology editing (node canvas). No real-time performance controls.
- **SETUP** — Mixer-level overview (volumes, mutes, bridge status). Read-only graph projection.
- **PERFORM** — Sequenced performance surface (step grid, P-Locks, crossfader). Only exposed parameters visible.

**DC-4: Progressive Disclosure.** Factory presets ship as pre-wired macro-nodes. Default view shows collapsed blocks. Double-click expands to reveal individual processing stages.

**DC-5: Backward Compatibility.** v1.x behavior is a strict subset of v2.0. Users who never open PATCH mode experience zero functional regression.

### 1.2 Key Capabilities (New in v2.0)

| Capability | Description |
|-----------|-------------|
| Arbitrary topology | User-defined signal routing replaces fixed 13-stage chain |
| Cross-lane modulation | Spectral features from Lane A can modulate parameters on Lane B |
| Exposed Controls | Any node parameter can be promoted to PERFORM view |
| Auto-generated control surface | PERFORM layout dynamically assembles from exposed parameters |
| Macro-nodes | Encapsulate subgraphs into reusable, shareable blocks |
| Control-rate signals (CV) | Digital control voltage [0..1] routable between any nodes |
| Markov sequencer | Probabilistic step transitions replace static step grids |
| External audio input routing | Mic/line input as excitation source for neural inference |

---

## 2. High-Level Architecture

```
┌──────────────────────────────────────────────────────────────┐
│                     macOS Application (.app)                  │
│                                                              │
│  ┌───────────────────────┐   ┌─────────────────────────────┐ │
│  │    SwiftUI Shell       │   │   WKWebView (React Flow)    │ │
│  │                        │   │                             │ │
│  │  ┌──────────────────┐  │   │  ┌───────────────────────┐  │ │
│  │  │  SETUP View      │  │   │  │  PATCH View           │  │ │
│  │  │  (mixer strips)  │  │   │  │  (node canvas)        │  │ │
│  │  └──────────────────┘  │   │  │  Nodes + Edges        │  │ │
│  │  ┌──────────────────┐  │   │  │  Zoom / Pan / Groups  │  │ │
│  │  │  PERFORM View    │  │   │  │  Minimap              │  │ │
│  │  │  (auto-generated │  │   │  └───────────────────────┘  │ │
│  │  │   control surface)│  │   │                             │ │
│  │  └──────────────────┘  │   │                             │ │
│  └───────────┬────────────┘   └──────────────┬──────────────┘ │
│              │                               │                │
│              │     WKScriptMessageHandler     │                │
│              │  ◄──────────────────────────►  │                │
│              │     (bidirectional JSON)       │                │
│              │                               │                │
│  ┌───────────┴───────────────────────────────┴──────────────┐ │
│  │                  Graph Engine (Swift)                      │ │
│  │                                                           │ │
│  │  NodeGraph ←→ NeuralEngine ←→ ResonatorLane[]             │ │
│  │      │              │               │                     │ │
│  │      │         AVAudioEngine   SpectralProcessor          │ │
│  │      │              │          SignalGenerator             │ │
│  │      │              │          ModulationGraph             │ │
│  │      │              │                                     │ │
│  │      │         ACEStepBridge ──► Python Server             │ │
│  │      │              │          (ace_bridge_server.py)      │ │
│  │      │              │          ACE-Step 1.5 + PyTorch      │ │
│  └──────┴──────────────┴─────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────┘
```

### 2.1 Technology Decisions

| Decision | Choice | Rationale |
|---------|--------|-----------|
| Node editor runtime | WKWebView (embedded) | Ships with macOS, ~30MB overhead, Apple-maintained WebKit engine |
| Node editor library | React Flow (xyflow, MIT) | Most mature web node editor. TypeScript, custom nodes/edges, minimap, 100k+ GitHub stars |
| JS build | Vite → static bundle | Compiled once, loaded from app bundle. No runtime dependency on npm/node |
| JS ↔ Swift bridge | WKScriptMessageHandler | Native Apple API. ~1–2ms message latency. Main-thread delivery |
| Audio engine | AVAudioEngine + Accelerate | Unchanged from v1.x. Zero-copy DSP path. < 5ms latency |
| Neural inference | Python + PyTorch + ACE-Step 1.5 | Unchanged from v1.x. HTTP bridge on localhost:8976. Shell-managed sub-process with performance flags. |

**Shell Integration (v2.0):**
- Python bridge spawned automatically via `Foundation.Process`
- Dynamic command-line arguments (`--low-latency` for PERFORM mode)
- Real-time terminal console in PATCH view (Mecha Metal aesthetic)
- Performance mode caps inference steps to 6 for low-latency

**Rejected alternatives:**
- *SwiftUI-native node editor*: No mature library exists. Estimated 6–12 months to build from scratch (Bézier cables, infinite zoom, hit testing, grouping, minimap).
- *Electron*: +200MB binary overhead, separate process model complicates audio latency.
- *Tauri*: Requires Rust bridge layer. Adds build complexity without clear benefit over WKWebView for single-app distribution.

---

## 3. Node Taxonomy

### 3.1 Categories

Each node belongs to a color-coded category. Colors derive from the existing `LRConstants.DS` design system.

| Category | Color Token | Description |
|----------|------------|-------------|
| **SOURCE** | `neonTurquesa` | Signal generators and audio input |
| **SPECTRAL** | `paramPhase` (purple) | FFT-domain processing |
| **FILTER** | `info` (cyan) | Analog-modeled filtering |
| **EFFECT** | `paramDelay` (blue) | Delay, bitcrush, waveshaping |
| **NEURAL** | `neonAmbar` | ACE-Step inference and AI parameters |
| **CONTROL** | `trigLock` (yellow) | LFOs, envelopes, sequencers, Markov chains |
| **ROUTING** | `textPrimary` (white) | Mixers, splitters, feedback paths |
| **ANALYSIS** | `success` (green) | Spectral feature extraction, scopes |

### 3.2 Signal Types and Port Compatibility

Four signal types flow between nodes. Ports only accept connections of matching type.

| Type | Visual | Bit Depth / Rate | Description |
|------|--------|-------------------|-------------|
| `audio` | Thick solid line, source-color | 32-bit float, 48kHz | Audio signal buffer |
| `control` | Thin dashed line, yellow | 32-bit float, ~60Hz | Continuous parameter modulation [0..1] or [-1..1] |
| `gate` | Thin solid line, red | Boolean, event-driven | Binary on/off triggers, clocks, resets |
| `text` | Thin double line, amber | UTF-8 string, event-driven | Prompt strings for neural inference |

Port shapes: `audio` = circle (8px), `control` = square (6px), `gate` = diamond (6px), `text` = rounded rect (8×6px).

Connection validation is enforced both in JS (immediate visual feedback) and Swift (authoritative check before audio graph reconfiguration).

### 3.3 Complete Node Catalog

#### 3.3.1 SOURCE Nodes

**OSCILLATOR** — Maps to `SignalGenerator.swift`
```
Params:  waveform: enum [SINE|SAW|SQUARE|TRI|PULSE]
         frequency: Float [20..2000 Hz] (default: 110)
         pulseWidth: Float [0.1..0.9] (default: 0.5)
Ports:   OUT → audio
         FREQ ← control (frequency modulation)
         PW ← control (pulse width modulation)
```

**KOENIG SEED** — Euclidean rhythm generator. Bjorklund algorithm E(k,n) with Gaussian noise tails.
```
Params:  pulses: Int [1..16] (default: 5)
         steps: Int [2..32] (default: 13)
         noiseTailMs: Float (default: 20.0)
         amplitude: Float (default: 1.0)
Ports:   OUT → audio
         TRIG ← gate (re-seed trigger)
```

**NOISE** — White noise broadband excitation.
```
Params:  amplitude: Float [0..1] (default: 1.0)
Ports:   OUT → audio
```

**SILENCE** — Null signal. Forces pure hallucination from neural model latent priors.
```
Ports:   OUT → audio
```

**AUDIO INPUT** — Live mic/line input. Reads from AVAudioEngine hardware input tap via shared `CircularAudioBuffer`.
```
Params:  gain: Float [0..2] (default: 1.0)
Ports:   OUT → audio
```

**FEEDBACK TAP** — Reads from a NEURAL INFERENCE node's output buffer. Closes the recursive loop (whitepaper §3.3: S_{i+1} = ACE(S_i + N(μ,σ), P, γ)).
```
Ports:   OUT → audio
         FB_IN ← audio (connect from inference output)
```

#### 3.3.2 SPECTRAL Nodes

Decomposition of the 14-stage `SpectralProcessor.swift` into individual nodes:

**FFT ANALYSIS** — Hann window + Forward FFT (vDSP_fft_zrip).
```
Params:  fftSize: enum [512|1024|2048] (default: 1024)
Ports:   IN ← audio
         OUT → spectrum
```

**SEMANTIC EQ** — 4-band spectral gain. Profiles derived from prompt keyword matching against `LRConstants.semanticProfiles` dictionary (80+ entries).
```
Params:  low: Float [0..3] | lowMid: Float [0..3]
         highMid: Float [0..3] | high: Float [0..3]
         profile: String (auto-derived from prompt keywords)
Ports:   IN ← spectrum | OUT → spectrum
         PROFILE ← control (semantic vector override)
```

**SPECTRAL SATURATION** — Per-band harmonic enrichment in frequency domain.
```
Params:  drive: Float [0..1] (default: 0.5)
Ports:   IN ← spectrum | OUT → spectrum
         DRIVE ← control
```

**SPECTRAL NOISE** — Entropy-driven colored noise injection in spectral domain.
```
Params:  amount: Float [0..100] (default: 35)
Ports:   IN ← spectrum | OUT → spectrum
         AMOUNT ← control
```

**SPECTRAL MEMORY** — Persistent magnitude array. Recursive spectral drift accumulator. Frequencies that persist across iterations are reinforced.
```
Params:  coefficient: Float [0..1] (default: 0.85)
Ports:   IN ← spectrum | OUT → spectrum
         COEFF ← control
```

**SPECTRAL GRANULARITY** — Microsound window sparsification (granular synthesis in frequency domain).
```
Params:  window: Float [0..100] (default: 45)
Ports:   IN ← spectrum | OUT → spectrum
         WINDOW ← control
```

**SPECTRAL FREEZE** — Captures and sustains a spectral magnitude snapshot.
```
Params:  freeze: Bool (default: false)
         blend: Float [0..1] (default: 0.9)
Ports:   IN ← spectrum | OUT → spectrum
         FREEZE ← gate | BLEND ← control
```

**IFFT SYNTHESIS** — Inverse FFT. Overlap-add reconstruction to time domain.
```
Ports:   IN ← spectrum
         OUT → audio
```

#### 3.3.3 FILTER Nodes

**LADDER FILTER** — 4-pole 24dB/oct Moog-style (Huovilainen improved model).
```
Params:  mode: enum [LP|HP|BP]
         cutoff: Float [20..20000 Hz] (default: 20000)
         resonance: Float [0..0.95] (default: 0.0)
Ports:   IN ← audio | OUT → audio
         CUTOFF ← control | RESO ← control
```

**COMB FILTER** — Parallel comb with prime-number delay spacing. Produces inharmonic metallic partials.
```
Params:  baseDelay: Int samples (default: 137, prime)
         feedback: Float [0..0.95] (default: 0.78)
         taps: Int (default: 5)
Ports:   IN ← audio | OUT → audio
         FEEDBACK ← control
```

**TUNABLE RESONATOR** — Pitched comb filter. Delay length derived from MIDI note → frequency → sample count.
```
Params:  note: Float [24..96 MIDI] (default: 60, C4)
         decay: Float [0..0.99] (default: 0.7)
Ports:   IN ← audio | OUT → audio
         NOTE ← control | DECAY ← control
```

#### 3.3.4 EFFECT Nodes

**BIT CRUSHER** — Bit-depth quantization.
```
Params:  depth: Float [2..16 bits] (default: 14)
Ports:   IN ← audio | OUT → audio
         DEPTH ← control
```

**WAVESHAPER** — Analog saturation model. Continuous morph between transfer functions: clean → tube → transistor → diode.
```
Params:  mode: enum [CLEAN|TUBE|XSTR|DIODE]
         morph: Float [0..1] (default: 0.0)
Ports:   IN ← audio | OUT → audio
         MORPH ← control
```

**DELAY LINE** — Recursive delay with configurable feedback.
```
Params:  time: Float [0.01..2.0 s] (default: 0.25)
         feedback: Float [0..0.95] (default: 0.6)
         mix: Float [0..1] (default: 0.4)
Ports:   IN ← audio | OUT → audio
         TIME ← control | FB ← control | MIX ← control
```

#### 3.3.5 NEURAL Nodes

**ACE-STEP INFERENCE** — Core neural inference node. Sends audio buffer to Python bridge server (`ace_bridge_server.py`), receives processed audio from ACE-Step 1.5 model (PyTorch + MPS/CUDA/CPU).
```
Params:  cfg: Float [3..20] (default: 10.0)         — classifier-free guidance
         steps: Int [4..100] (default: 8)             — diffusion denoising steps
         shift: Float [1..10] (default: 5.0)          — attention allocation weight
         inferMethod: enum [ODE|SDE] (default: ODE)   — deterministic vs stochastic
         denoise: Float [0..1] (default: 1.0)         — 0=DSP-only, 1=full neural
         prompt: String
Ports:   IN ← audio (capture buffer)
         OUT → audio (feedback buffer)
         CFG ← control | DENOISE ← control
         SHIFT ← control | STEPS ← control
         PROMPT ← text
Status:  Shows bridge connection state, iteration count, cycle time
```

**PROMPT ENGINE** — Spectral-flatness-conditioned prompt phase evolution (whitepaper §4.2.2). Transitions between prompt phases based on signal entropy state.
```
Params:  phase1: String | phase2: String | phase3: String
         evolution: Bool (default: true)
         phase2Threshold: Float (default: 0.35)  — flatness trigger
         phase3Threshold: Float (default: 0.65)  — flatness trigger
Ports:   OUT → text
         FLATNESS ← control (drives phase transitions)
         PHASE ← control (manual override: 1, 2, or 3)
```

**INPUT STRENGTH** — Controls blend ratio between fresh excitation and recursive feedback state.
```
Params:  strength: Float [0..1] (default: 0.6)
         autoDecay: Bool (default: false)
         target: Float (default: 0.45)
         iterations: Float [1..50] (default: 10)
Ports:   OUT → control
         DECAY_TRIG ← gate
```

#### 3.3.6 CONTROL Nodes

**AGITATION (LFO)** — Multi-waveform modulator with polyadic state. Each output connection maintains independent phase and RNG state (from `ModulationEngine.swift`).
```
Params:  waveform: enum [SINE|TRIANGLE|SAW|SQUARE|SAMPLE_AND_HOLD|RANDOM_WALK]
         rate: Float [0.01..10 Hz] (default: 0.1)
         depth: Float [0..1] (default: 0.0)
Ports:   OUT → control
         RATE ← control (meta-modulation)
         DEPTH ← control (meta-modulation)
```

**PEAK (ENVELOPE)** — Triggered envelope generator with probability gate.
```
Params:  attack: Float [1..5000 ms] (default: 10)
         hold: Float [0..5000 ms] (default: 50)
         decay: Float [1..10000 ms] (default: 200)
         probability: Float [0..1] (default: 1.0)
Ports:   OUT → control
         TRIG ← gate
```

**MANUAL CONTROL** — Static value with per-connection slew rate. Replaces hardcoded macro parameters.
```
Params:  value: Float [0..1] (default: 0.5)
         slew: Float [0..5 s] (default: 0.1)
Ports:   OUT → control
         VALUE ← control (meta-modulation)
```

**STEP SEQUENCER** — 16-step sequencer with per-step parameter locks, trig types (Note/Lock/OneShot/Skip), probability gates, and configurable chain length.
```
Params:  steps: Int (default: 16)
         chainLength: Int [1..16] (default: 16)
         advanceMode: enum [ITERATION|TIME|MANUAL]
         bpm: Int [30..300] (default: 120, TIME mode only)
Ports:   VALUE → control (current step parameter value)
         GATE → gate (trig on/off per step)
         CLOCK ← gate (external clock input)
         RESET ← gate
```

**MARKOV SEQUENCER** — Probabilistic step sequencer using first-order Markov chain transitions. Replaces deterministic step patterns with stochastic pattern generation.
```
Params:  states: Int [2..16] (default: 8)
         transitionMatrix: Float[][] (row-stochastic, user-editable)
         seed: Int (RNG seed for reproducibility)
         temperature: Float [0..2] (default: 1.0)
              — 0 = deterministic (argmax), 1 = true probabilities, >1 = more random
Ports:   VALUE → control (current state value)
         GATE → gate (state transition event)
         CLOCK ← gate (advance trigger)
         RESET ← gate
         TEMPERATURE ← control
```
**Implementation note:** Transition matrix stored as row-stochastic NxN array. Temperature scales logits before softmax: `p_i = exp(log(m_i)/T) / Σ exp(log(m_j)/T)`. At T→0 the chain becomes deterministic; at T>1 it approaches uniform random.

**SCENE CROSSFADER** — Linear interpolation between two scene parameter snapshots.
```
Params:  position: Float [0..1] (default: 0.0)
         sceneA: Int [1..8] | sceneB: Int [1..8]
         duration: Float [0..10 s] (default: 2.0)
Ports:   OUT → control (interpolated values)
         POSITION ← control
```

#### 3.3.7 ROUTING Nodes

**MIXER** — Summing amplifier. Dynamic input count (2–8 channels).
```
Ports:   IN[] ← audio (dynamic, N inputs)
         OUT → audio
         VOLUME[] ← control (per-input gain)
```

**SPLITTER** — Signal duplicator. One input → N identical outputs.
```
Ports:   IN ← audio
         OUT[] → audio (dynamic, N outputs)
```

**FEEDBACK LOOP** — Closes the recursive inference cycle. Stores last inference result in a 1-second ring buffer, mixes with excitation signal at configurable gain.
```
Params:  gain: Float [0..1] (default: 0.5)
         captureSize: Int samples (default: 48000)
Ports:   IN ← audio (from post-processing chain)
         OUT → audio (to excitation mix)
         GAIN ← control
```
**Constraint:** This is the only node permitted to create a cycle in the graph. The Graph Engine validates that all cycles pass through exactly one FEEDBACK LOOP node.

**MASTER OUTPUT** — DAC output with recording tap and metering.
```
Params:  volume: Float [0..1] (default: 1.0)
         record: Bool (default: false)
Ports:   IN ← audio
         VOLUME ← control
```

#### 3.3.8 ANALYSIS Nodes

**SPECTRAL ANALYZER** — Extracts real-time spectral features from audio. Converts audio signal to control-rate outputs.
```
Ports:   IN ← audio
         CENTROID → control [0..1]    (0=DC, 1=Nyquist — brightness)
         FLATNESS → control [0..1]    (0=tonal, 1=noise-like)
         FLUX → control [0..∞)        (frame-to-frame magnitude change)
```
**This is the key node for cybernetic feedback.** Routing CENTROID → LADDER_FILTER.CUTOFF or FLATNESS → ACE_STEP.CFG creates self-modulating systems where the output shapes the parameters that shape the output.

**SCOPE** — Visual-only node. Renders waveform, spectrum, or XY vectorscope (CRT-style, using existing `LatentXYPad` rendering).
```
Params:  mode: enum [WAVEFORM|SPECTRUM|VECTORSCOPE]
Ports:   IN ← audio
         CTRL ← control (optional overlay)
```

---

## 4. Exposed Controls and Auto-Generated Control Surface

### 4.1 The Exposed Control System

Any parameter on any node can be promoted to the PERFORM view. This is the mechanism that bridges the complexity of the node graph with the immediacy required for live performance.

**Workflow:**
1. In PATCH view, user right-clicks any node parameter.
2. Context menu: **"Expose to Perform Surface"**.
3. User assigns a label (e.g., "MUTATION") and optionally a control type (knob, fader, XY pad, toggle).
4. The parameter appears on the PERFORM view as a hardware-style control.
5. All non-exposed parameters are invisible in PERFORM mode.

```swift
/// Metadata for a parameter promoted to the performance surface.
struct ExposedControl: Identifiable, Codable {
    let id: UUID
    let nodeId: UUID
    let paramId: String
    let label: String                    // User-defined display name
    let controlType: ControlWidget       // knob, fader, xyPad, toggle
    let range: ClosedRange<Float>        // Value range
    let defaultValue: Float
    var midiCC: Int?                     // Optional MIDI CC assignment
    var position: Int                    // Order on the perform surface
}

enum ControlWidget: String, Codable {
    case knob       // RetroKnob (270° sweep)
    case fader      // Vertical slider
    case xyPad      // 2D control (requires two exposed params, X and Y)
    case toggle     // On/off button
    case dropdown   // Enum selector
}
```

### 4.2 Auto-Generated PERFORM Layout

The PERFORM view dynamically assembles its control surface based on the current set of exposed controls. No manual layout required.

**Layout algorithm:**

```
Given: N exposed controls, sorted by user-defined position

1. If N ≤ 4:  Single row of large knobs (size: 96pt)
2. If N ≤ 8:  Two rows of medium knobs (size: 74pt)
3. If N ≤ 16: Grid layout, 4 columns (size: 56pt)
4. If N > 16: Scrollable grid with section grouping by source node

Special cases:
- Two consecutive controls marked as xyPad → render as single XY pad
- Control with range [0,1] and type toggle → render as LRToggle
- Control with enum type → render as LRSegmentPicker
```

**Result:** A user who exposes 2 parameters sees two large, high-resolution knobs. A user who exposes X/Y dimensions of a latent space reduction sees an XY pad. The surface adapts to what the user has decided matters for performance.

### 4.3 Macro Scaling (Multi-Target Exposed Controls)

A single exposed control can drive multiple node parameters simultaneously with independent scaling curves. This enables "meta-parameters" — one knob that coordinates multiple internal changes.

```swift
/// A single exposed control that drives multiple parameters.
struct MacroBinding: Codable {
    let exposedControlId: UUID
    let targets: [MacroTarget]
}

struct MacroTarget: Codable {
    let nodeId: UUID
    let paramId: String
    let inputRange: ClosedRange<Float>   // Range of the macro knob
    let outputRange: ClosedRange<Float>  // Mapped range on the target
    let curve: ScalingCurve              // Linear, exponential, inverted, S-curve
}

enum ScalingCurve: String, Codable {
    case linear             // y = x
    case exponential        // y = x^2
    case logarithmic        // y = log(x)
    case inverted           // y = 1 - x (increase macro → decrease target)
    case sCurve             // y = 3x² - 2x³ (smooth transition)
}
```

**Example:** An exposed control labeled "MUTATION" (0→1) is bound to:
- `ACE_STEP.cfg`: output [10..20], curve: exponential — guidance scale increases
- `LADDER_FILTER.cutoff`: output [20000..200], curve: inverted — filter closes
- `SPECTRAL_NOISE.amount`: output [0..100], curve: linear — entropy increases

One knob turn → three coordinated parameter changes with different response curves.

---

## 5. Cross-Lane Modulation

### 5.1 Spectral Feature Routing

The SPECTRAL ANALYZER node outputs control-rate signals (centroid, flatness, flux). These can be routed to any control-rate input on any node, including nodes on different lanes.

**Example topology — self-modulating feedback system:**
```
Lane A (NOISE → spectral chain → ACE-STEP):
  SPECTRAL ANALYZER outputs:
    centroid ──► Lane B: LADDER_FILTER.CUTOFF
    flatness ──► Lane B: ACE_STEP.CFG

Lane B (SINE → spectral chain → ACE-STEP):
  SPECTRAL ANALYZER outputs:
    flux ──► Lane A: SPECTRAL_NOISE.AMOUNT
```

Each lane's spectral state modulates the other lane's processing parameters. The result is a coupled dynamical system where both lanes co-evolve.

### 5.2 Cross-Lane Feedback Routing

`ResonatorLane` already supports `feedbackSourceLaneId` and `externalFeedbackBuffer`. In v2.0, this becomes a visual cable: the FEEDBACK TAP node on Lane A connects to the FEEDBACK LOOP output on Lane B.

---

## 6. Macro-Nodes (Encapsulation)

### 6.1 Structure

A macro-node is a subgraph packaged as a single node in the parent graph. It stores:
- The internal graph (nodes + edges)
- A list of exposed ports (inputs/outputs visible on the collapsed view)
- A list of exposed parameters (controllable from outside without expanding)

### 6.2 Factory Macro-Nodes (v1.x Preset Migration)

Each `LanePreset` becomes a factory macro-node containing the full 14-stage processing chain pre-wired with preset-specific parameter values.

| Macro-Node | Internal Topology | Key Params Exposed |
|-----------|-------------------|-------------------|
| FERROFLUID DRONE (RFC label: MOOG BASS) | SAW→FFT→SemanticEQ[moog]→...→IFFT→Ladder[LP,200Hz]→Comb[d=137]→... | cfg, feedback, cutoff, warmth |
| SPECTRAL TIDE (RFC label: TB-303 ACID) | SQUARE→FFT→SemanticEQ[acid]→...→IFFT→Ladder[LP,800Hz,res=0.7]→... | cfg, feedback, cutoff, resonance |
| DRUM LANE | KOENIG→FFT→SemanticEQ[percussion]→...→IFFT→Ladder[BP]→... | cfg, feedback, drumVoice, entropy |
| BUCHLA PERC | KOENIG→FFT→SemanticEQ[buchla]→...→IFFT→Ladder[BP]→... | cfg, feedback, cutoff |
| ARP LEAD | SQUARE→FFT→SemanticEQ[lead]→...→IFFT→Ladder[LP]→... | cfg, feedback, cutoff, resonance |
| ROLAND PAD | SINE→FFT→SemanticEQ[pad]→...→IFFT→Ladder[LP]→... | cfg, feedback, warmth |
| NOISE SCAPE | NOISE→FFT→SemanticEQ[air]→...→IFFT→Ladder[HP]→... | cfg, feedback, entropy, granularity |

### 6.3 User-Created Macro-Nodes

**Creation:** Select nodes in PATCH → Cmd+G or right-click → "Encapsulate".
**Auto-port detection:** Cables crossing the encapsulation boundary become exposed ports.
**Export/Import:** Macro-nodes serialize to standalone JSON files for sharing.

### 6.4 Nested Macro-Nodes

Macro-nodes can contain other macro-nodes. Maximum nesting depth: 4 levels (prevents runaway complexity).

---

## 7. Communication Protocol (JS ↔ Swift)

### 7.1 Bridge Architecture

```
React Flow (JS)                        Swift Host
     │                                      │
     │── window.webkit.messageHandlers      │
     │   .patchBridge.postMessage(JSON) ──► │
     │                                      │
     │◄── webView.evaluateJavaScript(       │
     │    "window.patchBridge.receive(...)") │
     │                                      │
```

### 7.2 Messages: JS → Swift

```typescript
// --- Graph Mutations ---

interface AddNodeMsg {
  action: "node.add";
  nodeId: string;           // UUID, generated in JS
  nodeType: string;         // e.g. "oscillator", "ladder_filter", "ace_step"
  position: { x: number; y: number };
  params?: Record<string, number | string | boolean>;
}

interface RemoveNodeMsg {
  action: "node.remove";
  nodeId: string;
}

interface ConnectMsg {
  action: "edge.connect";
  edgeId: string;
  sourceNodeId: string;
  sourcePortId: string;
  targetNodeId: string;
  targetPortId: string;
  signalType: "audio" | "control" | "gate" | "text";
}

interface DisconnectMsg {
  action: "edge.disconnect";
  edgeId: string;
}

// --- Parameter Changes ---

interface ParamSetMsg {
  action: "param.set";
  nodeId: string;
  paramId: string;
  value: number | string | boolean;
}

// --- Exposed Controls ---

interface ExposeParamMsg {
  action: "expose.add";
  exposedId: string;
  nodeId: string;
  paramId: string;
  label: string;
  controlType: "knob" | "fader" | "xyPad" | "toggle" | "dropdown";
  position: number;
}

interface UnexposeParamMsg {
  action: "expose.remove";
  exposedId: string;
}

// --- Macro Scaling Bindings ---

interface MacroBindMsg {
  action: "macro.bind";
  exposedControlId: string;
  targets: Array<{
    nodeId: string;
    paramId: string;
    inputRange: [number, number];
    outputRange: [number, number];
    curve: "linear" | "exponential" | "logarithmic" | "inverted" | "sCurve";
  }>;
}

// --- Macro-Node Operations ---

interface EncapsulateMsg {
  action: "macro.encapsulate";
  macroId: string;
  name: string;
  childNodeIds: string[];
}

interface ExpandMacroMsg {
  action: "macro.expand";
  macroId: string;
}

// --- Markov Sequencer ---

interface MarkovMatrixMsg {
  action: "markov.setMatrix";
  nodeId: string;
  matrix: number[][];      // Row-stochastic NxN
  stateLabels?: string[];  // Optional display labels per state
}

// --- Patch Serialization ---

interface SavePatchMsg {
  action: "patch.save";
  name: string;
  graph: SerializedGraph;
}

interface LoadPatchMsg {
  action: "patch.load";
  name: string;
}

// --- Graph Serialization Schema ---

interface SerializedGraph {
  version: "2.0.0";
  nodes: SerializedNode[];
  edges: SerializedEdge[];
  macros: SerializedMacro[];
  exposedControls: ExposedControl[];
  macroBindings: MacroBinding[];
  viewport: { x: number; y: number; zoom: number };
}
```

### 7.3 Messages: Swift → JS

```typescript
// --- Telemetry (~15 Hz, throttled) ---

interface TelemetryMsg {
  event: "telemetry";
  nodes: Record<string, {
    level?: number;               // RMS [0..1]
    spectralCentroid?: number;
    spectralFlatness?: number;
    spectralFlux?: number;
    inferenceStatus?: "idle" | "processing" | "complete";
    iterationCount?: number;
    cycleTimeMs?: number;
  }>;
}

// --- Bridge Status ---

interface BridgeStatusMsg {
  event: "bridge.status";
  status: "disconnected" | "connecting" | "connected" | "model_loaded" | "error";
  modelType?: string;
  device?: string;
}

// --- Connection Validation ---

interface ValidationMsg {
  event: "edge.validation";
  edgeId: string;
  valid: boolean;
  reason?: string;
}

// --- Action Confirmation ---

interface ConfirmMsg {
  event: "action.confirmed";
  originalAction: string;
  success: boolean;
  error?: string;
}

// --- Exposed Controls Sync (Swift → JS, on PERFORM changes) ---

interface ExposedControlUpdateMsg {
  event: "exposed.update";
  exposedId: string;
  value: number;
}
```

---

## 8. Graph Engine (Swift)

### 8.1 Core Data Model

```swift
/// Signal types flowing between nodes.
enum SignalType: String, Codable {
    case audio, control, gate, text
}

/// Port direction.
enum PortDirection: String, Codable {
    case input, output
}

/// A typed port on a node.
struct NodePort: Identifiable, Codable {
    let id: String
    let label: String
    let signalType: SignalType
    let direction: PortDirection
}

/// A connection between two ports.
struct GraphEdge: Identifiable, Codable {
    let id: UUID
    let sourceNodeId: UUID
    let sourcePortId: String
    let targetNodeId: UUID
    let targetPortId: String
    let signalType: SignalType
}

/// Base protocol for all graph nodes.
protocol GraphNode: Identifiable, ObservableObject {
    var id: UUID { get }
    var nodeType: String { get }
    var ports: [NodePort] { get }
    var parameters: [String: Any] { get set }
    var exposedControls: [ExposedControl] { get set }

    func onTopologyChanged(
        inputs: [String: GraphEdge],
        outputs: [String: [GraphEdge]]
    )

    /// Returns the AVAudioNode for audio-processing nodes, nil for control-only.
    func audioUnit() -> AVAudioNode?

    /// Evaluates control-rate output (called at ~60Hz by ModulationGraph timer).
    func evaluateControl(portId: String, at time: TimeInterval) -> Float
}
```

### 8.2 NodeGraph

```swift
final class NodeGraph: ObservableObject {
    @Published var nodes: [UUID: any GraphNode] = [:]
    @Published var edges: [UUID: GraphEdge] = [:]
    @Published var exposedControls: [ExposedControl] = []
    @Published var macroBindings: [MacroBinding] = []

    /// Validates a proposed connection. Returns nil if valid, error string if not.
    func validateConnection(
        from source: (nodeId: UUID, portId: String),
        to target: (nodeId: UUID, portId: String)
    ) -> String? {
        // 1. Port type compatibility (audio↔audio, control↔control, etc.)
        // 2. Cycle detection via DFS (only FEEDBACK LOOP may create cycles)
        // 3. Single-connection constraint on audio input ports
        // 4. Multi-connection allowed on control input ports (summed)
    }

    /// Applies a topology change and triggers audio graph rebuild if needed.
    func applyMutation(_ mutation: GraphMutation, engine: NeuralEngine) throws {
        // 1. Validate
        // 2. Update internal state
        // 3. If audio topology changed: call audioGraphMapper.rebuild()
        // 4. If control-only: update ModulationGraph routing
        // 5. Send confirmation to React Flow
    }

    /// Serializes entire graph state to JSON.
    func serialize() -> SerializedGraph { ... }

    /// Rebuilds graph from serialized state.
    func deserialize(_ data: SerializedGraph, engine: NeuralEngine) throws { ... }
}
```

### 8.3 Audio Graph Mapper

```swift
final class AudioGraphMapper {
    private let avEngine: AVAudioEngine

    /// Determines if a graph mutation requires audio engine restart.
    func requiresRestart(_ mutation: GraphMutation) -> Bool {
        // Param changes: NO restart (in-place update)
        // New node / new audio edge / removed node: YES restart
    }

    /// Rebuilds AVAudioEngine node connections from NodeGraph.
    /// Gap: ~50ms (masked by 10ms fade out/in on master volume).
    func rebuild(from graph: NodeGraph) {
        // 1. Fade master to 0 (10ms ramp)
        // 2. Stop engine
        // 3. Detach all dynamic nodes
        // 4. Walk graph in topological order
        // 5. For each audio node: attach AVAudioNode, set format
        // 6. For each audio edge: connect source → target
        // 7. Start engine
        // 8. Fade master to 1 (10ms ramp)
    }
}
```

### 8.4 Markov Chain Implementation

```swift
/// First-order Markov chain for probabilistic sequencing.
struct MarkovChain: Codable {
    let stateCount: Int
    var transitionMatrix: [[Float]]    // Row-stochastic NxN
    var temperature: Float = 1.0
    private var currentState: Int = 0
    private var rng: Xoshiro256StarStar  // Same PRNG as SignalGenerator

    /// Advances to next state using temperature-scaled probabilities.
    mutating func advance() -> Int {
        let row = transitionMatrix[currentState]
        let scaled = temperatureScale(row, temperature)
        currentState = sampleCategorical(scaled, using: &rng)
        return currentState
    }

    /// Temperature scaling: p_i = exp(log(m_i)/T) / Σ exp(log(m_j)/T)
    private func temperatureScale(_ probs: [Float], _ T: Float) -> [Float] {
        guard T > 0 else {
            // T=0: deterministic (argmax)
            var result = [Float](repeating: 0, count: probs.count)
            if let maxIdx = probs.indices.max(by: { probs[$0] < probs[$1] }) {
                result[maxIdx] = 1.0
            }
            return result
        }
        let logits = probs.map { log(max($0, 1e-8)) / T }
        let maxLogit = logits.max() ?? 0
        let exps = logits.map { exp($0 - maxLogit) }
        let sum = exps.reduce(0, +)
        return exps.map { $0 / sum }
    }
}
```

---

## 9. PERFORM View: Auto-Generated Control Surface

### 9.1 Layout Engine

The PERFORM view renders exclusively from the `exposedControls` array. No hardcoded controls exist.

```swift
struct PerformSurfaceView: View {
    @ObservedObject var graph: NodeGraph

    var body: some View {
        let controls = graph.exposedControls.sorted(by: { $0.position < $1.position })
        let layout = PerformLayoutEngine.compute(for: controls)

        ForEach(layout.rows) { row in
            HStack(spacing: LRConstants.DS.spacingMD) {
                ForEach(row.items) { item in
                    switch item.controlType {
                    case .knob:
                        RetroKnob(value: binding(for: item), size: layout.knobSize)
                    case .fader:
                        LRParamSlider(value: binding(for: item))
                    case .xyPad:
                        LatentXYPad(x: binding(for: item.xParam),
                                    y: binding(for: item.yParam))
                    case .toggle:
                        LRToggle(isOn: boolBinding(for: item), label: item.label)
                    case .dropdown:
                        LRSegmentPicker(selection: enumBinding(for: item))
                    }
                }
            }
        }
    }
}
```

### 9.2 Layout Rules

```
N exposed controls → Layout strategy:

 1–4   → Single row, knob size 96pt
 5–8   → Two rows (4+4 or 5+3), knob size 74pt
 9–16  → Grid, 4 columns, knob size 56pt
 17+   → Scrollable grid with section headers (grouped by source node)

XY Pad: When two controls share a macro binding with axes labeled X/Y,
        or when user explicitly pairs them, render as single XY pad
        occupying 2×2 grid cells.

Step Sequencer: Always renders full-width below the knob grid.
                Only visible if a STEP SEQUENCER or MARKOV SEQUENCER
                node has exposed controls.
```

### 9.3 MIDI Learn Integration

Any exposed control supports MIDI CC assignment:
1. User long-presses a control in PERFORM view.
2. "MIDI Learn" mode activates (control flashes).
3. User moves a physical CC on their controller.
4. CC number is captured and stored in `ExposedControl.midiCC`.
5. Subsequent CC messages route directly to the bound parameter.

This replaces the hardcoded `ParameterRouter` CC mapping from v1.x.

---

## 10. Backward Compatibility

### 10.1 Implicit Graph Generation

When PATCH view has never been opened, the system generates an implicit graph equivalent to v1.x topology:

```
For each active ResonatorLane:
  [LanePreset Macro-Node] → [Lane Mixer Input]

All Lane Mixer Inputs → [Master Mixer] → [Master Output]
```

All v1.x parameters (guidanceScale, filterCutoff, etc.) are pre-exposed to the PERFORM surface matching v1.x layout.

### 10.2 Bidirectional Sync

`NodeGraph` is the single source of truth. SETUP and PERFORM views are read/write projections:
- Knob turn in SETUP → `param.set` to NodeGraph → reflected in PATCH
- Cable added in PATCH → NodeGraph updates → SETUP shows new routing
- P-Lock edit in PERFORM → `param.set` per step → NodeGraph stores per-step values

---

## 11. Example Topologies

### 11.1 Default Topology (v1.x equivalent)

```
KOENIG SEED → FFT → Semantic EQ → Spectral Saturation → Spectral Noise →
Spectral Memory → Spectral Granularity → Spectral Freeze →
IFFT → Ladder Filter → Comb Filter → Tunable Resonator →
Bit Crusher → Waveshaper → Delay → MIXER → MASTER OUTPUT
                                      ▲
                                      │
                         FEEDBACK LOOP ← ACE-STEP INFERENCE
                                              ▲
                                      PROMPT ENGINE
                                      (driven by SPECTRAL ANALYZER.flatness)
```

### 11.2 Cross-Lane Coupled System

```
Lane A (NOISE excitation):
  [spectral chain A] → MIXER A
  SPECTRAL ANALYZER A:
    centroid → Lane B: LADDER_FILTER.CUTOFF
    flatness → Lane B: ACE_STEP.CFG

Lane B (SINE excitation):
  [spectral chain B] → MIXER B
  SPECTRAL ANALYZER B:
    flux → Lane A: SPECTRAL_NOISE.AMOUNT
    centroid → Lane A: TUNABLE_RESONATOR.NOTE

FEEDBACK LOOP A reads from Lane B output
FEEDBACK LOOP B reads from Lane A output
```

Both lanes form a coupled dynamical system. Spectral state of each lane modulates the other's processing parameters and feeds back audio cross-lane.

### 11.3 Autonomous Generative System

```
SILENCE → ACE-STEP INFERENCE → SPECTRAL ANALYZER
               │                     │
               │            centroid → AGITATION.RATE
               │            flatness → ACE-STEP.CFG
               │            flux → MANUAL CONTROL → SPECTRAL NOISE.AMOUNT
               │
               └→ WAVESHAPER → DELAY → FEEDBACK LOOP → (back to input)

MARKOV SEQUENCER (8 states, T=0.8):
  VALUE → ACE-STEP.DENOISE
  GATE → PEAK ENVELOPE → DELAY.MIX

STEP SEQUENCER (16 steps, chain=12):
  VALUE → PROMPT ENGINE.PHASE
```

The system self-generates without external input. Spectral analysis modulates inference parameters, inference output modulates spectral state. Markov sequencer introduces probabilistic perturbations. Step sequencer cycles through prompt phases.

---

## 12. Implementation Roadmap

### Phase 1: Graph Foundation (4–6 weeks)
- `NodeGraph`, `GraphNode` protocol, `GraphEdge` in Swift
- `WebViewBridge` wrapper (WKWebView + WKScriptMessageHandler)
- React Flow project setup (TypeScript, Vite → static bundle)
- Bidirectional JSON message protocol
- Basic nodes: Oscillator, Noise, Mixer, Master Output
- **Deliverable:** Functional canvas. Create oscillator → connect to mixer → hear audio.

### Phase 2: Spectral Chain Decomposition (4–6 weeks)
- Decompose SpectralProcessor into individual GraphNode implementations
- AudioGraphMapper (NodeGraph → AVAudioEngine topology rebuild)
- Filter nodes: Ladder, Comb, Tunable Resonator
- Effect nodes: BitCrusher, Waveshaper, Delay
- Audio cable validation and rendering
- **Deliverable:** Full 14-stage spectral chain as individual connected nodes.

### Phase 3: Neural Inference Integration (3–4 weeks)
- ACE-Step Inference node (integration with existing ACEStepBridge)
- Prompt Engine node (spectral-flatness-conditioned phase evolution)
- Feedback Loop node (recursive cycle closure)
- Real-time telemetry (RMS levels, inference status, cycle time)
- **Deliverable:** Complete recursive inference loop running in node canvas.

### Phase 4: Control System (3–4 weeks)
- Control-rate signal routing (CV digital)
- Agitation (LFO), Peak (Envelope), Manual Control nodes
- Step Sequencer node with P-Locks
- Markov Sequencer node with editable transition matrix
- Spectral Analyzer node (audio → control signal conversion)
- Meta-modulation (modulate a modulator's rate with another modulator)
- **Deliverable:** Full modulation system in nodes. CV routing functional.

### Phase 5: Exposed Controls + Auto-Layout (3–4 weeks)
- Exposed Control system (right-click → Expose to Perform)
- Macro scaling bindings (one control → multiple targets with curves)
- Auto-generated PERFORM layout engine
- MIDI Learn for exposed controls
- **Deliverable:** Dynamic PERFORM surface that assembles from exposed params.

### Phase 6: Macro-Nodes + Presets (2–3 weeks)
- Node encapsulation (select → Cmd+G → Macro-Node)
- LanePreset → factory macro-node migration (7 presets)
- Save/Load patches (full graph JSON serialization)
- Macro-node export/import
- **Deliverable:** All 7 factory presets work as expandable macro-nodes.

### Phase 7: Bidirectional Sync (2–3 weeks)
- SETUP view as NodeGraph projection
- PERFORM view as NodeGraph projection
- Cross-lane modulation routing in PATCH reflected in SETUP
- Zero regression in all v1.x functionality
- **Deliverable:** Three views fully synchronized. All v1.x workflows preserved.

### Phase 8: Polish (2–3 weeks)
- Cable flow animations (particle system proportional to signal level)
- Minimap
- Undo/Redo (full graph history)
- Node search (Cmd+F, fuzzy match by name/category)
- Copy/Paste of nodes and subgraphs
- Keyboard shortcuts consistent with SETUP/PERFORM
- **Deliverable:** Release candidate v2.0.

**Total estimate: 23–33 weeks (~6–8 months)**

---

## 13. Open Questions

1. **Custom DSP nodes.** Allow users to write processing code (e.g., embedded Faust DSP scripts compiled to WebAssembly)? Opens community module ecosystem but requires sandboxing.

2. **Inference node limit.** Each ACE-STEP INFERENCE node consumes one inference cycle (~5–30s on MPS). Current `maxLanes = 4`. Maintain this cap or make it configurable based on hardware?

3. **MIDI Learn scope.** Per-patch or global? If a user assigns CC21 to "MUTATION" in Patch A, should CC21 do the same in Patch B?

4. **Patch migration.** When node catalog changes between versions, how to migrate saved patches? Proposed: semantic versioning + migration functions keyed to `version` field.

5. **Community patch sharing.** Macro-nodes export as standalone JSON. Publish to a shared repository? Defer to post-v2.0 or build infrastructure now?

6. **Markov matrix editor UX.** Editing an NxN probability matrix is non-trivial. Options: (a) spreadsheet grid in PATCH view, (b) graphical transition diagram with weighted edges, (c) preset matrices (uniform, cyclic, absorbing).

---

## Appendix A: Complete Technology Stack

| Layer | Technology | Role |
|-------|-----------|------|
| Audio engine | AVAudioEngine + Accelerate (vDSP) | Real-time DSP, < 5ms latency |
| Neural inference | Python 3.10+ / PyTorch 2.0+ / ACE-Step 1.5 | Generative audio model |
| Inference bridge | Flask + Waitress (HTTP, localhost:8976) | Swift ↔ Python communication |
| Graph engine | Swift (NodeGraph, GraphNode protocol) | Graph data model + validation |
| Audio mapper | Swift (AudioGraphMapper) | NodeGraph → AVAudioEngine rebuild |
| Modulation | Swift (ModulationGraph, ~60Hz timer) | Control-rate signal evaluation |
| Markov engine | Swift (MarkovChain + Xoshiro256**) | Probabilistic sequencing |
| Node editor UI | React Flow / xyflow (TypeScript, MIT) | Visual node canvas |
| WebView host | WKWebView + WKScriptMessageHandler | Embedding React Flow in app |
| JS build | Vite → static bundle | Compiled into app resources |
| Persistence | JSON (patches) + @AppStorage (settings) | Graph + preference storage |
| Design system | LRConstants.DS (shared tokens) | Visual consistency across views |
| PRNG | Xoshiro256** (lock-free, 2^256−1 period) | Audio-thread-safe randomness |
| FFT | Accelerate vDSP_fft_zrip | Spectral analysis/resynthesis |

## Appendix B: Glossary

| Term | Definition |
|------|-----------|
| Macro-Node | Subgraph encapsulated as a single collapsible node |
| CV (Control Voltage) | Digital control signal [0..1] routed between nodes at ~60Hz |
| P-Lock | Per-step parameter value stored in the step sequencer grid |
| Exposed Control | Node parameter promoted to the PERFORM surface |
| Macro Binding | Mapping from one exposed control to multiple node parameters with independent scaling |
| Dataflow | Programming paradigm where data flows between processing nodes connected by typed edges |
| Polyadic | Property where each modulation connection maintains independent state (phase, RNG) |
| Feedback Loop | Recursive cycle where processed output re-enters as input (whitepaper §3.3) |
| Spectral Memory | Persistent FFT magnitude array that accumulates resonant frequencies across iterations |
| Markov Chain | Stochastic model where next state depends only on current state via transition probabilities |
| Temperature (Markov) | Scalar controlling randomness: 0=deterministic, 1=true probabilities, >1=more random |
| Graph Mutation | Any structural change to the node graph (add/remove node, connect/disconnect edge) |

## Appendix C: v2.0 Implementation Notes (2026-04-03)

### Shell Integration

**Status:** ✅ COMPLETE

The Python bridge is now shell-managed:
- **Auto-spawn** — `BridgeProcessManager` launches Python server via `Foundation.Process`
- **Dynamic flags** — `--low-latency` passed in PERFORM mode (caps steps to 6)
- **Terminal console** — Real-time stdout/stderr display in PATCH view (Mecha Metal aesthetic)
- **Status indicators** — RUNNING / LAUNCHING / ERROR visible in UI

**Files:**
- `BridgeProcessManager.swift` — Added `realtimeLog: [String]`, `launchServer(performanceMode: Bool)`
- `Views/TerminalConsoleView.swift` — Phosphor green terminal with auto-scroll
- `RootView.swift` — Integrates terminal into PATCH view, restarts bridge on mode change
- `ace_bridge_server.py` — Accepts `--low-latency` flag, sets `LOW_LATENCY_MODE` global

### Audio Visualizer

**Status:** ✅ COMPLETE

SETUP mode's DRIFT FIELD now features real-time waveform + FFT visualization:
- **Canvas 2D + WebAudio** — Lightweight visualizer (~20KB memory)
- **WKWebView integration** — `AudioVisualizerXYPad.swift` wraps HTML/JS
- **Touch-reactive** — Still controls Texture/Chaos macros
- **Data flow** — `ResonatorLane.waveformSnapshot` (256 samples) + `spectralBins` (downsampled FFT)

**Files:**
- `ResonatorLane.swift` — Added `waveformSnapshot: [Float]`, populated in `processAudioTap`
- `WebView/AudioVisualizerHTML.swift` — HTML/JS for Canvas 2D rendering
- `Views/AudioVisualizerXYPad.swift` — WKWebView wrapper with 30fps throttled updates
- `LatentResonatorView.swift` — Replaced `LatentXYPad` with `AudioVisualizerXYPad`

### Documentation Updated

- `README.md` — Now correctly describes 3 modes, terminal console, audio visualizer, performance flags
- `CHANGELOG.md` — v2.0.0 entry added with full feature list
- `python-bridge/SKILL.md` — Documents `--low-latency` flag and terminal log streaming
- `latent-resonator-architecture/SKILL.md` — New Scenario D (terminal) and E (visualizer)
- `docs/GAP_ANALYSIS_2026-04-03.md` — Complete audit of code vs docs inconsistencies

