# Node Graph Engine — Current Architecture

**Trigger phrases:** "node graph", "dataflow", "canvas", "PatchCanvasView", "DSPNode", "GraphAudioEngine", "ExecutionPlan", "exposed controls", "macro-node", "NodeFactory"

**Purpose:** Describe the node-graph engine **as it exists in code today**. This is not a design doc for a future migration — the migration is done. Code is truth; if this file and the source disagree, the source wins and this file is stale.

---

## MANDATORY FIRST STEP

Read the real source before touching anything:

```
LatentResonator/LatentResonator/Graph/Engine/DSPNode.swift
LatentResonator/LatentResonator/Graph/Engine/GraphAudioEngine.swift
LatentResonator/LatentResonator/Graph/Engine/ExecutionPlan.swift
LatentResonator/LatentResonator/Graph/NodeGraph.swift
LatentResonator/LatentResonator/Graph/GraphNode.swift
LatentResonator/LatentResonator/Graph/Nodes/FilterEffectNodes.swift   (DelayLineNode = the pattern to copy)
```

`docs/ARCHITECTURE_v2_NODAL.md`, `docs/E2E_COHESION_ANALYSIS.md`, and `docs/IMPLEMENTATION_VERIFICATION.md` are **superseded** (WKWebView/React-Flow/AudioGraphMapper era). Do not treat them as canonical. **Source of truth:** `LatentResonator/LatentResonator/Graph/` (`NodeGraph.swift` first).

---

## THE TWO UI MODES (NOT THREE)

`RootView.swift` — `enum AppMode { case canvas, perform }`. There is no SETUP mode and no separate PATCH-vs-SETUP split.

- **CANVAS** — `PatchCanvasView` (native SwiftUI, `Views/Patch/PatchCanvasView.swift`). One surface for editing *and* playing: a `PatchLockMode` toggle (`.unlocked` / `.locked`, `Views/Patch/PatchTypes.swift`) gates structural edits without switching views. Cards (`NodeCardFactory.swift`) render each `GraphNode`; `CableLayer.swift` draws Bézier cables between port chips. Node position (`x`, `y`) lives on the node itself and persists via `NodeGraphStore`.
- **PERFORM** — `PerformanceMotherbaseView` (scenes, crossfader, Elektron-style step sequencer, auto-generated control surface from `exposedControls`).

`NodeGraph` is the single source of truth. Both views project from it; nothing else owns state.

---

## THE RENDER ENGINE: PULL-RENDER, NOT AVAUDIOENGINE GRAPH-BUILDING

This is the part agents most often get wrong. **AVAudioEngine is used only for I/O** — one `AVAudioSourceNode` (owned by `GraphAudioEngine`) is attached to it, connected straight to the master mixer. Every node in the patch, every mix, every filter runs *inside that one source node's render callback* by walking a pre-built `ExecutionPlan`. This is the same model as Reaktor, Max/MSP, SuperCollider, VCV Rack.

```
NodeGraph (topology, main thread)
      │  topologyDidChange
      ▼
ExecutionPlan.build(from:frameCapacity:)   — topological sort + buffer-slot assignment
      │
      ▼
GraphAudioEngine.adopt(plan)               — os_unfair_lock_trylock swap, audio thread never blocks
      │
      ▼
AVAudioSourceNode render callback          — walks plan.steps, calls step.dspNode.render(...)
```

### The pieces

- **`DSPNode`** (`Graph/Engine/DSPNode.swift`) — the ONLY interface the audio thread calls. `nodeId`, `render(inputs:output:frameCount:sampleRate:controls:)`, `reset()`. AVFoundation-free. Real-time contract: no allocation, no locks that can be held from the main thread (use `os_unfair_lock_trylock`), no blocking I/O, no `print`.
- **`GraphNodeDSPProvider`** (`Graph/Engine/ExecutionPlan.swift`) — `func dspNode() -> DSPNode?`. A node "participates" in audio by returning non-nil here. Nodes that return nil (e.g. `ACEStepInferenceNode`, `PromptEngineNode`) are silently skipped by the plan builder — they exist in the graph as parameter surfaces / control sources only.
- **`ExecutionPlan`** (`Graph/Engine/ExecutionPlan.swift`) — immutable snapshot of render order. `Step.inputBufferIndices` come from audio edges into a node **sorted by `targetPortId`** (so a node with ports `"feedback_in"` and `"in"` gets `feedback_in` at index 0 and `in` at index 1 when both are wired — never assume `inputs.first` is the primary signal; resolve by counting or by port order). One node becomes the terminal step (`MasterOutputNode`, or the last leaf) and writes directly into the AVAudioEngine's `AudioBufferList` via `ExecutionPlan.terminalSlot`.
- **`GraphAudioEngine`** (`Graph/Engine/GraphAudioEngine.swift`) — owns the root `AVAudioSourceNode` and the `os_unfair_lock`-guarded `currentPlan`. `adopt(_:)` swaps plans atomically; the audio thread renders one buffer of silence if it can't acquire the trylock mid-swap (inaudible). `resetAllNodes()` calls `DSPNode.reset()` on every step's node.
- **`BufferPool`** (`Graph/Engine/BufferPool.swift`) / **`AudioBuffer`** (`Graph/Engine/AudioBuffer.swift`) — one contiguous pre-allocated heap block sliced into stereo `(left, right)` pointer pairs. Reused every callback; never touches the allocator on the audio thread.
- **`ControlGraphEvaluator`** (`Graph/ControlGraphEvaluator.swift`, 60Hz timer) — wired in `NeuralEngine` for LFO/MetaParameter CV routing into node parameters via control edges. `ExecutionPlan.Step.controls` remains empty (parameters read on next `DSPNode.render` from the graph store).

`NeuralEngine.rebuildAudioGraphIfNeeded()` is the only call site that builds a plan and adopts it (on init and on every `topologyDidChange`).

---

## HOW A NEW AUDIO-PARTICIPATING NODE IS WIRED (COPY THIS PATTERN)

Mirror `DelayLineNode` in `Graph/Nodes/FilterEffectNodes.swift` exactly:

```swift
final class MyNode: BaseGraphNode {
    var myParam: Float {
        get { getParam("myParam", default: 0.5) }
        set { setParam("myParam", value: newValue) }
    }

    // pre-allocated state goes here — never allocate in render()

    init(id: UUID = UUID(), params: [String: Any] = [:]) {
        super.init(id: id, nodeType: "my_node", category: .effect, displayName: "MY NODE")
        for (key, value) in params { parameters[key] = value }
    }

    required init(from decoder: Decoder) throws { try super.init(from: decoder) }

    override var ports: [NodePort] {
        [
            NodePort(id: "in", label: "IN", signalType: .audio, direction: .input),
            NodePort(id: "out", label: "OUT", signalType: .audio, direction: .output)
        ]
    }
}

extension MyNode: GraphNodeDSPProvider, DSPNode {
    var nodeId: UUID { id }
    func dspNode() -> DSPNode? { self }

    func render(
        inputs: UnsafeBufferPointer<AudioBuffer>,
        output: AudioBuffer,
        frameCount: Int,
        sampleRate: Double,
        controls: [String: Float]
    ) {
        guard let inBuf = inputs.first else {
            for i in 0..<frameCount { output.left[i] = 0; output.right[i] = 0 }
            return
        }
        // ... DSP, writing into output.left / output.right ...
    }

    func reset() { /* clear internal state */ }
}
```

Then register the node type string in `NodeFactory.createNode(...)` (bottom of `NodeGraph.swift`) and add a `case` to `NodeCategory` color mapping if it's a new category (`GraphNode.swift`).

**Ignore `GraphNode.audioUnit() -> AVAudioNode?`.** It is still declared on the protocol and default-returns `nil` in `BaseGraphNode`, and a couple of not-yet-migrated nodes (`SpectralChainNode`) still override it — but **nothing in the current engine calls `.audioUnit()` to attach anything to `AVAudioEngine`.** It is a dead vestige of the abandoned `AudioGraphMapper` design (see DELETED section below). Do not implement new nodes by overriding it.

---

## SIGNAL TYPES

```swift
enum SignalType: String, Codable {
    case audio, control, trigger, gate
}
```

Validated in `NodeGraph.validateConnection(from:to:)`: type match, output→input direction, audio inputs accept exactly one connection, control inputs accept many, cycles are rejected unless the target node's `nodeType == "feedback_loop"`.

---

## NEURAL NODES — THE HYBRID PATTERN

`Graph/Nodes/NeuralNodes.swift`. This is the one place where the render graph touches async neural inference, and it does so **without ever blocking the audio thread**:

- **`FeedbackLoopNode`** — the only neural-adjacent node that conforms to `DSPNode`. `render()` does pointer-based `captureBuffer.write` / `feedbackBuffer.read` against its two `CircularAudioBuffer`s (lock-free SPSC) and a cheap `os_unfair_lock_trylock` check to fire at most one inference `Task` at a time. It never calls `await` from inside `render()`.
- **`ACEStepInferenceNode`** — a **parameter surface only**. It does not conform to `DSPNode` / `GraphNodeDSPProvider` and is silently skipped by `ExecutionPlan.build`. It holds `prompt`, `guidanceScale`, `numSteps`, `inputStrength`, `entropy`, `granularity`, `taskType`, `thinking`, and a `bridge: ACEStepBridge?` reference. `FeedbackLoopNode` reads a parameter snapshot from it via a weak `inferenceNode` reference — that's the entire coupling between the two node types.
- Bridge injection flows `NeuralEngine.aceBridge` → `NodeGraph.aceBridge` → `NodeFactory.createNode(bridge:)`. `NodeGraph` also runs an idempotent wiring pass that connects any `FeedbackLoopNode` to an available `ACEStepInferenceNode` and assigns `.bridge`, so graphs built without a hand-authored edge between the two still work.
- No model loaded / bridge unavailable → `FeedbackLoopNode` passes the dry signal straight through. This is intentional graceful degradation, not a bug.

**Do not make `ACEStepInferenceNode` itself a blocking `DSPNode`.** A synchronous `await bridge.infer(...)` inside `render()` would stall the audio thread for the multi-second inference duration.

---

## MARKED DELETED — DO NOT RESURRECT

These were part of the pre-pull-render design (`docs/ARCHITECTURE_v2_NODAL.md`, `docs/ROAD_TO_V2_GAPS_2026-04-14.md`) and are gone or dead:

- **`AudioGraphMapper`** — the "rebuild AVAudioEngine topology on every mutation" approach. Replaced by `GraphAudioEngine` + `ExecutionPlan` (atomic plan swap, no engine restart, no click-fade dance).
- **`WKWebView` / React Flow patch editor** — `WebViewBridge.swift`, `PatchViewCoordinator.swift`, `AudioVisualizerHTML.swift`, and the bundled `PatchEditor` React/TypeScript project have been removed from the Xcode target entirely — and from the repo on 2026-07-27 (`git rm`, recoverable from git history). `PatchCanvasView` (native SwiftUI) is the canvas. Don't recreate any of this. (`AudioVisualizerXYPad.swift` is an unrelated, still-live `WKWebView` used only for the waveform/FFT visualizer inside PERFORM mode — not the patch canvas. Don't conflate the two.)
- **`ResonatorLane`** — per-lane fixed-topology class. Replaced by `MacroNode` (an encapsulated subgraph) + the flat node types in `Graph/Nodes/`. If you see a doc mention `ResonatorLane.swift`, the doc is stale.
- **Per-node `AVAudioNode` wiring via `installTap`/`AVAudioSourceNode` fan-out between graph nodes** — that pattern belongs to `SpectralChainNode`, which is mid-migration and explicitly out of scope for unrelated changes. Don't copy its `installUpstreamTap`/`sourceNode` pattern into new nodes; copy `DelayLineNode` instead.

---

## CHECKLIST: ADDING A NODE

- [ ] Class extends `BaseGraphNode`, params via `getParam`/`setParam` (backed by `parameters: [String: Any]`)
- [ ] `ports` overridden with correct `SignalType` per port
- [ ] Pre-allocate all DSP state in `init`/`init(from:)` — never in `render`
- [ ] Conform to `GraphNodeDSPProvider` + `DSPNode` in an extension (mirror `DelayLineNode`), or deliberately omit it if the node is a parameter surface / control source only
- [ ] `NodeFactory.createNode(...)` has a `case` for the new `nodeType` string
- [ ] No `.audioUnit()` override unless you are specifically continuing the `SpectralChainNode` migration
- [ ] No new `Task`, `Timer`, or polling loop spawned unconditionally from `init` — trigger-based, not eager

---

## KEY INVARIANTS (NEVER VIOLATE)

1. `NodeGraph` is the single source of truth — CANVAS and PERFORM are projections.
2. The audio thread only ever calls `DSPNode.render`/`reset()` through an `ExecutionPlan` snapshot — never touches `NodeGraph` directly.
3. Plan swaps are atomic (`os_unfair_lock_trylock`) — never block the audio thread waiting for the main thread.
4. Neural inference is async and triggered, never polled or blocking inside `render()`.
5. Graceful degradation: no bridge / no model → passthrough, never silence-by-crash.
6. Signal types are enforced on every edge; only `feedback_loop` nodes may close a cycle.
