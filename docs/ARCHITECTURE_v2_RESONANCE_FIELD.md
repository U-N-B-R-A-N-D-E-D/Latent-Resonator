# Resonance Field Architecture (v2.0)

## The Mathematical Foundation

The Latent Resonator's core identity is captured in the recursive feedback formula:

```
S(i+1) = ACE(S(i) + N(μ, σ), P, γ)
```

Where:
- **S(i)**: The current state (audio as latent representation)
- **N(μ, σ)**: Stochastic drift (controlled noise injection)
- **P**: Prompt/character (the qualitative identity)
- **γ**: Guidance scale (how strictly P is enforced)
- **ACE**: Audio Controlled Encoder (the neural inference engine)

## Extending to Modulation: The Resonance Field

The v2.0 architecture extends this philosophy to the **control space**: modulation of modulation of modulation. We call this the **Resonance Field** — a living, recursive system where control signals flow, interact, and transform each other.

### The Resonance Field Equation

In the PATCH view, each node is a state S(i) in the field. Connections between nodes are the ACE operator applied to control signals:

```
S_control(i+1) = Field(S_control(i) + N_field(μ, σ), NodeConfig, Depth)
```

Where:
- **S_control**: A parameter value in the NodeGraph
- **N_field**: AgitationNode output (stochastic modulation source)
- **NodeConfig**: The node's type and internal parameters (LFO waveform, filter character)
- **Depth**: Control edge intensity (equivalent to guidance scale)
- **Field**: The ControlGraphEvaluator — the conductor of the field

## Architecture Overview

### Three Views, Three Perspectives

| View | Modulation Experience | User Mental Model |
|------|----------------------|-------------------|
| **SETUP** | Per-lane LFO only | "My lane breathes with organic movement" |
| **PATCH** | Full Resonance Field | "I see the energy flowing between nodes" |
| **PERFORM** | Exposed macro controls only | "I touch the result, not the mechanism" |

### Control Flow Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    PATCH VIEW (Node Graph)                         │
│  ┌──────────┐    ┌──────────┐    ┌──────────┐                  │
│  │Agitation │───→│  Peak    │───→│ MacroNode│                  │
│  │  Node    │    │  Node    │    │(Lane DSP)│                  │
│  │ (N(μ,σ)) │    │(resonance)│   │          │                  │
│  └──────────┘    └──────────┘    └────┬─────┘                  │
│       ↓                                 │                        │
│  ┌──────────┐                      (control edge)               │
│  │Envelope  │                          ↓                        │
│  │  Node    │──────────────────────────┘                        │
│  └──────────┘                                                   │
└─────────────────────────────────────────────────────────────────┘
                              │
                    ┌─────────▼──────────┐
                    │ControlGraphEvaluator│ 60Hz evaluation
                    │   (Field Conductor) │
                    └─────────┬───────────┘
                              │
                    ┌─────────▼──────────┐
                    │  NodeGraph (Source  │
                    │   of Truth)         │
                    └─────────┬───────────┘
                              │
                    ┌─────────▼──────────┐
                    │RTParameterSnapshot │ Lock-free, audio thread
                    │  (per-lane, 25 params)│
                    └─────────┬───────────┘
                              │
                    ┌─────────▼──────────┐
                    │  Audio Thread       │
                    │  (ACE inference)    │
                    └─────────────────────┘
```

## Node Types in the Resonance Field

### Source Nodes (Generators)

| Node | Mathematical Role | Musician Concept |
|------|-------------------|------------------|
| **AgitationNode** | N(μ, σ) — stochastic drift | "Ether/Chaos" — unpredictable energy |
| **LFO Node** | Periodic oscillator | "Pulse" — rhythmic breathing |
| **Envelope Node** | Attack/Decay stages | "Swelling" — rising and falling energy |

### Transform Nodes (Processors)

| Node | Function | Musician Concept |
|------|----------|------------------|
| **Peak Node** | Envelope following, attack/decay | "Resonator" — captures and sustains peaks |
| **Fold Node** | Wavefolding distortion | "Turbulence" — adds harmonic complexity |
| **Filter Node** | Frequency emphasis | "Color" — timbral shaping |

### Destination Nodes (Targets)

| Node | Role | Parameters Modulated |
|------|------|---------------------|
| **MacroNode** | Lane container | cfg, entropy, granularity, feedback, filter cutoff, etc. |

## Technical Implementation

### ControlGraphEvaluator (Field Conductor)

```swift
final class ControlGraphEvaluator {
    // Runs at 60Hz on main thread
    func tick() {
        // 1. Topological sort of control nodes
        let outputs = evaluate(graph: nodeGraph, at: currentTime)
        
        // 2. Apply modulation via NodeGraph (source of truth)
        applyModulation(outputs: outputs, graph: graph)
        
        // 3. Notify for RT snapshot updates
        onEvaluationComplete?()
    }
}
```

### Lock-Free Audio Thread Access

```swift
// Main thread (60Hz): Updates snapshot
func updateRTSnapshot() {
    rtSnapshot.cfgScale = graph.getParameter(nodeId: macroId, key: "cfgScale") ?? 0.5
    rtSnapshot.entropy = graph.getParameter(nodeId: macroId, key: "entropy") ?? 0.5
    // ... all 25 parameters
}

// Audio thread (real-time): Reads snapshot
let cfg = rtSnapshot.cfgScale  // Lock-free, atomic for Float
```

### Control Edge Semantics

```swift
// Control edges in NodeGraph carry modulation signals
edge.signalType == .control  // 60Hz evaluation

// Target parameters are identified by port ID
// "freq_cv" → maps to "freq" parameter with additive modulation
let paramKey = edge.targetPortId.replacingOccurrences(of: "_cv", with: "")

// Modulation is additive: newValue = baseValue + modulation
let modulatedValue = currentValue + sourceValue
graph.setParameter(nodeId: edge.targetNodeId, key: paramKey, value: modulatedValue)
```

## Signal Flow Deep Dive

### 1. SETUP View: LFO Configuration

Users configure per-lane LFO parameters (rate, depth, target). These are **static configuration**, not the Resonance Field:

```swift
// ResonatorLane LFO (simplified, per-buffer)
let lfoValue = sin(phase) * params.lfoDepth
applyLFOModulation(value: lfoValue, target: params.lfoTarget)
```

**Why separate?** The LFO is always present, always simple, always per-lane. It's the "baseline life" of each lane, distinct from the complex field interactions in PATCH.

### 2. PATCH View: The Field Comes Alive

When users switch to PATCH, they see the **MacroNodes** for each active lane. Expanding a MacroNode reveals its internal graph — the Resonance Field for that lane.

Control nodes (Agitation, Peak, etc.) can be:
- **Inside** a MacroNode (affects only that lane)
- **Outside** at the global level (can cross-modulate between lanes via edges)

### 3. PERFORM View: Touch the Result

Only exposed macro controls are visible. The Resonance Field is active but invisible — users hear its effect, feel its behavior, but don't manipulate its structure.

## Mathematical Equivalence

The Resonance Field preserves the ACE-Step identity:

| ACE-Step | Resonance Field |
|----------|-----------------|
| S(i): Audio latent | Node parameter value |
| N(μ, σ): Noise injection | AgitationNode output |
| P: Prompt | Node configuration (type + params) |
| γ: Guidance scale | Control edge depth/intensity |
| ACE: Inference engine | ControlGraphEvaluator |

This is **intentional isomorphism**: the same mathematical structure operates at multiple scales (audio inference, control modulation, meta-modulation).

## Migration from v1.x

### Deprecated Components

| v1.x Component | v2.0 Replacement | Status |
|----------------|----------------|--------|
| `ModulationGraph` | `ControlGraphEvaluator` + `NodeGraph` | Deprecated, kept for compatibility |
| `ModulationStripView` (SETUP) | PATCH view node editor | Removed from SETUP |
| Direct audio thread offset reads | `RTParameterSnapshot` | Migrated |

### Backward Compatibility

Saved v1.x sessions containing `ModulationGraph` data can be loaded. The system will:
1. Load the legacy graph into `NeuralEngine.modulationGraph`
2. Not use it for new modulation (audio thread ignores it)
3. Preserve it for re-saving in v1.x format

New modulation is always created via PATCH view nodes.

## Thread Safety Architecture

```
Main Thread (60Hz)          Audio Thread (real-time)
    │                              │
    ▼                              ▼
┌─────────────────┐        ┌─────────────────┐
│ ControlGraph    │        │ ResonatorLane   │
│ Evaluator       │        │ audio callback  │
│ - Evaluates     │        │ - Reads         │
│   nodes         │        │   RTParameter   │
│ - Sets params   │        │   Snapshot      │
│   via NodeGraph │        │ - Runs ACE      │
└────────┬────────┘        │   inference     │
         │                 └─────────────────┘
         ▼                         │
┌─────────────────┐               │
│ NodeGraph       │               │
│ (source of      │               │
│  truth)         │               │
└────────┬────────┘               │
         │                         │
         ▼                         │
┌─────────────────┐               │
│ updateRTSnapshot│               │
│ (writes to      │               │
│  RTParameter    │               │
│  Snapshot)      │               │
└─────────────────┘               │
         │                         │
         ▼                         ▼
┌───────────────────────────────────┐
│   Lock-free: Float atomic reads   │
│   (torn read inaudible)           │
└───────────────────────────────────┘
```

## Performance Characteristics

| Aspect | Specification |
|--------|---------------|
| Control evaluation rate | 60 Hz (16.67ms period) |
| Audio callback rate | 48 kHz / 512 samples = ~93 Hz (10.67ms) |
| Snapshot update jitter | < 1ms (main thread timer) |
| Modulation latency | ~16ms (control to audio) |
| Thread synchronization | Lock-free (atomic Float reads) |
| Node count limit | 1000+ nodes (topological sort O(N)) |
| Edge count limit | 5000+ edges |

## Future Extensions

The Resonance Field architecture supports:

1. **Meta-modulation**: Modulation of modulator parameters (already supported via control edges between control nodes)
2. **Cross-lane modulation**: Global control nodes modulating multiple lanes
3. **Feedback loops**: Self-modulation (node output → node parameter) with cycle detection
4. **Preset nodes**: Save/recall sub-graph configurations as "characters"
5. **Gesture recording**: MPE trajectory capture as envelope nodes

## Summary

The Resonance Field transforms the abstract `ModulationGraph` into a **visual, interactive, musician-centric experience**. It embodies the ACE-Step philosophy at the control layer:

> *"Modulation is not applied to audio. Modulation is the recursive feedback of control states, guided by node configuration, with stochastic drift from AgitationNodes, all conducted by the ControlGraphEvaluator at 60Hz."*

This is **GRM Atelier philosophy realized**: modulation as a living, breathing, self-modifying field — not a static routing matrix, but a **resonance** between interconnected energies.
