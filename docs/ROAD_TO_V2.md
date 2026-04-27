# Latent Resonator — Road to v2: Full Nodal Architecture

> **Purpose:** Technical migration plan to remove the lane-based architecture entirely and replace it with a pure node-graph system. This is the plan to reach v2.0. Written to be executed phase-by-phase by an LLM agent with full codebase access.
>
> **Core Constraint:** The whitepaper thesis is sacred. The recursive neural feedback loop `S(i+1) = ACE(S(i) + F(S(i)), T(i))` remains the conceptual nucleus. We are not building a generic modular synth — we are building a **node-graph instrument whose identity is the feedback loop**. Every architectural decision must serve this.
>
> **Inspiration:** Envion (Pure Data ecosystem by Emiliano Pennisi) demonstrates that conceptual restriction + topological freedom = coherent instrument. Envion's "Dynatext triplet" is its atom; our atom is the **feedback cycle** — a graph pattern where audio flows through processing → neural inference → back to mix.

---

## Table of Contents

1. [Current Architecture (What We're Leaving)](#1-current-architecture)
2. [Target Architecture (Where We're Going)](#2-target-architecture)
3. [Phase 0: Preparation & Safety Net](#phase-0-preparation--safety-net)
4. [Phase 1: SequencerNode — Decouple Sequencing from Lanes](#phase-1-sequencernode)
5. [Phase 2: Dynamic Audio Graph — Kill H19](#phase-2-dynamic-audio-graph)
6. [Phase 3: Dissolve ResonatorLane into Graph Patterns](#phase-3-dissolve-resonatorlane)
7. [Phase 4: Flatten NodeGraph — Remove Lane Subgraphs](#phase-4-flatten-nodegraph)
8. [Phase 5: New UX — Patch-First Interface](#phase-5-new-ux)
9. [Phase 6: Scene System on Pure Graph](#phase-6-scene-system)
10. [Phase 7: Factory Topologies — The "Feedback Templates"](#phase-7-factory-topologies)
11. [Phase 8: Cleanup & Delete Legacy Code](#phase-8-cleanup)
12. [Risk Register](#risk-register)
13. [File Reference Map](#file-reference-map)

---

## 1. Current Architecture

### What exists today (v2.0, released 2026-04-03)

The system uses a **hybrid architecture** where the node graph sits alongside — not replacing — the lane system:

```
NeuralEngine (orchestrator)
  ├── lanes: [ResonatorLane]          ← v1.x core, 1889-line monolith
  │     ├── combinedSourceNode        ← AVAudioSourceNode (excitation + feedback)
  │     ├── laneMixer                 ← AVAudioMixerNode (volume/solo/mute)
  │     ├── feedbackBuffer            ← CircularAudioBuffer (inference → audio thread)
  │     ├── stepGrid: StepGrid        ← per-lane sequencer state
  │     ├── macroNode: MacroNode      ← v2.0 bidirectional link to graph
  │     └── rtSnapshot                ← thread-safe parameter snapshot
  │
  ├── nodeGraph: NodeGraph            ← v2.0 source of truth (but lanes still own audio)
  │     ├── nodes / edges             ← parent-level graph
  │     ├── laneSubgraphs             ← one NodeGraph per lane (isolated)
  │     └── crossLaneEdges            ← connections between lane subgraphs
  │
  ├── audioGraphMapper                ← translates NodeGraph → AVAudioEngine
  │     └── EXCLUDES lane subgraph nodes (they use H19 path)
  │
  └── laneSlots: [ResonatorLane]      ← H19: pre-allocated pool of 4 slots
```

### Why this must change

1. **The lanes limit topology.** Each lane is a fixed 10-node chain (source → filter → comb → resonator → crusher → delay → spectral → ACE → mixer). Users cannot wire feedback loops with arbitrary geometry.
2. **The node graph is decorative.** AudioGraphMapper explicitly excludes lane subgraph nodes (line 129-137 of `AudioGraphMapper.swift`). The graph controls parameters but not audio routing.
3. **H19 pre-allocation prevents dynamism.** All 4 lane slots and their AVAudioNodes are attached at init. No new nodes can be added at runtime without engine restart.
4. **Dual codepaths create bugs.** `useGraphAudioPath` toggle (Constants.swift line 22-50) means two audio paths coexist. Every feature must work in both.

### Key files and their lane dependency depth

| File | Lines | Lane Refs | Depth |
|------|-------|-----------|-------|
| `ResonatorLane.swift` | 1,889 | IS the lane | DELETE target |
| `NeuralEngine.swift` | ~1,500 | ~200 refs | HEAVY rewrite |
| `NodeGraph.swift` | ~1,010 | laneSubgraphs, crossLaneEdges, addLane/removeLane | MODERATE rewrite |
| `AudioGraphMapper.swift` | ~500 | Excludes lane nodes, cross-lane transitions | MODERATE rewrite |
| `PerformanceMotherbaseView.swift` | ~650 | focusLane, lane iteration, XY bindings | HEAVY rewrite |
| `SequencerEngine.swift` | 185 | lanesGetter, per-lane iteration | REWRITE |
| `SceneManager.swift` | 265 | Per-lane snapshots + graph snapshots | MODERATE rewrite |
| `ImplicitGraphBuilder.swift` | 178 | LanePreset → NodeGraph | REPURPOSE |
| `MacroNode.swift` | 384 | weak var lane: ResonatorLane? | MODERATE rewrite |
| `PerformanceState.swift` | 531 | LaneSnapshot (deprecated), StepGrid | MODERATE rewrite |
| `WebViewBridge.swift` | 595 | activeLanesOnly, laneId context | LIGHT rewrite |
| `PatchViewCoordinator.swift` | ~300 | activeLanesOnly flag | LIGHT rewrite |
| `Constants.swift` | ~400 | maxLanes, useGraphAudioPath | UPDATE |

---

## 2. Target Architecture

### What we're building (v2.0)

```
NeuralEngine (orchestrator)
  ├── nodeGraph: NodeGraph             ← SOLE source of truth for ALL state
  │     ├── nodes: [UUID: GraphNode]   ← flat namespace, no subgraphs
  │     ├── edges: [UUID: GraphEdge]   ← all connections including feedback cycles
  │     └── metadata                   ← tempo, master volume, project info
  │
  ├── audioGraphMapper                 ← translates FULL graph → AVAudioEngine
  │     ├── dynamicAttach/detach       ← runtime node management with fade-crossfade
  │     └── cycleResolver              ← handles feedback edges (delay-compensated)
  │
  ├── sequencerEngine                  ← reads SequencerNode(s) from graph
  │     └── no lane concept            ← subscribes to graph nodes directly
  │
  ├── sceneManager                     ← snapshots entire graph parameter state
  │     └── no lane concept            ← GraphSnapshot only
  │
  └── NO lanes, NO laneSlots, NO ResonatorLane
```

### Core design principles

1. **One graph, flat namespace.** No laneSubgraphs, no crossLaneEdges. All nodes live in `nodeGraph.nodes`. Connections between any nodes are just `edges`.
2. **Feedback cycles are first-class.** The graph validator allows exactly one cycle pattern: paths that pass through a `FeedbackLoopNode`. This node introduces the required delay (inference latency) that makes the cycle causal.
3. **Dynamic audio topology.** Nodes can be added/removed at runtime using the fade-crossfade algorithm (already implemented: 50ms out → rebuild → 40ms in).
4. **Factory topologies replace presets.** Instead of `LanePreset` enum values, we ship JSON graph files that encode common feedback loop patterns. Users load and modify these.
5. **The SequencerNode is a control-rate node.** It emits gate and parameter-lock signals into the graph. Multiple SequencerNodes can exist, driving different parts of the topology.
6. **The MasterOutputNode is the terminal.** One per graph, always present, handles recording and metering.

### New node: SequencerNode

```
Category: CONTROL
Signal type: gate (output), control (output per p-lock parameter)
Parameters:
  - chainLength: Int (1-64)
  - stepTimeBPM: Float (20-300)
  - advanceMode: .iteration | .time
  - swing: Float (0-1)
  - steps: [StepData] (each step has: active, probability, trigType, parameterLocks)
Ports:
  - IN: clock (gate) — optional external clock
  - IN: reset (gate) — reset to step 0
  - OUT: gate — fires on each active step
  - OUT: p_lock_0..N (control) — parameter lock values, one per bound parameter
Behavior:
  - On each advance (iteration count from connected FeedbackLoopNode, or internal BPM clock):
    - Evaluate step probability
    - If active: emit gate=1.0, emit p-lock control values
    - If skip: emit gate=0.0
  - AdvanceMode.iteration subscribes to a connected FeedbackLoopNode's iterationCount
```

### New node: MasterOutputNode

```
Category: ROUTING
Parameters:
  - volume: Float (0-1)
  - isRecording: Bool
  - limiterThreshold: Float (-0.1 dBTP default)
Ports:
  - IN: audio (stereo)
  - IN: sidechain (audio, optional)
Behavior:
  - Routes to AVAudioEngine mainMixerNode → output
  - Manages AudioRecorder when isRecording toggled
  - Applies brick-wall limiter
  - Provides metering data for UI
```

---

## Phase 0: Preparation & Safety Net

**Goal:** Create a safe branch and ensure we can always revert.

### Steps

1. **Create branch `v2/nodal-migration`** from current `main`.
2. **Tag current state** as `v2.0-final` for rollback.
3. **Verify all existing tests pass:**
   ```bash
   xcodebuild test -project LatentResonator.xcodeproj -scheme LatentResonator -destination 'platform=macOS'
   ```
4. **Document current test coverage** — all 18 test files in `LatentResonatorTests/`.

### Definition of Done
- Branch exists, tag exists, all tests green.

---

## Phase 1: SequencerNode

**Goal:** Create a `SequencerNode` that encapsulates all step-grid logic as a graph node, independent of lanes.

### Why first
The SequencerEngine currently depends on `ResonatorLane` via closures (`lanesGetter`, `focusStepGridGetter`). We need to break this dependency before we can dissolve lanes.

### Files to create
- `Graph/Nodes/SequencerNodes.swift` — new file

### Files to modify
- `SequencerEngine.swift` — rewrite to subscribe to SequencerNode(s) in the graph
- `Graph/GraphNode.swift` — add `.sequencer` to `NodeCategory` enum if not present
- `PerformanceState.swift` — move `StepGrid` struct to `SequencerNodes.swift` (or keep shared)

### Implementation details

#### 1.1 Create SequencerNode

```swift
// Graph/Nodes/SequencerNodes.swift

final class SequencerNode: BaseGraphNode {
    // Inline the StepGrid data (move from PerformanceState.swift lines 334-425)
    // or reference it — but the node OWNS the grid, not a lane.
    
    // Parameters stored in self.parameters dictionary:
    // "chainLength": Int, "stepTimeBPM": Float, "advanceMode": String,
    // "swing": Float, "steps": [[String: Any]] (serialized StepData)
    
    // Ports:
    // Input: "clock" (gate), "reset" (gate)
    // Output: "gate" (gate), "p_lock_0"..."p_lock_15" (control)
    
    // State:
    var currentStepIndex: Int = 0
    var iterationSubscription: AnyCancellable?
    
    // Connect to a FeedbackLoopNode's iterationCount for .iteration advance mode
    func subscribeToIterations(of feedbackNode: FeedbackLoopNode) { ... }
    
    // Advance logic: port from SequencerEngine.advanceLaneToStep() 
    // (SequencerEngine.swift lines 120-156)
    func advance() -> StepOutput { ... }
}
```

#### 1.2 Rewrite SequencerEngine

Current `SequencerEngine` (185 lines) takes closures that reference lanes. Rewrite to:

```swift
final class SequencerEngine {
    private weak var nodeGraph: NodeGraph?
    
    // Instead of lanesGetter, find all SequencerNodes in the graph
    private var sequencerNodes: [SequencerNode] {
        nodeGraph?.nodes.values.compactMap { $0 as? SequencerNode } ?? []
    }
    
    // Subscribe to each SequencerNode (replaces subscribeLaneIterations)
    func subscribeAll() { ... }
    
    // Time-based advance iterates sequencerNodes instead of lanes
    func advanceAllSteps() { ... }
}
```

#### 1.3 Bridge compatibility

During this phase, `ResonatorLane.stepGrid` still exists. Add a **temporary adapter** that syncs SequencerNode ↔ ResonatorLane.stepGrid bidirectionally. This adapter is deleted in Phase 3.

### Tests to write
- `SequencerNodeTests.swift`: advance logic, probability, skip, oneshot, p-lock emission
- Verify existing `SequencerEngine` behavior is preserved

### Definition of Done
- SequencerNode exists and can drive step sequencing independent of any lane
- SequencerEngine reads from graph, not from lanes
- Existing sequencer behavior unchanged (adapter bridges the gap)

---

## Phase 2: Dynamic Audio Graph — Kill H19

**Goal:** Replace the H19 pre-allocation model with dynamic node attachment using fade-crossfade.

### Why this is the critical phase
H19 (NeuralEngine.swift lines 172-174, 318-356) pre-allocates all audio nodes before `engine.start()` and never touches the graph again. This is incompatible with a dynamic node graph where users add/remove nodes at runtime.

### The solution already exists
`AudioGraphMapper.rebuild()` (lines 127-300) already implements:
1. Fade master to 0 (10ms)
2. Stop engine
3. Detach old nodes
4. Attach new nodes
5. Connect edges
6. Start engine
7. Fade master back to 1

The problem is that this path is only used for cross-lane transitions and never for the primary audio path. We promote it to THE audio path.

### Files to modify
- `NeuralEngine.swift` — remove H19 pre-allocation, delegate all audio setup to AudioGraphMapper
- `AudioGraphMapper.swift` — remove lane subgraph exclusion, handle full graph
- `Constants.swift` — remove `maxLanes`, `useGraphAudioPath` toggle

### Implementation details

#### 2.1 Modify AudioGraphMapper to handle ALL nodes

In `AudioGraphMapper.rebuild()` (line 127-300), remove the lane subgraph exclusion:

**Current code (lines 129-137):**
```swift
let laneSubgraphNodeIds = Set(graph.laneSubgraphs.values.flatMap { $0.nodes.keys })
let sorted = graph.topologicalSort()
for nodeId in sorted {
    if let node = graph.nodes[nodeId], !laneSubgraphNodeIds.contains(nodeId) {
        allNodesToAttach.append((nodeId, node))
    }
}
```

**Replace with:**
```swift
let sorted = graph.topologicalSort()
for nodeId in sorted {
    if let node = graph.nodes[nodeId] {
        allNodesToAttach.append((nodeId, node))
    }
}
```

#### 2.2 Add cycle-aware topological sort

The current `topologicalSort()` in NodeGraph must handle feedback cycles. The `FeedbackLoopNode` introduces the cycle — the sort must treat the feedback-return edge as a "back edge" that doesn't participate in ordering.

```swift
// In NodeGraph.swift, modify topologicalSort():
func topologicalSort() -> [UUID] {
    // Mark edges where target is a FeedbackLoopNode's feedback_in port as back-edges
    // These edges are excluded from the DAG sort but are still connected in AVAudioEngine
    // The FeedbackLoopNode internally manages the delay buffer that makes the cycle causal
    let backEdges = edges.values.filter { edge in
        guard let targetNode = nodes[edge.targetNodeId] else { return false }
        return targetNode is FeedbackLoopNode && edge.targetPortId == "feedback_in"
    }
    let forwardEdges = edges.values.filter { !backEdges.contains($0) }
    // ... standard Kahn's algorithm on forwardEdges only
}
```

#### 2.3 Modify NeuralEngine init

**Remove (lines 318-356):** The entire H19 pre-allocation block:
```swift
// DELETE: H19 pre-allocation loop
// for i in 0..<LRConstants.maxLanes {
//     let slot = ResonatorLane(...)
//     audioEngine.attach(slot.combinedSourceNode!)
//     audioEngine.attach(slot.laneMixer)
//     ...
// }
```

**Replace with:**
```swift
// v2.0: Build initial graph topology, then let AudioGraphMapper handle everything
let initialTopology = TopologyTemplates.defaultFeedbackLoop()
nodeGraph.merge(initialTopology)
try audioGraphMapper.rebuild(from: nodeGraph)
try audioEngine.start()
```

#### 2.4 Ensure fade-crossfade is robust

The existing fade-crossfade (AudioGraphMapper lines 178-181, ~470+) does a 10ms fade. For user-initiated topology changes (adding a node in PATCH mode), increase to 50ms for safety:

```swift
func rebuild(from graph: NodeGraph, fadeDuration: TimeInterval = 0.05) throws {
    fadeMaster(to: 0.0, duration: fadeDuration)
    Thread.sleep(forTimeInterval: fadeDuration + 0.005) // margin
    // ... detach, attach, connect ...
    try audioEngine.start()
    fadeMaster(to: 1.0, duration: fadeDuration)
}
```

#### 2.5 Create MasterOutputNode

```swift
// Graph/Nodes/RoutingNodes.swift (append to existing file)

final class MasterOutputNode: BaseGraphNode {
    // Parameters: volume, isRecording, limiterThreshold
    // Ports: IN audio (stereo), IN sidechain (optional)
    // audioUnit() returns the masterMixerNode reference
    // This node is always present in the graph and cannot be deleted
}
```

### Tests to write
- `DynamicGraphTests.swift`: add node at runtime, rebuild, verify audio passes
- `FeedbackCycleTests.swift`: verify topological sort handles cycles correctly
- `FadeRebuildTests.swift`: verify no clicks/pops during rebuild

### Definition of Done
- H19 pre-allocation code deleted
- AudioGraphMapper handles ALL nodes in the graph (no exclusions)
- Nodes can be added/removed at runtime with click-free transitions
- FeedbackLoopNode cycles work in topological sort
- MasterOutputNode exists as the terminal node
- `useGraphAudioPath` toggle deleted — there is only one path

---

## Phase 3: Dissolve ResonatorLane into Graph Patterns

**Goal:** Eliminate `ResonatorLane.swift` entirely by distributing its responsibilities to existing graph nodes.

### Responsibility mapping

| ResonatorLane responsibility | New owner | Notes |
|------------------------------|-----------|-------|
| `combinedSourceNode` (excitation + feedback mix) | Source nodes + FeedbackLoopNode | The mix happens at graph edges, not inside a monolith |
| `laneMixer` (volume/solo/mute) | MixerNode parameters | Each MixerNode has volume, solo, mute params |
| `feedbackBuffer` | FeedbackLoopNode.feedbackBuffer | Already exists in NeuralNodes.swift line 274 |
| `captureBuffer` | FeedbackLoopNode.captureBuffer | Already exists in NeuralNodes.swift line 266 |
| `stepGrid` | SequencerNode (Phase 1) | Fully migrated |
| `rtSnapshot` | Node-level parameter access | Each node reads its own parameters; no global snapshot needed |
| `spectralProcessor` | SpectralChainNode | Already a graph node |
| `inferenceTask` | FeedbackLoopNode + ACEStepBridge | FeedbackLoopNode manages its own inference lifecycle |
| `macroNode` link | MacroNode is standalone | Remove `weak var lane` from MacroNode |
| Preset values | Factory topology JSON files | No more LanePreset enum |
| `name`, `accentColorName` | Node metadata/tags | Nodes can have display name and color |
| `isDrumLane` | SequencerNode parameter or topology variant | Drum topology = different factory template |

### Files to modify

#### 3.1 FeedbackLoopNode upgrade (NeuralNodes.swift)

The existing FeedbackLoopNode (lines 244-438) has the buffers and the render callback, but it currently doesn't manage its own inference lifecycle — that's in ResonatorLane. Move inference management into FeedbackLoopNode:

```swift
// Add to FeedbackLoopNode:

/// Reference to the bridge for inference calls
weak var bridge: ACEStepBridge?

/// Inference task (moved from ResonatorLane lines 1462-1599)
private var inferenceTask: Task<Void, Never>?

/// Start the recursive inference loop
func startInferenceLoop() {
    inferenceTask = Task { [weak self] in
        while !Task.isCancelled {
            guard let self = self else { break }
            // 1. Read from captureBuffer
            // 2. Send to bridge.infer()
            // 3. Write result to feedbackBuffer
            // 4. Increment iterationCount
            self.iterationCount += 1
        }
    }
}

/// Install capture tap on the upstream mixer node
func installCaptureTap(on mixerNode: AVAudioMixerNode) { ... }
```

Port the inference loop logic from `ResonatorLane.swift` (approximately lines 1462-1599, look for `inferenceTask`, `runInferenceLoop`, or similar).

#### 3.2 Remove lane from MacroNode

In `MacroNode.swift` line 18: `weak var lane: ResonatorLane?` — **delete this property** and all references to it.

MacroNode becomes a pure graph abstraction: an encapsulated subgraph with exposed ports. No lane reference.

#### 3.3 NeuralEngine: replace lane array with graph queries

**Delete:**
- `@Published var lanes: [ResonatorLane] = []` (line 59)
- `private var laneSlots: [ResonatorLane] = []` (line 174)
- `var focusLaneId: UUID?` (line 134)
- `var focusLane: ResonatorLane?` computed property (lines 147-152)
- `addLane()` function (lines 841-947)
- `removeLane()` function (lines 952-982)
- `updateLaneMixerState()` (lines 1000-1013)
- `applyLaneStepLocks()` (lines 1080-1133)

**Replace with graph-native equivalents:**

```swift
// NeuralEngine.swift — v2.0

/// The focused MacroNode (replaces focusLane)
@Published var focusMacroId: UUID?

var focusMacro: MacroNode? {
    guard let id = focusMacroId else { return nil }
    return nodeGraph.nodes[id] as? MacroNode
}

/// All FeedbackLoopNodes in the graph (replaces lane iteration)
var feedbackLoops: [FeedbackLoopNode] {
    nodeGraph.nodes.values.compactMap { $0 as? FeedbackLoopNode }
}

/// All SequencerNodes in the graph
var sequencers: [SequencerNode] {
    nodeGraph.nodes.values.compactMap { $0 as? SequencerNode }
}

/// Start all feedback loops (replaces per-lane inference start)
func startAllFeedbackLoops() {
    for loop in feedbackLoops {
        loop.bridge = aceBridge
        loop.startInferenceLoop()
    }
}

/// Apply parameter from MIDI/OSC (replaces applyParameter routing to focusLane)
func applyParameter(_ param: ControlParameter, value: Float) {
    guard let macro = focusMacro else { return }
    macro.setParameter(param.rawValue, value: value)
    nodeGraph.topologyDidChange.send()
}
```

#### 3.4 Delete ResonatorLane.swift

After all responsibilities are migrated, **delete the entire file** (1,889 lines).

Also delete:
- `ImplicitGraphBuilder.swift` — replaced by factory topology JSON files
- `SpectralProcessorShim.swift` — SpectralChainNode handles this directly
- The `LanePreset` enum from wherever it's defined
- The `LaneSnapshot` struct from `PerformanceState.swift` (lines 8-46)

### Tests to write
- `FeedbackLoopNodeInferenceTests.swift`: verify inference loop runs, buffers communicate
- `NeuralEnginev2Tests.swift`: verify engine starts with graph, no lane references
- Run ALL existing tests — many will need updating

### Definition of Done
- `ResonatorLane.swift` deleted
- `ImplicitGraphBuilder.swift` deleted
- No Swift file imports or references `ResonatorLane`
- FeedbackLoopNode manages its own inference lifecycle
- NeuralEngine orchestrates graph nodes directly
- All audio flows through AudioGraphMapper, no separate path

---

## Phase 4: Flatten NodeGraph — Remove Lane Subgraphs

**Goal:** Eliminate `laneSubgraphs`, `crossLaneEdges`, and all lane-scoped logic from NodeGraph.

### Files to modify

#### 4.1 NodeGraph.swift

**Delete these properties:**
- `laneSubgraphs: [UUID: NodeGraph]` (line 31)
- `crossLaneEdges: [UUID: GraphEdge]` (line 35)
- `laneInfo: [UUID: LaneInfo]` (if exists)
- `activeLaneIds: Set<UUID>` (line 50)

**Delete these methods:**
- `addLane(id:name:preset:color:)` (lines 708-726)
- `removeLane(id:)` (lines 739-749)
- `laneIdForNode(_:)` 
- `createCrossLaneEdge(...)`
- `isEdgeConnectedToLane(...)`
- `crossLaneEdgesForLane(_:)`

**Keep/enhance:**
- `addNode()`, `removeNode()`, `addEdge()`, `removeEdge()` — these are the only topology operations
- `topologicalSort()` — updated in Phase 2 for cycle awareness
- `wouldCreateCycle()` — update: cycles are allowed ONLY through FeedbackLoopNode
- Serialization: simplify to flat node/edge lists

#### 4.2 GraphEdge.swift

Remove any `EdgeType` or lane-scoping. An edge is just: sourceNodeId, sourcePortId, targetNodeId, targetPortId, signalType. No lane context.

#### 4.3 WebViewBridge.swift

**Delete:**
- `activeLanesOnly` flag (line 24-26)
- Lane-aware node filtering in `sendFullGraphToJS()` (lines 374-401)
- `laneId` context in node data (line 447-449)

**Replace with:**
- Send ALL nodes in `nodeGraph.nodes` to JS
- MacroNodes render as expandable groups in the React Flow canvas
- No lane filtering — the entire graph is always visible

#### 4.4 PatchViewCoordinator.swift

Remove `activeLanesOnly` references (line 107-110, 250-252, 279-281).

### Tests
- `NodeGraphFlatTests.swift`: verify all operations work on flat graph
- `SerializationTests.swift`: verify JSON round-trip with no lane artifacts

### Definition of Done
- NodeGraph has zero lane-related properties or methods
- WebViewBridge sends flat graph to JS
- All graph operations are lane-agnostic

---

## Phase 5: New UX — Patch-First Interface

**Goal:** Redesign the three-mode interface for a lane-free world.

### Mode redesign

| Mode | v2.0 (current) | v2.0 (target) |
|------|-----------------|----------------|
| **SETUP** | Mixer-level overview, lane strips | **OVERVIEW**: Master meters, global controls, topology thumbnail, recording |
| **PATCH** | Node graph filtered by active lane | **PATCH**: Full node graph, no filtering, MacroNodes as collapsible groups |
| **PERFORM** | Elektron-style per-lane controls | **PERFORM**: Auto-generated surface from ALL exposed parameters across entire graph |

### Files to modify

#### 5.1 PerformanceMotherbaseView.swift — HEAVY rewrite

**Current lane dependencies (remove all):**
- `engine.focusLaneId` (line 62) → replace with `engine.focusMacroId`
- `engine.focusLane?.stepGrid.*` (lines 65-75) → replace with focused SequencerNode
- `engine.lanes` iteration (line 375) → replace with MacroNode iteration
- `LaneTabView` per lane (lines 474-547) → replace with `MacroTabView`
- `FocusLaneStripView` (line 589-650) → reads exposed controls from focused MacroNode (this part mostly works already)
- XY bindings to `lane.texture`, `lane.guidanceScale` (lines 219-230) → bind to MacroNode parameters

**New structure:**

```
PerformanceMotherbaseView
  ├── TopBar
  │     ├── MacroTabRow (replaces laneTabRow)
  │     │     └── MacroTabView per MacroNode (name, color, mute/solo)
  │     └── GlobalControls (master volume, BPM, recording)
  │
  ├── MainArea
  │     ├── StepGridView (reads from focused SequencerNode, not lane.stepGrid)
  │     ├── ExposedControlsGrid (from PerformLayoutEngine — already works with MacroNode)
  │     └── XYPad (bound to focused MacroNode parameters)
  │
  └── BottomBar
        ├── SceneCrossfader (unchanged — works with GraphSnapshot)
        └── TransportControls
```

#### 5.2 AudioVisualizerXYPad.swift

Change `@ObservedObject var lane: ResonatorLane` to accept parameter bindings directly:

```swift
struct AudioVisualizerXYPad: View {
    @Binding var xValue: Float
    @Binding var yValue: Float
    let xLabel: String
    let yLabel: String
    // Remove all lane references
}
```

#### 5.3 RootView.swift

Update mode descriptions. The `syncPatchToScenesOnEnterPerform()` call (lines 54-68) should now sync from NodeGraph directly, not from lanes.

#### 5.4 PatchEditor (React)

**src/App.tsx** — Remove any lane-aware grouping. All nodes render in one flat canvas.

**src/bridge.ts** — Remove lane-scoped messages. Add:
- `topology.loadTemplate` — load a factory topology JSON
- `topology.saveAsTemplate` — save current graph as user template

### Tests
- UI snapshot tests if applicable
- Manual testing of all three modes

### Definition of Done
- All three modes work without any lane reference
- PERFORM reads from MacroNodes and SequencerNodes
- PATCH shows flat graph
- XY pad binds to arbitrary MacroNode parameters

---

## Phase 6: Scene System on Pure Graph

**Goal:** Simplify SceneManager to work exclusively with GraphSnapshot.

### Files to modify

#### 6.1 SceneManager.swift

**Delete:**
- `applyScene(at:lanes:)` — v1.x legacy path (lines 122-149)
- `blendLaneSnapshot()` (lines 154-200)
- `applyCrossfader(sceneAIndex:sceneBIndex:t:lanes:)` (lines 154-200)
- `appendLaneSnapshotToAllScenes()` and `removeLaneSnapshotFromAllScenes()` (lines 238-263)

**Keep/simplify:**
- `applyScene(at:to:nodeGraph)` (lines 17-43) — this is already the v2.0 path
- `captureScene(at:from:nodeGraph:)` — rewrite to iterate ALL nodes (not lanes):

```swift
func captureScene(at index: Int, from graph: NodeGraph) {
    var snapshots: [UUID: GraphSnapshot] = [:]
    for (id, node) in graph.nodes {
        // Capture parameters from every node that has meaningful state
        if node.parameters.values.contains(where: { $0 is Float }) {
            snapshots[id] = GraphSnapshot(from: node)
        }
    }
    sceneBank[index].graphSnapshots = snapshots
}
```

#### 6.2 PerformanceState.swift

**Delete:**
- `struct LaneSnapshot` (lines 8-46) — entirely
- `laneSnapshots` property from `PerformanceScene` (line 83-85)
- Legacy Codable fallback (lines 106-121)

### Definition of Done
- SceneManager has zero lane references
- Scenes capture/apply entire graph state
- Crossfader morphs between full graph snapshots

---

## Phase 7: Factory Topologies — The "Feedback Templates"

**Goal:** Create a library of preset graph topologies that replace LanePreset and embody the whitepaper thesis.

### Concept

Like Envion ships thousands of Dynatext triplet files in `/data`, we ship JSON graph files in `/Topologies` that encode feedback loop patterns. Each is a complete, playable instrument. The user loads one as a starting point and modifies it in PATCH mode.

### Factory topologies to create

#### 7.1 `feedback_basic.json` — The Whitepaper Loop
```
KoenigSeed → LadderFilter → SpectralChain → FeedbackLoopNode
                                                    ↓
                                              ACE-Step Inference
                                                    ↓
                                              (back to FeedbackLoopNode)
                                                    ↓
                                              MixerNode → MasterOutput
Also includes: SequencerNode connected to FeedbackLoopNode iteration count
```

#### 7.2 `feedback_dual.json` — Cross-Feedback
```
Two parallel feedback loops where Loop A's spectral analysis
modulates Loop B's guidance scale, and vice versa.
```

#### 7.3 `feedback_granular.json` — Microsound Textures
```
NoiseSource → SpectralGranularity → FeedbackLoopNode → SpectralFreeze → MasterOutput
SequencerNode drives granularity and freeze parameters via p-locks
```

#### 7.4 `feedback_drone.json` — Spectral Drone
```
Silence → SpectralMemory → FeedbackLoopNode → DelayLine → MasterOutput
The loop generates from nothing — pure generative degradation
```

#### 7.5 `feedback_drum.json` — Rhythmic Machine
```
KoenigSeed → BitCrusher → FeedbackLoopNode → WaveShaper → MasterOutput
SequencerNode with drum-focused p-locks (bitcrush depth, waveshape amount)
Short inference buffer (ULTRA mode)
```

#### 7.6 `feedback_external.json` — Live Input Processing
```
AudioInput → LadderFilter → FeedbackLoopNode → SpectralChain → MasterOutput
Process external audio through the neural feedback loop
```

### Implementation

```swift
// TopologyTemplates.swift (new file)
enum TopologyTemplates {
    static func load(_ name: String) -> NodeGraph {
        guard let url = Bundle.main.url(forResource: name, withExtension: "json",
                                         subdirectory: "Topologies") else { fatalError() }
        let data = try! Data(contentsOf: url)
        return try! JSONDecoder().decode(NodeGraph.self, from: data)
    }
    
    static func defaultFeedbackLoop() -> NodeGraph {
        load("feedback_basic")
    }
    
    static func allTemplates() -> [(name: String, description: String)] {
        // List all JSON files in Topologies/
    }
}
```

### PatchEditor integration

Add a "Load Template" panel in PATCH mode:
- User sees thumbnail + description of each factory topology
- Loading replaces current graph (with confirmation)
- "Save as Template" lets users save their own

### Definition of Done
- At least 6 factory topology JSON files exist and load correctly
- Users can browse and load topologies from PATCH mode
- Each topology is a playable instrument out of the box
- Default topology loads on first launch

---

## Phase 8: Cleanup & Delete Legacy Code

**Goal:** Remove every trace of the lane architecture.

### Files to DELETE entirely
- `ResonatorLane.swift` (1,889 lines)
- `ImplicitGraphBuilder.swift` (178 lines)
- `SpectralProcessorShim.swift` (if it exists as separate file)

### Code to DELETE from surviving files
- `NeuralEngine.swift`: all lane-related properties, methods, closures (~400 lines)
- `NodeGraph.swift`: laneSubgraphs, crossLaneEdges, addLane/removeLane (~150 lines)
- `AudioGraphMapper.swift`: lane exclusion logic, cross-lane transition (~80 lines)
- `Constants.swift`: `maxLanes`, `useGraphAudioPath`, `defaultLaneCount` (~30 lines)
- `PerformanceState.swift`: `LaneSnapshot`, legacy codable (~150 lines)
- `SceneManager.swift`: lane snapshot methods (~100 lines)
- `WebViewBridge.swift`: `activeLanesOnly`, lane filtering (~30 lines)

### Verification

```bash
# Verify no lane references remain
grep -rn "ResonatorLane\|laneSlots\|focusLane\|addLane\|removeLane\|LanePreset\|LaneSnapshot\|laneSubgraphs\|crossLaneEdges\|isDrumLane\|laneMixer" \
  --include="*.swift" LatentResonator/
# Should return 0 results
```

### Final test suite
- All existing tests updated or replaced
- New integration test: load factory topology → start inference → verify audio output
- New UI test: three modes navigate correctly

### Definition of Done
- `grep` returns zero lane references in Swift code
- All tests pass
- App launches with factory topology, all three modes work
- Estimated total lines deleted: ~2,500+
- Estimated total lines added: ~800 (SequencerNode, MasterOutputNode, TopologyTemplates, factory JSONs)

---

## Risk Register

| Risk | Impact | Mitigation |
|------|--------|------------|
| **Audio glitches during dynamic rebuild** | Users hear clicks/pops when adding nodes | Fade-crossfade already exists; increase fade time; pool frequently-used AVAudioNodes |
| **Feedback cycle causes infinite gain** | Runaway audio levels | FeedbackLoopNode already has gain parameter; add hard limiter in MasterOutputNode; add automatic mute on RMS > threshold |
| **Performance regression** | More nodes = more CPU | Profile with Instruments; the flat graph should actually be MORE efficient than the current dual-path system |
| **Loss of user patches** | v2.0 saved graphs can't load | Write a one-time migration that converts v2.0 serialized graphs (with laneSubgraphs) to flat v2.0 format |
| **Topological sort breaks on complex graphs** | Crash or incorrect node ordering | Comprehensive unit tests for cycle-aware sort; back-edge detection is well-understood CS |
| **Inference latency variance** | FeedbackLoopNode underruns | Already handled: loop buffer sustains previous output during underrun (NeuralNodes.swift line 398-412) |

---

## File Reference Map

Quick lookup for the executing LLM agent:

```
Root: /LatentResonator/LatentResonator/

CORE (heavy modification):
  NeuralEngine.swift              — Central orchestrator, lane owner → graph orchestrator
  ResonatorLane.swift             — DELETE ENTIRELY after Phase 3

GRAPH (moderate modification):
  Graph/NodeGraph.swift           — Remove lane subgraphs, flatten
  Graph/AudioGraphMapper.swift    — Remove lane exclusion, handle all nodes
  Graph/GraphNode.swift           — Add SequencerNode category
  Graph/GraphEdge.swift           — Remove lane-scoped edge types
  Graph/MacroNode.swift           — Remove weak lane reference
  Graph/ImplicitGraphBuilder.swift — DELETE (replaced by factory topologies)

NODES (add new, modify existing):
  Graph/Nodes/NeuralNodes.swift   — Upgrade FeedbackLoopNode with inference lifecycle
  Graph/Nodes/SequencerNodes.swift — NEW: SequencerNode
  Graph/Nodes/RoutingNodes.swift  — Add MasterOutputNode

ENGINE:
  SequencerEngine.swift           — Rewrite: graph-native, no lane closures

CONFIG:
  Config/Constants.swift          — Remove maxLanes, useGraphAudioPath
  Config/PerformanceState.swift   — Remove LaneSnapshot, keep GraphSnapshot + StepGrid

SCENES:
  SceneManager.swift              — Simplify: graph-only snapshots

VIEWS (moderate-heavy rewrite):
  Views/RootView.swift            — Update mode transitions
  Views/PerformanceMotherbaseView.swift — Replace lane iteration with MacroNode iteration
  Views/AudioVisualizerXYPad.swift — Remove lane dependency, use bindings

WEBVIEW:
  WebView/WebViewBridge.swift     — Remove activeLanesOnly
  WebView/PatchViewCoordinator.swift — Remove lane filtering

REACT:
  PatchEditor/src/App.tsx         — Remove lane grouping
  PatchEditor/src/bridge.ts       — Add topology load/save messages

NEW FILES:
  TopologyTemplates.swift         — Factory topology loader
  Topologies/*.json               — Factory topology files (6+)
  Graph/Nodes/SequencerNodes.swift — SequencerNode implementation
```

---

## Execution Order Summary

```
Phase 0  →  Branch + safety net
Phase 1  →  SequencerNode (decouple first dependency)
Phase 2  →  Dynamic audio graph (kill H19 — the big one)
Phase 3  →  Dissolve ResonatorLane (the cathartic one)
Phase 4  →  Flatten NodeGraph (cleanup graph model)
Phase 5  →  New UX (make it usable)
Phase 6  →  Scene system (cleanup scenes)
Phase 7  →  Factory topologies (make it playable)
Phase 8  →  Delete legacy code (make it clean)
```

Each phase has its own Definition of Done and is independently testable. An LLM agent should complete one phase fully (including tests) before moving to the next.

---

*Last updated: 2026-04-13*
*Author: Claude (from architectural analysis session with Leo)*
