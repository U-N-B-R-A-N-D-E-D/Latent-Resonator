# Latent Resonator — Road to v2: Gap Report & Recovery Plan

> **Superseded.** This gap report describes the `AudioGraphMapper` / React-Flow-in-WKWebView recovery path, which was abandoned. The shipped architecture is pull-render + native canvas (`GraphAudioEngine` → `ExecutionPlan` → `DSPNode`, `PatchCanvasView`). See `README.md` and `.cursor/skills/v2-node-graph/SKILL.md`; code is truth.

> **Date:** 2026-04-14
> **Status:** Migration partially executed. No audio, no usable PERFORM mode. Build probably compiles but runtime is dead.
> **Purpose:** Concrete, ordered list of actionables to restore audio and usability. Written to be executed by an LLM agent.

---

## Executive Diagnosis

The Road to v2 migration was executed **out of order relative to `ROAD_TO_V2.md`** (formerly `MIGRATION_V3_NODAL.md`). The critical mistake was deleting `ResonatorLane.swift` (Phase 3) and gutting `PerformanceMotherbaseView.swift` (part of Phase 5) **before** the dynamic audio graph (Phase 2) was verified end-to-end, and **before** the factory topology loader (Phase 7) was validated.

The result is a codebase where:

- **The nodes exist** (40+ implementations in `Graph/Nodes/`)
- **The graph infrastructure exists** (`NodeGraph.swift` 1038 lines, `AudioGraphMapper.swift` 496 lines)
- **The React PATCH editor works** (built, bridged, functional)
- **But nothing runs.** The audio engine starts with an empty graph because:
  1. The factory topology JSON can't be deserialized (format mismatch + `ClosedRange<Float>` not Codable)
  2. `MasterOutputNode.audioUnit()` returns nil because `mainMixer` is never wired in
  3. Connectivity validation then throws because no node is recognized as an audio output
- **And nothing is playable.** `PerformanceMotherbaseView` was reduced from 1,273 lines to an 80-line "Migration in Progress" placeholder. There is no XY pad, no step grid, no scene crossfader, no trigger button, no meters.

The good news: **every piece needed exists** somewhere. `PerformanceMotherbaseView.swift.backup_v1` is the v1.x PERFORM implementation. `PerformLayoutEngine.swift` (211 lines) already computes adaptive layouts from exposed controls. `MacroBindingsPanel.swift` is scaffolded. The React PATCH editor is complete. The 40+ node classes are implemented with audio units. What's missing is the **plumbing between them** — and that plumbing is a small amount of work once it's identified precisely.

---

## Part A — Critical Path to First Audio

**Goal:** Launch the app, load the Kickstart topology, hear a sine wave coming out of the speakers. Nothing more.

Execute these in order. Each is small. Audio should work after A.7.

### A.1 — Fix `ClosedRange<Float>` Codable in `ExposedControl`

**File:** `LatentResonator/LatentResonator/Graph/NodeGraph.swift` (~line 837)

**Problem:** `ExposedControl.range: ClosedRange<Float>` — `ClosedRange` is not `Codable` by default. Any JSON decode of an exposed control throws before we even reach the audio setup.

**Fix:** Add a custom `Codable` conformance that serializes as `{ "lower": Float, "upper": Float }`.

```swift
extension ClosedRange: Codable where Bound: Codable {
    enum CodingKeys: String, CodingKey { case lower, upper }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let lower = try c.decode(Bound.self, forKey: .lower)
        let upper = try c.decode(Bound.self, forKey: .upper)
        self = lower...upper
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(lowerBound, forKey: .lower)
        try c.encode(upperBound, forKey: .upper)
    }
}
```

Place this in a new file `Graph/Extensions/ClosedRange+Codable.swift` and add it to the xcodeproj.

**Verification:** Unit test that encodes/decodes `20.0...20000.0` round-trip.

---

### A.2 — Fix `KickstartTemplate.json` parameter format

**File:** `LatentResonator/LatentResonator/Resources/KickstartTemplate.json`

**Problem:** JSON encodes parameters as `{ "type": "float", "value": 220.0 }` but `SerializedGraph.deserialize()` in `NodeGraph.swift` (around line 682-708) expects `CodableValue` enum format.

**Decision:** Pick ONE format and make it the canonical serialization. Two options:

**Option 1 (recommended): Change the JSON** to match `CodableValue` directly. Most compact:
```json
"parameters": {
  "frequency": 220.0,
  "amplitude": 0.5,
  "waveform": "saw",
  "pitchDrift": 0.02,
  "driftRate": 0.1
}
```
This works if `CodableValue` has a discriminator-free decode (tries float, then string, etc.).

**Option 2: Change the decoder** to understand the `{type, value}` object format. More verbose but type-safe.

**Recommended path:** Option 1 — update `KickstartTemplate.json` and verify `CodableValue.init(from decoder:)` handles untagged primitives. If it doesn't, implement that first.

**Verification:** Add a unit test `KickstartTemplateLoadTests.testLoadKickstartProducesNonEmptyGraph()`.

---

### A.3 — Fix `MasterOutputNode.audioUnit()` to return a real node

**File:** `LatentResonator/LatentResonator/Graph/Nodes/RoutingNodes.swift` (lines 91-150)

**Problem:** `MasterOutputNode.mainMixer` is declared as `private weak var mainMixer: AVAudioMixerNode?` but is never initialized. `audioUnit()` returns nil. Consequences cascade: `AudioGraphMapper` can't attach it, can't identify it as an output, connectivity check fails.

**Fix:** `MasterOutputNode` must own its own `AVAudioMixerNode` strongly, created in `init()`:

```swift
final class MasterOutputNode: BaseGraphNode {
    // Strong reference - master mixer is owned by this node
    private let mixer = AVAudioMixerNode()

    override init(id: UUID = UUID(), name: String = "Master Out", position: CGPoint = .zero) {
        super.init(id: id, name: name, position: position)
        // Register params: volume, limiterThreshold
        setParam("volume", value: Float(1.0))
        setParam("limiterThreshold", value: Float(-0.1))
    }

    override func audioUnit() -> AVAudioNode? {
        return mixer
    }

    override var ports: [NodePort] {
        [
            NodePort(id: "in", name: "IN", direction: .input, signalType: .audio)
        ]
    }
}
```

Then in `AudioGraphMapper.rebuild()`, after attaching the master output, **explicitly connect it to `avEngine.mainMixerNode`**:

```swift
// Near the end of rebuild(), after all nodes are attached and edges connected:
for (nodeId, node) in allNodesToAttach {
    if node is MasterOutputNode, let output = node.audioUnit() {
        avEngine.connect(output, to: avEngine.mainMixerNode, format: audioFormat)
    }
}
```

**Verification:** Runtime check — after `rebuild()` succeeds, `mapper.attachedAudioNodes` must contain the master output UUID.

---

### A.4 — Fix `AudioGraphMapper.isGraphConnected()` to recognize outputs

**File:** `LatentResonator/LatentResonator/Graph/AudioGraphMapper.swift` (lines 59-96)

**Problem:** The function looks for "nodes with no outgoing audio edges and a non-nil audioUnit()" to identify outputs. With A.3 fixed, this should now find the `MasterOutputNode`. But the logic is fragile — it fails silently if no output is found.

**Fix:**
1. After A.3, verify the function works. Add an explicit check for `MasterOutputNode` type as well:

```swift
let outputNodes = graph.nodes.values.filter { node in
    if node is MasterOutputNode { return true }
    let hasOutgoingAudio = graph.edges.values.contains { edge in
        edge.sourceNodeId == node.id && edge.signalType == .audio
    }
    return !hasOutgoingAudio && node.audioUnit() != nil
}
```

2. Replace the silent failure with a clear error:

```swift
guard !outputNodes.isEmpty else {
    throw MapperError.invalidConfiguration(
        "No MasterOutputNode found in graph. Every graph must have exactly one MasterOutputNode."
    )
}
```

**Verification:** Delete the master output from the test graph — rebuild should throw a clear error, not silently return.

---

### A.5 — Remove the silent early-return in `AudioGraphMapper.rebuild()`

**File:** `LatentResonator/LatentResonator/Graph/AudioGraphMapper.swift` (lines 147-149)

**Problem:**
```swift
if audioNodesToAttach.isEmpty && attachedAudioNodes.isEmpty {
    print("AudioGraphMapper: No audio nodes to manage, skipping rebuild")
    return
}
```
This makes empty-graph failures invisible. The engine "starts" but nothing is connected.

**Fix:** Throw instead of returning silently:

```swift
if audioNodesToAttach.isEmpty {
    throw MapperError.invalidConfiguration(
        "Graph has no audio nodes to attach. Load a topology first."
    )
}
```

**Verification:** Start with an empty graph — should now throw with a clear message.

---

### A.6 — Ensure a topology actually loads on startup

**File:** `LatentResonator/LatentResonator/NeuralEngine.swift` (around line 1150-1177 — `loadGraphOrBootstrap`)

**Problem:** The bootstrap function silently falls through to "empty graph" if both saved graph and KickstartTemplate fail to load. Combined with A.5, this is now a loud error — which is what we want.

**Fix:** With A.1, A.2, A.3 fixed, `KickstartTemplate.json` should deserialize successfully. Verify by:

1. Adding explicit logging at each bootstrap step:
```swift
private func loadGraphOrBootstrap() {
    print(">> NeuralEngine: Attempting to load saved graph...")
    if let saved = try? NodeGraphStore.loadLatest() {
        nodeGraph.merge(saved)
        print(">> NeuralEngine: Loaded saved graph with \(saved.nodes.count) nodes.")
        return
    }
    print(">> NeuralEngine: No saved graph. Loading KickstartTemplate...")
    do {
        let kickstart = try loadKickstartTemplate()
        nodeGraph.merge(kickstart)
        print(">> NeuralEngine: Loaded Kickstart with \(kickstart.nodes.count) nodes.")
    } catch {
        fatalError(">> NeuralEngine: FATAL: Cannot load any topology. Error: \(error)")
    }
}
```

`fatalError` is deliberate here — during early recovery we want crashes with clear messages, not silent failures. Remove the `fatalError` once stability is restored and replace with a user-facing "Load Template" dialog.

**Verification:** Run the app. Console should print "Loaded Kickstart with 4 nodes." If it prints an error, trace back to A.1/A.2/A.3.

---

### A.7 — Verify the Kickstart topology is audio-complete

**File:** `LatentResonator/LatentResonator/Resources/KickstartTemplate.json`

The Kickstart has: `Oscillator → LadderFilter → Mixer → MasterOutput`. After A.1-A.6 are fixed, this should produce a continuous saw wave at 220 Hz when the engine starts.

**If it doesn't make sound after all the fixes above**, the issue is in one of:

1. **`OscillatorNode.audioUnit()`** — verify it returns a working `AVAudioSourceNode` that actually renders. Read `SourceNodes.swift` lines 9-137. Test in isolation:
   ```swift
   let osc = OscillatorNode(id: UUID())
   osc.frequency = 440
   let engine = AVAudioEngine()
   engine.attach(osc.audioUnit()!)
   engine.connect(osc.audioUnit()!, to: engine.mainMixerNode, format: nil)
   try engine.start()
   // Should hear a sine wave
   ```

2. **`LadderFilterNode.audioUnit()`** — same isolation test, wire in between osc and main.

3. **Parameter initialization** — the oscillator parameters might be at zero amplitude. Confirm `OscillatorNode.init` sets `amplitude > 0`, `frequency > 20`, and the render callback reads them.

4. **`FeedbackLoopNode` starting prematurely** — `NeuralNodes.swift` line 337 auto-starts the inference task in `init()`. For the Kickstart topology there's no FeedbackLoop, so this shouldn't matter — but if Kickstart is later upgraded to include one, the auto-start may cause issues. Remove auto-start from init; let `NeuralEngine.startProcessing()` call `startInferenceLoop()` explicitly on every FeedbackLoopNode after `rebuild()` succeeds.

**Definition of "first audio":** Launch app → audio engine starts → 220 Hz saw wave is audible → no exceptions in console.

---

## Part B — Critical Path to First Usable PERFORM Mode

**Goal:** User can see the macro(s), tweak parameters, start/stop processing, and visualize output.

This assumes Part A is complete and audio flows.

### B.1 — Restore `PerformanceMotherbaseView` from backup, minimally

**File:** `LatentResonator/LatentResonator/Views/PerformanceMotherbaseView.swift`
**Backup:** `LatentResonator/LatentResonator/Views/PerformanceMotherbaseView.swift.backup_v1` (1,273 lines)

**Strategy:** Do **not** copy the entire backup. It references `ResonatorLane` directly and will fail to compile. Instead, **rebuild it section by section** using the compatibility shims already present in `NeuralEngine.swift` (lines 132-136: `focusLane`, `focusLaneId` now return `MacroNode`).

Create the new view in 5 progressive passes. Each pass must compile and run before moving to the next.

**B.1.1 — Pass 1: Macro tab row (replaces lane tabs)**
- Read `PerformanceMotherbaseView.swift.backup_v1` lines 302-398 (`laneTabsSection`)
- Port to iterate `engine.macroNodes` instead of `engine.lanes`
- Each tab shows: macro name, mute/solo buttons reading from macro parameters
- Focus-selection writes to `engine.focusMacroId`
- **DoD:** Tabs render, clicking switches focus, no crash.

**B.1.2 — Pass 2: Status bar**
- Port lines 399-430 of backup (`statusBar`)
- Show: bridge status (from `engine.bridgeProcess`), BPM (from global state), current focus macro name, processing on/off
- Bottom of view, fixed height
- **DoD:** Status reflects real state, updates live.

**B.1.3 — Pass 3: Trigger button + start/stop**
- Port lines 340-398 of backup (`triggerButton`)
- Big obvious button that calls `engine.startProcessing()` / `engine.stopProcessing()`
- Also shows CPU/DSP meter if available
- **DoD:** User can start and stop audio from the UI.

**B.1.4 — Pass 4: XY Pad bound to focus macro parameters**
- Use existing `AudioVisualizerXYPad.swift`
- Hook it to `engine.focusMacro?.parameters` using generic bindings
- Axis selector: let user pick which parameter goes on X and which on Y from the macro's exposed controls
- **DoD:** Moving the pad changes audio in real time.

**B.1.5 — Pass 5: PerformLayoutEngine integration**
- `Views/PerformLayoutEngine.swift` (211 lines) already exists and is functional
- Call it with `engine.focusMacro?.exposedControls ?? []` to compute a layout
- Render the layout below the XY pad using `RetroKnob`, `LatentXYPad`, toggles, etc.
- **DoD:** Exposed controls from PATCH mode appear automatically in PERFORM mode.

**What NOT to restore yet (defer to later):**
- Step grid UI (requires `SequencerNode` wiring to UI — Part C)
- Scene crossfader (requires `SceneManager` verification — Part C)
- XY axis mode picker with pre-defined modes (TXT/CHS, CFG/FBK, etc.) — replaced by parameter selection in B.1.4

---

### B.2 — Wire up the scene crossfader (if `SceneManager` works)

**File:** `LatentResonator/LatentResonator/Views/SceneCrossfaderView.swift` (exists, unused)

- Verify `SceneManager.applyCrossfader(t:sceneAIndex:sceneBIndex:to:)` works with pure `GraphSnapshot`
- Hook `SceneCrossfaderView` into `PerformanceMotherbaseView` above the macro tab row
- **DoD:** Two scenes can be captured from PATCH mode, crossfading morphs parameters in real time.

---

### B.3 — Remove debug telemetry endpoints before release

**Files:**
- `LatentResonator/PatchEditor/src/bridge.ts` (lines 114-116, 165-183, 96-98) — `http://127.0.0.1:7350/ingest`
- `LatentResonator/LatentResonator/WebView/WebViewBridge.swift` (line ~142) — `/Users/leolambertini/RLTNAS/.cursor/debug-c82797.log`

These were added for debugging the migration. They'll leak paths and phone home to localhost in shipped builds. **Remove them now.**

**DoD:** `grep -r "7350\|debug-c82797" PatchEditor/ LatentResonator/` returns zero matches.

---

## Part C — Step Sequencer & Full UX (deferred)

Only start this after Part A and Part B are fully working.

### C.1 — Wire `SequencerNode` to UI

- `Graph/Nodes/SequencerNodes.swift` (325 lines) exists with `SequencerNode` and `StepOutput`
- Need: a `StepGridView` SwiftUI component reading from the focus macro's `SequencerNode` (find by iterating `focusMacro.internalGraph.nodes`)
- Reuse patterns from `PerformanceMotherbaseView.swift.backup_v1` lines 278-301
- **DoD:** Step grid renders, clicking steps toggles them, advance rate changes work.

### C.2 — P-Lock editing

- The `SequencerNode.steps` array stores per-step parameter locks
- UI: Shift+click a step → parameter lock editing panel
- Write through to `SequencerNode` parameters
- **DoD:** Parameter changes locked to specific steps take effect only on those steps.

### C.3 — Kickstart topology upgrade: add `SequencerNode` and `FeedbackLoopNode`

Once C.1 and C.2 work, upgrade `KickstartTemplate.json` from the minimal 4-node demo into the real whitepaper topology:

```
KoenigSeed → LadderFilter → SpectralChain → FeedbackLoopNode → Mixer → MasterOutput
                                                    ↑ (feedback edge)
                                                    │
                                            ACEStepInferenceNode
SequencerNode → (gate) → KoenigSeed.trigger
SequencerNode → (control) → FeedbackLoopNode.feedbackAmount (p-lock)
```

This is the first topology where the user actually hears the whitepaper thesis.

---

## Part D — Phase Status Relative to `ROAD_TO_V2.md`

| Phase | Name | Status | Notes |
|-------|------|--------|-------|
| 0 | Safety net | ⚠️ **SKIPPED** | No `v3/nodal-migration` branch; all work is uncommitted on `main`. Recovery: `git stash` current work, create branch, reapply. |
| 1 | SequencerNode | ✅ **Done** | `SequencerNodes.swift` exists (325 lines). UI wiring pending (Part C). |
| 2 | Dynamic audio graph (kill H19) | ⚠️ **Partial** | H19 removed from NeuralEngine. `AudioGraphMapper.rebuild()` exists but has the silent-empty bug (A.5) and the connectivity bug (A.4). |
| 3 | Dissolve ResonatorLane | ✅ **Done** | `ResonatorLane.swift` deleted. `NeuralEngine` uses `MacroNode`. Compatibility shims (`lanes`, `focusLane`) are kept as computed properties — OK for transition, remove later. |
| 4 | Flatten NodeGraph | ❓ **Verify** | Check whether `laneSubgraphs` and `crossLaneEdges` are actually removed from `NodeGraph.swift` or still present as legacy. |
| 5 | New UX | ❌ **Blocked** | `PerformanceMotherbaseView` is an 80-line stub. Part B is the recovery. |
| 6 | Scene system on pure graph | ❓ **Verify** | `SceneManager.swift` was modified. Confirm `LaneSnapshot` path is deleted and only `GraphSnapshot` remains. |
| 7 | Factory topologies | ⚠️ **Broken** | One template (`KickstartTemplate.json`) exists but fails to deserialize. Part A.1/A.2 fixes this. No additional topologies yet. |
| 8 | Cleanup | ❌ **Not started** | Do not start until Parts A, B, C are stable. |

---

## Recommended Execution Order

For the next LLM agent working on this:

1. **First 30 minutes:** Execute A.1 → A.2 → A.3 → A.4 → A.5 → A.6 in order. Do **not** run the app between fixes — finish all six and then launch. Expect to hear the Kickstart sine wave.

2. **If A.7 reveals the oscillator itself is broken:** Isolation-test `OscillatorNode` per A.7 step 1. Trace the issue into `SourceNodes.swift`. Do not proceed to B until audio is flowing.

3. **Next 2-4 hours:** Execute B.1.1 through B.1.5 sequentially. Compile and run between each pass. Do **not** try to land all 5 passes in one shot. The stub is actually a gift here — it lets you add features incrementally.

4. **After B is stable:** Commit everything. Create `v3/nodal-migration` branch retroactively. Push.

5. **Then Part C.** By this point, the app should be usable — even if the step grid and full sequencer experience isn't ready, the user can load the Kickstart, tweak parameters, and hear the instrument.

---

## Critical Reminders

- **Do not re-introduce the lane concept.** The shims in `NeuralEngine.swift` lines 132-136 are for backwards-compat during migration only. All new code should use `MacroNode` terminology.

- **Do not delete `PerformanceMotherbaseView.swift.backup_v1`.** It's the reference for porting UI sections. Keep it until B.1.5 is done.

- **Do not try to land all of Part C before B is working.** A usable PERFORM mode with XY pad is worth 10x more than a half-implemented step grid.

- **Every fix in Part A has a test to write.** Do not skip tests — these bugs happened because the migration had no test net. Phase 0 (safety net) was skipped; Part A compensates by adding tests as we fix.

- **The whitepaper thesis is preserved.** The `FeedbackLoopNode` exists in `NeuralNodes.swift` lines 244-822. It implements `S(i+1) = ACE(S(i) + F(S(i)), T(i))`. The Kickstart topology is intentionally simpler than the whitepaper thesis **for now** — we ship audio first, then upgrade the Kickstart to the full thesis in C.3.

---

*Last updated: 2026-04-14*
*Author: Claude, from audit session with Leo*
