---
name: Latent Resonator v2.0 Integration
overview: Complete implementation of NodeGraph-as-source-of-truth architecture, unifying the bifurcated v1.x/v2.0 codebases into a cohesive system aligned with the whitepaper. All 12 opportunity areas across Tiers 1-4.
todos:
  - id: w1-param-authority
    content: "Week 1: Migrate ResonatorLane to NodeGraph parameter authority - remove @Published, add graphNodeId, implement lock-free RT reads, remove syncNodeParameter() entirely"
    status: pending
  - id: w2-scene-migration
    content: "Week 2: Replace LaneSnapshot with GraphSnapshot, implement scene morphing via graph parameters, run A/B listening test gate"
    status: pending
  - id: w3-audio-activation
    content: "Week 3: Wire AudioGraphMapper.rebuild() to production path, replace SpectralChainNode placeholder with real audio processing, unify modulation systems into graph nodes"
    status: pending
  - id: w4-ui-unification
    content: "Week 4: Implement MacroNode unifying SETUP/PATCH, wire PerformLayoutEngine to PerformanceMotherbaseView, implement Expose to Motherbase flow"
    status: pending
  - id: w5-meta-parameters
    content: "Week 5: Implement MetaParameter with scaling curves in MacroNode, add k/n parameters to KoenigSeedNode for parametric Euclidean rhythms"
    status: pending
  - id: w6-prompt-markov
    content: "Week 6: Create PromptBankNode replacing hardcoded P1/P2/P3, implement MarkovSequencerNode with temperature scaling and flatness-driven state transitions"
    status: pending
  - id: w7-shell-ux
    content: "Week 7: Make TerminalConsoleView persistent panel in Motherbase, expose performance profiles (--ultra-low-latency, --balanced, --studio) as hardware toggles"
    status: pending
  - id: w8-cross-lane
    content: "Week 8: Implement cross-lane audio routing - parent-child subgraph hierarchy, AVAudioEngine re-routing with fade-crossfade, live cable patching between lanes"
    status: pending
  - id: verify-ab
    content: "Verification: A/B test suite comparing v1.x vs v2.0 audio quality across all factory presets, >99.9% correlation required"
    status: pending
  - id: docs-update
    content: Update ARCHITECTURE_v2_NODAL.md and IMPLEMENTATION_VERIFICATION.md to reflect completed status, remove RFC banners
    status: pending
isProject: false
---

## Phase 1: Foundation - NodeGraph as Single Source of Truth (Weeks 1-2)

### Week 1: Parameter Authority Migration

**Objective:** Remove dual-truth source, make NodeGraph the canonical storage for all parameters.

**Key Files to Modify:**

- `/Users/leolambertini/RLTNAS/LatentResonator/LatentResonator/ResonatorLane.swift` - Remove `@Published` parameters, add `graphNodeId: UUID`
- `/Users/leolambertini/RLTNAS/LatentResonator/LatentResonator/NeuralEngine.swift` - Wire `AudioGraphMapper.rebuild()` into production path
- `/Users/leolambertini/RLTNAS/LatentResonator/LatentResonator/Graph/NodeGraph.swift` - Ensure lock-free read for RT thread

**Implementation Details:**

```swift
// ResonatorLane becomes a view into NodeGraph
class ResonatorLane {
    let graphNodeId: UUID  // The MacroNode this lane represents
    
    // All parameter access routes through NodeGraph
    var texture: Float {
        get { nodeGraph.parameters[graphNodeId]?["texture"] ?? 0.5 }
        set { nodeGraph.setParameter(nodeId: graphNodeId, key: "texture", value: newValue) }
    }
}
```

**Critical Path:**

1. Remove `syncNodeParameter()` entirely
2. Replace with `nodeGraph.setParameter()` as universal API
3. Add snapshot-based lock-free read for audio callback thread
4. All writers (SETUP knobs, PATCH editor, P-Locks, scenes, MPE, Python shell) route through `NodeGraph`

### Week 2: Scene Persistence Migration

**Objective:** Scenes become GraphSnapshot, not LaneSnapshot.

**Files:**

- `/Users/leolambertini/RLTNAS/LatentResonator/LatentResonator/SceneManager.swift`
- `/Users/leolambertini/RLTNAS/LatentResonator/LatentResonator/Graph/GraphTypes.swift` (create)

**Implementation:**

```swift
struct GraphSnapshot: Codable {
    let nodeId: UUID
    let parameters: [String: Float]
    // No topology - scenes morph parameter values, not graph structure
}

struct PerformanceScene {
    let laneGraphSnapshots: [UUID: GraphSnapshot]  // nodeId -> snapshot
    // Crossfader morphs between GraphSnapshots
}
```

**A/B Test Gate:** Before proceeding to Phase 2, run listening test comparing v1.x scenes vs v2.0 graph-based scenes. If audio differs, diagnose parameter resolution latency.

---

## Phase 2: Audio Path Activation (Week 3)

### Week 3: AudioGraphMapper Production Wiring + Modulation Unification

**Objective:** Activate the dormant AudioGraphMapper, replace placeholder SpectralChainNode.

**Files:**

- `/Users/leolambertini/RLTNAS/LatentResonator/LatentResonator/Graph/AudioGraphMapper.swift` - Already implemented, just needs calling
- `/Users/leolambertini/RLTNAS/LatentResonator/LatentResonator/Graph/Nodes/SpectralNodes.swift` - Replace placeholder with real audio processing
- `/Users/leolambertini/RLTNAS/LatentResonator/LatentResonator/NeuralEngine.swift` - Call `audioGraphMapper.rebuild()` on mutations

**Critical Implementation:**

```swift
// SpectralChainNode:798-832 - Replace silence buffer with real audio input
func audioUnit() -> AVAudioNode? {
    return AVAudioSourceNode { [weak self] _, _, frameCount, audioBufferList in
        guard let self = self else { return 1 }
        
        // Get input from upstream connection (not silence!)
        let inputBuffer = self.getInputAudioBuffer(frameCount: frameCount)
        
        // Process through actual SpectralProcessor
        let processed = self.processor.process(
            samples: inputBuffer,
            guidanceScale: self.parameters["guidanceScale"] ?? 10.0,
            // ... other params from NodeGraph
        )
        
        // Write to output
        return 0
    }
}
```

**Modulation Unification:**

- Eliminate `ModulationEngine` as sistema paralelo
- Convert LFO/Envelope/Random nodes to real `GraphNode` implementations
- `ControlGraphEvaluator` evalúa a 60Hz y escribe a `NodeGraph.setParameter()`
- P-Locks del StepGrid se convierten en `SequencerNode` del grafo

---

## Phase 3: UI Unification (Week 4)

### Week 4: MacroNode Unifies SETUP/PATCH + PerformLayoutEngine Wiring

**Objective:** SETUP view shows same MacroNode that PATCH shows expanded.

**Files:**

- `/Users/leolambertini/RLTNAS/LatentResonator/LatentResonator/Views/LaneStripView.swift` - Render from MacroNode.exposedControls
- `/Users/leolambertini/RLTNAS/LatentResonator/LatentResonator/Views/PerformanceMotherbaseView.swift` - Use `PerformLayoutEngine` instead of hardcoded layout
- `/Users/leolambertini/RLTNAS/LatentResonator/LatentResonator/Views/MacroBindingsPanel.swift` (create) - UI for one-to-many parameter binding

**Implementation:**

```swift
// LaneStripView renders MacroNode.exposedControls
struct LaneStripView: View {
    let macroNode: MacroNode  // The node this lane represents
    
    var body: some View {
        ForEach(macroNode.exposedControls) { control in
            RetroKnob(
                value: binding(for: control),
                label: control.label
            )
        }
    }
}
```

**Expose to Motherbase Flow:**

1. User right-clicks parameter in PATCH → "Expose to Motherbase"
2. Parameter added to `MacroNode.exposedControls`
3. `PerformLayoutEngine.compute()` regenerates layout
4. `PerformanceMotherbaseView` renders new control automatically

---

## Phase 4: Meta-Parameters & Sound Range Expansion (Weeks 5-6)

### Week 5: Meta-Parameters + Koenig Paramétrico

**Files:**

- `/Users/leolambertini/RLTNAS/LatentResonator/LatentResonator/Graph/MacroNode.swift` - Implement MetaParameter with scaling curves
- `/Users/leolambertini/RLTNAS/LatentResonator/LatentResonator/Graph/Nodes/SourceNodes.swift` - Add k,n parameters to KoenigSeedNode

**MetaParameter Implementation:**

```swift
struct MetaParameter {
    let id: UUID
    let name: String  // e.g., "Mutación"
    let targets: [MacroTarget]
}

struct MacroTarget {
    let nodeId: UUID
    let paramId: String
    let inputRange: ClosedRange<Float>  // 0...1
    let outputRange: ClosedRange<Float>  // e.g., CFG 3...20
    let curve: ScalingCurve  // linear, exponential, inverted, s-curve
}

// Crossfader as meta-parameter
let crossfaderTargets = [
    MacroTarget(nodeId: aceNode, paramId: "cfg", outputRange: 3...20, curve: .exponential),
    MacroTarget(nodeId: ladderNode, paramId: "cutoff", outputRange: 20000...200, curve: .inverted),
    MacroTarget(nodeId: noiseNode, paramId: "amount", outputRange: 0...100, curve: .linear)
]
```

### Week 6: PromptBank + Markov Sequencer

**Files:**

- `/Users/leolambertini/RLTNAS/LatentResonator/LatentResonator/Graph/Nodes/NeuralNodes.swift` - PromptBankNode
- `/Users/leolambertini/RLTNAS/LatentResonator/LatentResonator/Graph/Nodes/ControlNodes.swift` - MarkovSequencerNode

**PromptBankNode:**

- Reemplaza P1/P2/P3 + DrumVoice hardcoded
- Lista editable: `.kick`, `.pad_warm`, `.drone_metal`
- P-Lockable como drumVoice actual

**MarkovSequencerNode:**

- Implementa matriz de transición NxN
- Temperatura: T=0 determinista, T=1 probabilidades reales, T>1 más random
- Estados basados en flatness actual de señal

---

## Phase 5: Shell Philosophy & Polish (Week 6-7)

### Terminal Console as First-Class Citizen

**Files:**

- `/Users/leolambertini/RLTNAS/LatentResonator/LatentResonator/Views/TerminalConsoleView.swift` - Ya existe, hacerlo panel persistente
- `/Users/leolambertini/RLTNAS/LatentResonator/LatentResonator/BridgeProcessManager.swift` - Exponer --ultra-low-latency, --balanced, --studio

**Implementation:**

```swift
// Motherbase shows terminal as phosphor panel
struct MotherbaseView: View {
    var body: some View {
        HStack {
            PerformanceSurface()
            TerminalConsoleView()  // Always visible, not debug-only
                .font(.phosphor)   // From Constants.swift
                .foregroundColor(.terminalAmber)
        }
    }
}

// Performance profile toggles
enum PerformanceProfile: String, CaseIterable {
    case ultraLowLatency = "--performance-mode --max-steps 4"
    case balanced = "--performance-mode --max-steps 8"
    case studio = "--max-steps 20"
}
```

### Native Reverb Post-ACE

**Files:**

- `/Users/leolambertini/RLTNAS/LatentResonator/LatentResonator/Graph/Nodes/EffectNodes.swift` - Add ReverbNode using AVAudioUnitReverb

**Rationale:** ACE-Step devuelve audio seco. Reverb nativo (no en feedback loop neural) = espacio acústico gratis sin latencia adicional.

---

## Phase 6: The Grand Integration - Cross-Lane Routing (Weeks 7-8)

### Week 7-8: Live Cross-Lane Audio + Topology Persistence

**Objective:** Feedback cables between lanes funcionan en vivo.

**Files:**

- `/Users/leolambertini/RLTNAS/LatentResonator/LatentResonator/Graph/NodeGraph.swift` - Implement parent-child subgraph hierarchy
- `/Users/leolambertini/RLTNAS/LatentResonator/LatentResonator/Graph/AudioGraphMapper.swift` - Handle cross-lane AVAudioEngine routing with fade-crossfade
- `/Users/leolambertini/RLTNAS/LatentResonator/LatentResonator/ResonatorLane.swift` - Expose audio inputs/outputs para cableado

**Architecture Change:**

```swift
// Current: flat nodeGraph
nodeGraph.nodes[macroNode.id] = macroNode

// New: hierarchical with cross-lane edges
class NodeGraph {
    var laneSubgraphs: [UUID: Subgraph]  // laneId -> nodes+edges for that lane
    var crossLaneEdges: [GraphEdge]  // Audio/control routing between lanes
}

// Cross-lane routing via AVAudioEngine mixers
func rebuildCrossLaneRouting() {
    // Lane A.output → Lane B.feedback_in
    // Con fade-crossfade para evitar clicks
}
```

**Effort:** 40-80h según tu análisis. Esto es el refactor más grande - requiere re-routeo de AVAudioEngine con fade-crossfade entre lanes.

---

## Verification Gates


| Gate              | Week | Criterio de éxito                                               |
| ----------------- | ---- | --------------------------------------------------------------- |
| A/B Audio         | 2    | v1.x y v2.0 paths suenan idénticos en todos los factory presets |
| Graph Persistence | 2    | Guardar/cargar patch preserva topología exacta                  |
| Latencia RT       | 3    | Audio callback <5ms incluso con NodeGraph lookup                |
| Meta-Parameter    | 4    | Un knob "Mutación" escala 3+ parámetros con distintas curvas    |
| Cross-Lane        | 8    | Cable de Lane A → Lane B produce audio audible sin clicks       |


---

## Files to be Modified/Created

### Core Architecture (20 files)

1. `ResonatorLane.swift` - Remove @Published params, add graphNodeId
2. `NeuralEngine.swift` - Wire AudioGraphMapper, call rebuild()
3. `SceneManager.swift` - GraphSnapshot persistence
4. `NodeGraph.swift` - Lock-free RT reads, parent-child hierarchy (Week 7)
5. `AudioGraphMapper.swift` - Call from production, cross-lane routing (Week 7)
6. `ModulationEngine.swift` - Deprecate, migrate a nodos
7. `ControlGraphEvaluator.swift` - Evaluar a 60Hz

### Node Implementations (8 files)

1. `SpectralNodes.swift` - Replace placeholder, real audio processing
2. `NeuralNodes.swift` - PromptBankNode, ACE integration
3. `SourceNodes.swift` - Koenig paramétrico (k,n)
4. `ControlNodes.swift` - MarkovSequencerNode
5. `EffectNodes.swift` - ReverbNode
6. `MacroNode.swift` - MetaParameter con curvas
7. `SequencerNode.swift` - P-Locks como parte del grafo

### UI (6 files)

1. `LaneStripView.swift` - Render from MacroNode.exposedControls
2. `PerformanceMotherbaseView.swift` - Use PerformLayoutEngine
3. `MacroBindingsPanel.swift` (new) - UI para binding curvas
4. `TerminalConsoleView.swift` - Panel persistente en Motherbase
5. `PatchViewCoordinator.swift` - Remove blocked handler (cleanup)

### Bridge (1 file)

1. `BridgeProcessManager.swift` - Exponer performance profiles

**Total:** 34 files, ~2,500 líneas nuevas/modificadas.