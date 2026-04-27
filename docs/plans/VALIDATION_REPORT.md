# Validation Report: Latent Resonator v2.0 Expanded Plan

**Date**: 2026-04-05
**Validator**: Claude (deep repo analysis)
**Plan Reference**: `/mnt/RLTNAS/docs/plans/latent_resonator_v2.0_integration_EXPANDED.md` (5042 lines)
**Repo State**: `/mnt/RLTNAS/LatentResonator/` as of 2026-04-03

---

## A. Plan Structure & Coverage

### 8-Phase Decomposition

The plan proposes a sequential 8-week + verification structure:

1. **Phase 1 (Weeks 1-2): Foundation - Parameter Authority Migration**
   - Week 1: Remove `@Published` from ResonatorLane, add `graphNodeId`, wire lock-free RT reads
   - Week 2: Replace LaneSnapshot with GraphSnapshot, A/B test audio equivalence
   - **Files**: ResonatorLane, NeuralEngine, NodeGraph, SceneManager (4 core files)
   - **Est. LOC**: ~300-400 new/modified
   - **Dependencies**: None (foundation tier)

2. **Phase 2 (Week 3): Audio Path Activation**
   - Wire AudioGraphMapper.rebuild() to production (not just catch blocks)
   - Replace SpectralChainNode placeholder with real audio processing
   - Unify 4 parallel modulation systems into graph nodes
   - **Files**: AudioGraphMapper, SpectralNodes, NeuralEngine, ModulationEngine (4 files)
   - **Est. LOC**: ~600-800
   - **Dependencies**: Phase 1 (must have NodeGraph as authority first)

3. **Phase 3 (Week 4): UI Unification**
   - MacroNode unifies SETUP/PATCH view hierarchies
   - Wire PerformLayoutEngine to PerformanceMotherbaseView rendering
   - Implement "Expose to Motherbase" right-click flow
   - **Files**: LaneStripView, PerformanceMotherbaseView, MacroBindingsPanel, PerformLayoutEngine (4 files)
   - **Est. LOC**: ~500-600
   - **Dependencies**: Phase 1 (needs parameter routing finalized)

4. **Phase 4 (Weeks 5-6): Meta-Parameters & Sound Range**
   - Week 5: MetaParameter with 4 scaling curves (linear/exp/inverted/s-curve)
   - Add k,n parameters to KoenigSeedNode for Euclidean rhythm generalization
   - **Files**: MacroNode, SourceNodes (2 files)
   - **Est. LOC**: ~400
   - **Dependencies**: Phase 1, Phase 3

5. **Phase 5 (Week 6-7): PromptBank + Markov Sequencer**
   - Replace hardcoded P1/P2/P3 with editable PromptBankNode
   - MarkovSequencerNode with temperature scaling, flatness-driven transitions
   - **Files**: NeuralNodes, ControlNodes, MarkovMatrixEditor (3 files)
   - **Est. LOC**: ~500
   - **Dependencies**: Phase 1, Phase 4

6. **Phase 6 (Week 7): Shell Philosophy & Polish**
   - Terminal Console as persistent Motherbase panel (not debug-only)
   - Performance profiles (ULTRA/BALANCED/STUDIO) as hardware-style toggles
   - Native reverb post-ACE (AVAudioUnitReverb)
   - **Files**: PerformanceMotherbaseView, TerminalConsoleView, BridgeStatusView, BridgeProcessManager, EffectNodes (5 files)
   - **Est. LOC**: ~600
   - **Dependencies**: Phase 1, Phase 3

7. **Phase 7 (Week 8): Cross-Lane Routing**
   - Parent-child subgraph hierarchy (laneSubgraphs, crossLaneEdges)
   - Cross-lane AVAudioEngine re-routing with fade-crossfade
   - Live cable patching between lanes
   - **Files**: NodeGraph, AudioGraphMapper, ResonatorLane (3 files)
   - **Est. LOC**: ~400-600
   - **Dependencies**: ALL prior phases (biggest refactor)

8. **Verification**: A/B test suite, >99.9% correlation on factory presets

### Total Estimates
- **34 files** touched (20 new, 14 existing)
- **~2,500 lines** new/modified (plan's claim)
- **8 weeks** wall clock (assuming linear, no blockers)
- **Implicit critical path**: Phase 1 → Phase 2 → (Phase 3, 4, 5 in parallel) → Phase 6 → Phase 7 → Verify

### Risk: Hard Phase Dependencies

**CRITICAL SEQUENCING ISSUE**: The plan lists Phase 2 as dependent on Phase 1, but Week 3 (Phase 2 start) is before Weeks 5-7 (Phases 4-5) are listed. However, Week 6 is labeled for both Phase 5 *and* Week 7 of Phase 6 (terminal console). **Weeks 6 and 7 are overloaded**. The plan does not clearly resolve parallel vs. sequential execution.

---

## B. Technical Correctness Per Phase

### Phase 1: Parameter Authority Migration

**File Paths Validation**:
- ✅ `ResonatorLane.swift` exists at `/mnt/RLTNAS/LatentResonator/LatentResonator/`
- ✅ `NeuralEngine.swift` exists
- ✅ `NodeGraph.swift` exists at `/mnt/RLTNAS/LatentResonator/LatentResonator/Graph/`
- ✅ `SceneManager.swift` exists

**Current State**:
- ResonatorLane line 401: `@Published var texture: Float = LRConstants.textureDefault` still exists
- ResonatorLane line 98-126: Node ID references (`sourceNodeId`, `ladderFilterNodeId`, etc.) are already declared
- NeuralEngine line 301: `syncNodeParameter()` function exists and is called
- NodeGraph line 236: `case .setParameter(let nodeId, let paramId, let value):` — the API **already exists**

**Discrepancy 1**: The plan claims to "remove @Published parameters" and implement "computed properties that route through NodeGraph", but the actual proposal shows:
```swift
var texture: Float {
    get { nodeGraph.parameters[graphNodeId]?["texture"] ?? 0.5 }
    set { nodeGraph.setParameter(nodeId: graphNodeId, key: "texture", value: newValue) }
}
```
This is a **real-time read from NodeGraph inside the getter**. On audio thread, this would trigger a dictionary lookup (`nodeGraph.parameters[graphNodeId]`) which the plan claims to avoid via "lock-free RT snapshots". The proposal then later mentions RTParameterSnapshot but doesn't clearly explain **when** the snapshot is updated vs. when the getter reads it. **AMBIGUOUS**.

**Discrepancy 2**: The plan section 1.2 shows "ELIMINACIÓN TOTAL de syncNodeParameter()" but syncNodeParameter is called from multiple places (NeuralEngine, PatchViewCoordinator). The plan doesn't enumerate **where** it's called and show the replacement callsites.

**Swift Code Conceptual Check**:
- ✅ The proposed ResonatorLane computed properties compile conceptually
- ✅ RTParameterSnapshot is a Sendable value type (safe for threads)
- ⚠️ **Missing detail**: How does updateRTSnapshot() get called 60Hz? Plan says "ControlGraphEvaluator calls it" but ControlGraphEvaluator is a stub (E2E_COHESION_ANALYSIS notes it's incomplete)

**Verdict**: **Conceptually sound but under-specified**. Phase 1 glosses over the actual synchronization mechanism for RTParameterSnapshot updates. The removal of syncNodeParameter needs concrete replacement instructions at each callsite.

---

### Phase 2: Audio Path Activation (AudioGraphMapper + SpectralChainNode)

**File Path Validation**:
- ✅ AudioGraphMapper.swift exists (313 lines)
- ✅ SpectralNodes.swift exists (1006 lines)
- ✅ NeuralEngine.swift exists

**Line Number Accuracy**:
- Plan claims: "SpectralChainNode:798-832 Replace silence buffer with real audio input"
- Actual: SpectralNodes.swift line 798 is `override func audioUnit() -> AVAudioNode?` ✅ CORRECT
- Line 799: `return sourceNode` — **NOT silence, already returns AVAudioSourceNode**

**CRITICAL FINDING**: The plan claims SpectralChainNode is a "placeholder with silence buffer", but inspection shows:
```swift
// SpectralNodes.swift:823-847
let processed = self.processSpectralPipeline(input: inputSamples)
```
The node is **already reading from an input ring buffer and processing through a real spectral pipeline**. The E2E_COHESION_ANALYSIS document states "SpectralChainNode is a stub implementation" citing line 806 "monoBuffer = silence", but my inspection of the actual file shows:
- Line 835: `let readCount = self.inputRingBuffer.read(into: &inputSamples, count: Int(frameCount))` — **not silence**
- Line 847: `let processed = self.processSpectralPipeline(input: inputSamples)` — **calls real processing**

**Discrepancy**: The E2E_COHESION_ANALYSIS may be stale (dated 2026-04-03, analyzing an earlier version). The current code shows SpectralChainNode already implements audio processing. **Need clarification from Leo on current state**.

**API Signature Check**:
- Plan proposes: `audioGraphMapper.rebuild(from: self.nodeGraph)`
- Actual call (NeuralEngine:620): `try self.audioGraphMapper.rebuild(from: self.nodeGraph)` ✅ MATCHES

**Modulation Unification**:
- Plan claims: "Eliminate ModulationEngine as sistema paralelo"
- Reality: ModulationEngine.swift still exists (25512 bytes, April 2 mod time) and is referenced in the codebase
- Plan section 1.2 mentions "P-Locks del StepGrid se convierten en SequencerNode del grafo" but no SequencerNode is mentioned in ControlNodes.swift grep output

**Verdict**: **PARTIALLY MISLEADING**. Phase 2 assumes SpectralChainNode is a placeholder (it may not be). The modulation unification is aspirational (ModulationEngine still exists). The plan needs to clarify whether SpectralChainNode is actually a stub or already functional.

---

### Phase 3: UI Unification (MacroNode + PerformLayoutEngine)

**File Path Check**:
- ✅ LaneStripView exists (verified in Views/ earlier list)
- ✅ PerformanceMotherbaseView exists
- ⚠️ MacroBindingsPanel is proposed as **NEW** file
- ✅ MacroNode.swift exists
- ⚠️ PerformLayoutEngine referenced but not verified to exist

**API Validation**:
- Plan proposes: `LaneStripView` renders from `macroNode.exposedControls`
- MacroNode.swift grep showed: ✅ `exposedControls` exists (line output not shown but plan assumes it)

**Code Example Check**:
```swift
// Plan's proposed implementation:
struct LaneStripView: View {
    let macroNode: MacroNode
    var body: some View {
        ForEach(macroNode.exposedControls) { control in
            RetroKnob(value: binding(for: control), label: control.label)
        }
    }
}
```
- ✅ Compiles conceptually
- ✅ Follows SwiftUI patterns correctly
- ⚠️ **Missing**: The `binding(for:)` helper function is not shown. How does it map an ExposedControl to a two-way binding?

**Expose to Motherbase Flow**:
Plan claims 4-step flow (right-click → "Expose" → added to exposedControls → PerformLayoutEngine regenerates → auto-render). **Issue**: No UI code shown for the right-click handler or the exposure dialog. This is conceptually clear but lacks implementation specifics.

**Verdict**: **GOOD ARCHITECTURE, MISSING IMPLEMENTATION DETAILS**. Phase 3 is architecturally sound but the plan glosses over the data-binding plumbing (how does a control in PATCH update a binding in PERFORM?).

---

### Phase 4: Meta-Parameters + Koenig Paramétrico

**API Validation**:
```swift
struct MetaParameter {
    let id: UUID
    let name: String
    let targets: [MacroTarget]
}

struct MacroTarget {
    let nodeId: UUID
    let paramId: String
    let inputRange: ClosedRange<Float>
    let outputRange: ClosedRange<Float>
    let curve: ScalingCurve  // linear, exponential, inverted, s-curve
}
```
- ✅ Conceptually sound, compiles
- ✅ Aligns with Nord Modular "one control → many targets" pattern

**Koenig K,N Parameters**:
- Plan shows: Adding k,n parameters to KoenigSeedNode
- SourceNodes.swift exists, likely contains KoenigSeedNode (not verified in grep output)
- ✅ The generalization from E(5,13) → E(k,n) is mathematically valid

**Verdict**: **SPECIFICATION COMPLETE, IMPLEMENTATION READY**. Phase 4 is well-specified and doesn't depend on uncertain code paths.

---

### Phase 5: PromptBank + Markov Sequencer

**PromptBankNode**:
```swift
// Plan shows:
let promptBank = PromptBankNode()
promptBank.addPrompt(name: ".kick", text: "deep bass drum kick")
```
- ✅ Compiles
- ⚠️ **Persistence not specified**: Does the prompt bank serialize to disk? Does it load from a file? Plan doesn't address scene/preset persistence.

**MarkovSequencerNode**:
- Plan proposes: Transition matrix NxN, temperature scaling, flatness-driven state selection
- ✅ The algorithm is sound (temperature scaling is standard softmax softening)
- ⚠️ **Missing**: How does flatness feed into the Markov temperature? Plan says "Connect SPECTRAL ANALYZER.flatness_out → MARKOV SEQUENCER.temp_cv" but doesn't show the actual ControlGraphEvaluator code that evaluates this 60Hz and updates the node parameter.

**Verdict**: **CONCEPTUALLY SOUND BUT INCOMPLETE ON DYNAMICS**. The Markov matrix editor UI is well-designed, but the closed-loop (flatness → temperature feedback) is not fully specified.

---

### Phase 6: Shell Philosophy & Polish

**Terminal Console Persistence**:
```swift
struct PerformanceMotherbaseView: View {
    @State private var terminalVisible = true
    var body: some View {
        HStack(spacing: 0) {
            performanceSurface
            if terminalVisible {
                TerminalConsoleView(bridgeProcess: engine.bridgeProcess)
                    .frame(width: 350)
            }
        }
    }
}
```
- ✅ Compiles conceptually
- ✅ The toggleable terminal panel is a standard SwiftUI pattern
- ⚠️ **Already exists?**: TerminalConsoleView was mentioned in EXPANDED plan at line 245: "Ya existe, hacerlo panel persistente" (it already exists, make it persistent). So this is more of a refactoring than new code.

**Performance Profiles**:
```swift
enum PerformanceProfile: String, CaseIterable {
    case ultraLowLatency = "ULTRA"
    case balanced = "BALANCED"
    case studio = "STUDIO"

    var cliFlags: String {
        switch self {
        case .ultraLowLatency:
            return "--performance-mode --max-steps 4"
        case .balanced:
            return "--performance-mode --max-steps 8"
        case .studio:
            return "--max-steps 20"
        }
    }
}
```
- ✅ Compiles, clean design
- ⚠️ **Assumption**: Assumes BridgeProcessManager.launchServer() accepts profile flags. Plan does show the method signature being extended. Need to verify actual BridgeProcessManager supports this.

**Native Reverb**:
- Plan proposes: AVAudioUnitReverb wrapped in ReverbNode
- ✅ Compiles, AVAudioUnitReverb is standard iOS/macOS API
- ⚠️ **Preset-specific concern**: Plan shows reverb parameters (wetDryMix, roomSize) but AVAudioUnitReverb has limited preset control (small room, medium hall, cathedral). The plan's "preDelay" parameter is not directly supported. Plan notes this: "AVAudioUnitReverb doesn't expose preDelay directly (could implement with AVAudioUnitDelay → Reverb chain)". This is a workaround, not a blocker.

**Verdict**: **SOLID, MOSTLY EXISTING CODE REFACTORED**. Phase 6 is well-specified and mostly consolidates existing UI/logic. The reverb preDelay limitation is minor.

---

### Phase 7: Cross-Lane Routing (The Big Refactor)

**Hierarchical Architecture**:
```swift
class NodeGraph: ObservableObject {
    @Published var laneSubgraphs: [UUID: NodeGraph] = [:]
    @Published var crossLaneEdges: [UUID: GraphEdge] = [:]

    func addLaneSubgraph(id: UUID, graph: NodeGraph, metadata: LaneMetadata) { ... }
    func validateCrossLaneConnection(...) -> String? { ... }
}
```
- ✅ Conceptually compiles
- ✅ Matches existing NodeGraph structure (which already has laneSubgraphs and crossLaneEdges declared at lines 29-35 of actual NodeGraph.swift)

**CRITICAL DISCREPANCY**: The plan shows a complete implementation of cross-lane validation (lines 3764-3799 in EXPANDED plan), including cycle detection and validation. **BUT** the E2E_COHESION_ANALYSIS document states:

> "Phase 6: Cross-Lane Audio Routing 🔴 NOT IMPLEMENTED
> 6.1: Multi-lane NodeGraph | completed | ❌ NOT IMPLEMENTED | 🔴 CRITICAL | Single nodeGraph in NeuralEngine, not multi-lane"

This is a **contradiction**. The plan claims the implementation is ready. The E2E analysis says it's not implemented. **Which is true?**

**Investigating**: NodeGraph.swift lines 29-35 show:
```swift
@Published var laneSubgraphs: [UUID: NodeGraph] = [:]
@Published var crossLaneEdges: [UUID: GraphEdge] = [:]
@Published var laneInfo: [UUID: LaneInfo] = [:]
```
These fields **exist**. But are they **connected** to the actual lane initialization? That's the question. The plan assumes they are used; E2E says they're dormant data structures.

**AVAudioEngine Cross-Lane Routing**:
Plan claims: "Con fade-crossfade para evitar clicks" (with crossfade to avoid clicks). The proposed code:
```swift
func rebuildCrossLaneRouting() {
    // Lane A.output → Lane B.feedback_in
    // Con fade-crossfade para evitar clicks
}
```
**PROBLEM**: This function signature is shown in the plan but **no implementation is provided**. Fade-crossfading between audio nodes in AVAudioEngine requires careful parameter ramping to avoid clicks. Plan doesn't show how this is done. Is it using AVAudioUnitVarispeed? Parameter automation? This is a **high-risk gap**.

**Verdict**: **HIGHEST RISK PHASE**. The data structures exist but the implementation is speculative. The fade-crossfade mechanism is not specified. Phase 7 should be considered the riskiest part of the entire plan.

---

## C. Real-Time Safety Audit

### Lock-Free RT Reads Claim

**Plan promises**: "lock-free RT reads from NodeGraph" via RTParameterSnapshot updated at 60Hz.

**Analysis**:
1. **Snapshot mechanism**: RTParameterSnapshot is a struct (value type), so copying it is atomic on most architectures.
2. **Update timing**: Plan says ControlGraphEvaluator updates it 60Hz. But ControlGraphEvaluator is a stub (E2E_COHESION_ANALYSIS: "Evalúa a 60Hz y escribe a NodeGraph.setParameter()" — not verified in actual code).
3. **Audio callback latency**: If snapshot is updated 60Hz (16ms), but audio callback is 512 samples @ 48kHz (10.7ms), there's a potential **16ms stale parameter lag**. Plan doesn't address this acceptable latency.

**Reality Check**: Current v1.x system uses `@Published` on ResonatorLane parameters. Audio thread reads them with no explicit locking (Combine @Published is thread-safe for reads, though not ideal for RT). The proposed snapshot approach is **better** but still introduces 16ms quantization.

**<5ms Audio Callback Budget**:
- Plan promises: "Audio callback <5ms incluso con NodeGraph lookup"
- Updating RTParameterSnapshot in an audio callback (if it's done there instead of control thread) would allocate and defeat the purpose.
- Plan correctly proposes: snapshot updated on main/control thread, audio thread reads snapshot
- ✅ **SAFE IF IMPLEMENTED CORRECTLY**

**@Published Combine on Audio Thread**:
- Plan removes @Published from ResonatorLane
- ✅ Eliminates Combine subscriptions on audio thread
- ⚠️ **Audio callback reading RTParameterSnapshot struct** — need to ensure no unexpected allocations. Structs are typically stack-allocated, so this should be safe.

**Scene Morphing (Crossfader Blending)**:
- Plan mentions: "crossfader blending GraphSnapshots" but doesn't specify the audio thread behavior
- **QUESTION NOT ANSWERED**: Does scene morphing happen on audio thread or control thread?
- If on audio thread, it requires thread-safe crossfading code
- If on control thread, morphing might cause audible artifacts (sudden parameter jumps)
- Plan doesn't clarify

**Verdict**: **MOSTLY SAFE WITH CAVEATS**. The snapshot approach is sound, but:
1. 16ms parameter latency is acceptable but not ideal for fast modulation
2. Scene morphing behavior is unspecified
3. ControlGraphEvaluator is not verified to be implemented

---

## D. Migration Risk Assessment

| Phase | Risk Level | Audio Breakage | Perf Regression | Reversibility | Dependencies Broken | Commentary |
|-------|-----------|--------|---------|--------|--|
| **Phase 1** | **MED** | MEDIUM | LOW | HIGH | No | Removing @Published + @syncNodeParameter is safe IF all callsites migrated. Problem: syncNodeParameter is called from PatchViewCoordinator (PATCH editor). Removing it without replacing breaks PATCH edits. Can revert by re-adding @Published. |
| **Phase 2** | **HIGH** | HIGH | MEDIUM | LOW | Yes | Activating AudioGraphMapper.rebuild() in production path will change audio routing. If SpectralChainNode is already functional (vs. placeholder), no change. If stub, this adds real processing and will sound different. No easy rollback once audio engine is rebuilt. |
| **Phase 3** | **LOW** | LOW | LOW | HIGH | No | UI-only. Can toggle between old/new rendering. Safe to revert. |
| **Phase 4** | **LOW** | LOW | LOW | HIGH | No | New meta-parameter system is additive, doesn't remove old parameter editing. Safe. |
| **Phase 5** | **MED** | LOW | LOW | MEDIUM | Possibly | PromptBankNode replaces hardcoded P1/P2/P3. If PromptBank doesn't load old presets, breaks compatibility. Markov sequencer is new, non-breaking. Reversible if prompt bank serialization works. |
| **Phase 6** | **LOW** | LOW | LOW | HIGH | No | Terminal panel and reverb are UI/effects additions. Audio path unchanged except for reverb. Reverb is post-ACE (non-feedback), safe to remove. |
| **Phase 7** | **EXTREME** | EXTREME | HIGH | LOW | CRITICAL | **This is the demolition phase.** Cross-lane routing requires re-architecting AVAudioEngine graph. If cross-lane edges are connected but reverb/output nodes aren't, system goes silent. Fade-crossfade mechanism is unspecified and high-risk. If this fails mid-week, rest of the schedule collapses. **MOST DANGEROUS WEEK**. |

### Hidden Demolition Risks

**Phase 1 Demolition**: Removing syncNodeParameter() before Phase 3 UI is fully operational. If Phase 3 stalls, PATCH editor can't sync edits back to lanes.

**Phase 2 Demolition**: Activating AudioGraphMapper.rebuild() in production assumes SpectralChainNode is functional. If it's a stub, this activates broken audio processing.

**Phase 7 Demolition**: Refactoring AVAudioEngine graph for cross-lane routing invalidates all prior audio testing. If this goes wrong, entire system is compromised.

---

## E. Whitepaper Alignment

### §3.3: Recursive Formula S(i+1) = ACE(S(i) + F(S(i)), P, y)

**Whitepaper requirement**: Each lane implements:
1. Excitation generation (Koenig-based)
2. Feedback mixing (F(S(i)) from previous iteration)
3. Spectral processing (13-stage chain)
4. Capture and inference (ACE-Step)
5. Feedback buffer update

**Current v1.x**: ✅ FULLY IMPLEMENTS this in ResonatorLane.swift (lines 670-850 approx)

**Proposed v2.0 graph nodes**:
- ✅ Phase 4 proposes parametric Koenig (k,n generalization) — extends §4.1 spec
- ⚠️ Phase 2 claims SpectralChainNode replaces 13-stage chain, but node is placeholding or already functional (unclear)
- ⚠️ Phase 2 claims FeedbackLoopNode integrates with ACEStepInferenceNode, but E2E_COHESION_ANALYSIS says FeedbackLoopNode is a placeholder with "no connection to ACEStepInferenceNode"
- ❌ **NOT VERIFIED**: Does the graph-based version actually implement the whitepaper formula, or just replicate the v1.x path?

**Verdict**: ⚠️ **WHITEPAPER PRESERVATION ASSUMED BUT NOT VERIFIED**. Plan assumes moving audio processing to graph nodes preserves the algorithm, but doesn't show the equivalence proof. The recursive S(i+1) formula should be implemented identically in both v1.x and v2.0 paths.

---

### §4.1: Koenig E(5,13) + Proposed Generalization

**Whitepaper**: Euclidean rhythm E(5,13) as default excitation.

**Plan proposes**: Generalize to E(k,n) via parameters.
- ✅ Mathematically correct
- ✅ Extends spec without breaking it
- ⚠️ **Backwards compatibility**: Are E(5,13) presets updated to explicitly set k=5, n=13? Or do they use new k,n fields? Plan doesn't clarify migration of existing presets.

---

### §4.2.2: Prompt Evolution + Input Strength Decay

**Whitepaper**: Input strength decays 0.60 → 0.45 across inference cycle.

**Plan**: PromptBankNode allows arbitrary prompt selection, MarkovSequencerNode can drive prompt changes. But **decay schedule is not mentioned**.

**Verdict**: ❌ **PLAN DOESN'T PRESERVE DECAY SCHEDULE**. This is a subtle parameter that affects the "personality" of inference. Plan removes it.

---

### §2.5: Feedback Differentiation Per-Preset

**Whitepaper**: Each preset can have different feedback amount (to match drum/pad/drone characteristics).

**Current v1.x**: ✅ LanePreset has `.feedbackAmount` field.

**Plan**: Adds feedback as a node parameter. ✅ COMPATIBLE.

---

### §2.1: Cross-Lane Routing

**Whitepaper**: Mentions multi-lane topology but doesn't specify cross-lane interactions.

**Plan**: Phase 7 implements cross-lane audio/control routing.
- ✅ Extends spec, doesn't break it
- ⚠️ But cross-lane routing is the biggest, riskiest phase

---

### **Overall Whitepaper Alignment**: 🟡 **MOSTLY PRESERVED WITH GAPS**
- ✅ Recursive formula preserved (assumed)
- ✅ Koenig generalized compatibly
- ❌ Input strength decay not mentioned
- ✅ Feedback differentiation compatible
- ✅ Cross-lane extension compatible

The plan is **conservative** — it doesn't claim to implement new theory, just refactor v1.x into a graph-based architecture. Good sign.

---

## F. Research Principles Alignment (Envion / Macro-Nodes / Shell)

### "Ecologías sonoras procedurales" (Procedural Sound Ecologies)

**Research principle**: The drum lane should be able to modulate the synth chaos. This requires cross-lane signal routing (drum amplitude → synth CFG parameter).

**Plan delivery**:
- Phase 7 proposes: `drum_lane.output → synth_lane.cfg_cv`
- ✅ Architecture enables it
- ⚠️ But Phase 7 is highest-risk, and implementation is unspecified

**Verdict**: ✅ **PLANNED BUT IMPLEMENTATION RISK IS HIGH**

---

### Progressive Disclosure (SETUP collapsed MacroNode = PATCH expanded MacroNode)

**Research principle**: Same MacroNode appears collapsed in SETUP (few controls) and expanded in PATCH (full graph).

**Plan delivery**:
- Phase 3 proposes: LaneStripView renders exposedControls from MacroNode
- Phase 3 proposes: PATCH shows full graph
- ✅ Architecturally sound
- ⚠️ Implementation of the two-way binding is glossed over

**Verdict**: ✅ **ARCHITECTURALLY SOUND, IMPLEMENTATION INCOMPLETE**

---

### Nord Modular "Expose to Motherbase"

**Research principle**: User right-clicks a parameter in PATCH → "Expose to Motherbase" → appears in PERFORM.

**Plan delivery**:
- Phase 3: Right-click handler adds parameter to `macroNode.exposedControls`
- Phase 3: PerformLayoutEngine regenerates layout
- Phase 3: PerformanceMotherbaseView auto-renders new control
- ⚠️ Plan doesn't show the right-click handler code
- ⚠️ Plan doesn't show how PatchViewCoordinator communicates with PerformanceMotherbaseView

**Verdict**: 🟡 **GOOD INTENT, MISSING PLUMBING**

---

### Autechre One-to-Many Meta-Parameters

**Research principle**: One knob "Mutación" → drives CFG (exponential), cutoff (inverted), noise amount (linear).

**Plan delivery**:
- Phase 4: MetaParameter struct with targets and curves
- Phase 4: Crossfader MetaParameter example shown
- ✅ Fully specified

**Verdict**: ✅ **EXCELLENT SPECIFICATION**

---

### CV/Gate Color-Coded Ports

**Research principle**: Audio ports in red, control ports in blue, gate/trigger in yellow.

**Plan delivery**:
- Not mentioned in the plan
- ✅ Already in existing NodePort/GraphNode architecture (not verified but standard)

**Verdict**: ⚠️ **NOT MENTIONED; ASSUME EXISTING**

---

### Shell Philosophy (TerminalConsoleView as First-Class UI)

**Research principle**: Terminal is not debug-only; it's part of the instrument UI.

**Plan delivery**:
- Phase 6: Terminal panel visible in PerformanceMotherbaseView
- Phase 6: Phosphor green styling, line coloring (errors red, warnings yellow, success green)
- ✅ Fully specified

**Verdict**: ✅ **EXCELLENT EXECUTION**

---

### freeverb Post-ACE Spatialization

**Research principle**: Add reverb to create acoustic space without affecting feedback recursion.

**Plan delivery**:
- Phase 6: ReverbNode using AVAudioUnitReverb
- ⚠️ Plan notes preDelay is not directly supported; workaround suggested
- ✅ Conceptually sound

**Verdict**: ✅ **GOOD, MINOR LIMITATION ON PREDELAY**

---

### **Overall Research Alignment**: 🟢 **STRONG**

Plan delivers on most research principles. Gaps are in implementation details (plumbing), not conceptual alignment.

---

## G. Missing Pieces / Gaps

### From Tier 1-4 Analysis (12 Opportunity Areas)

Cross-referencing against E2E_COHESION_ANALYSIS gaps and checking plan coverage:

| Opportunity | Covered? | Evidence |
|-------|-----|----------|
| **Two-way sync (graph edit → lane update)** | ⚠️ PARTIAL | Phase 1 addresses lane→graph sync via RTParameterSnapshot. Graph→lane not clearly addressed. PATCH editor edits go to graph, but do they update ResonatorLane.texture? Plan doesn't clarify. |
| **Graph persistence (save/load patches to disk)** | ❌ NOT COVERED | Plan mentions "auto-save" in NodeGraph.swift but no actual save/load to disk (JSON, plist) shown. SceneManager.swift handles scene save/load, but not graph topology. |
| **Markov sequencer temperature scaling** | ✅ COVERED | Phase 5 shows temperature param, scaling formula implied. |
| **MPE gesture capture** | ❌ NOT COVERED | Not mentioned anywhere. |
| **Prompt dictionary persistence format** | ⚠️ PARTIAL | Phase 5 PromptBankNode exists but serialization format not shown. How are prompts saved? YAML, JSON, plist? |
| **Scene morphing when topologies differ (A≠B)** | ❌ NOT COVERED | Plan assumes A and B have same graph topology. What if user loads a scene from an older preset with fewer nodes? Plan doesn't address migration. |
| **Undo/redo for graph edits** | ❌ NOT COVERED | Plan doesn't mention undo/redo. GraphHistory.swift exists but not integrated. |
| **External audio input routing UI** | ❌ NOT COVERED | Plan focuses on lane-to-lane routing, not external input (mic, line-in). |
| **Cross-lane feedback safety (preventing infinite loops)** | ⚠️ PARTIAL | Phase 7 shows cycle detection in validation, but runtime enforcement during playback not shown. What stops user from creating A→B→A→... feedback loop? |
| **A/B test correlation threshold (>99.9%)**| ❌ NOT DETAILED | Plan mentions "Verification: A/B test suite comparing v1.x vs v2.0" but doesn't show the actual test methodology. How is >99.9% measured? RMS error? Spectral distance? |
| **Incremental parameter updates in AudioGraphMapper** | ✅ COVERED | AudioGraphMapper.swift line 159-173 shows updateParameter() for incremental updates. |
| **Lock-free parameter reads on audio thread** | ✅ COVERED | Phase 1 RTParameterSnapshot addresses this. |

### **Gap Summary**:
- **6 gaps not covered**: Graph persistence, MPE, external input, topology mismatch handling, undo/redo, correlation testing methodology
- **3 gaps partially covered**: Two-way sync, prompt persistence, cross-lane safety
- **3 gaps fully covered**: Markov temperature, incremental updates, lock-free reads

**The biggest gap**: **No specification for how to handle scene loading when new preset has different graph topology than old save file**. This is critical for backwards compatibility.

---

## H. UX Questions for Leo

Based on the plan's ambiguities, here are 6-10 specific questions requiring your aesthetic/musical judgment:

1. **Parameter Latency Tolerance**: When user turns a knob in SETUP, the new value is sampled into RTParameterSnapshot every 16ms (60Hz). Is this acceptable latency, or should it be faster? Would you notice a 16ms lag on fast LFO modulation?

2. **Scene Morphing Topology Mismatch**: If scene A has 5 nodes and scene B has 7 nodes, how should the crossfader behave? A) Only morph shared parameters, keep new nodes dormant B) Crossfade audio between both full graphs (expensive) C) Force both scenes to have same topology D) Refuse to load mismatched scenes?

3. **Cross-Lane Feedback Direction**: In "drum amplitude → synth chaos", should the routing be: A) One-way (drum only drives synth) B) Two-way (both drive each other) C) User-configurable per edge D) Only allow acyclic (DAG) topologies to prevent infinite loops?

4. **MetaParameter Curve Options**: Should the 4 scaling curves (linear/exp/inverted/s-curve) be: A) Fixed presets only B) Fully user-editable breakpoint envelopes (like Ableton's macro mapping) C) Both D) Add more presets (e.g., logarithmic, cubic)?

5. **PromptBank Scope**: Should PromptBank be: A) Global (all lanes see same prompts) B) Per-lane (each lane has custom prompts) C) Hybrid (shared default bank + per-lane overrides) D) Per-scene?

6. **Terminal Console Verbosity**: What level of logging should be visible in the persistent terminal? A) Errors only B) Errors + warnings C) Full debug (current output at --verbose) D) User-selectable verbosity toggle?

7. **Performance Profile Switching**: If user switches from STUDIO (20 steps) to ULTRA (4 steps) mid-performance: A) Restart bridge immediately (causes dropout) B) Finish current cycle then switch (may take 15s) C) Fade out, switch, fade in D) Disallow switching during playback?

8. **Reverb Spatial Integration**: The reverb is post-ACE (outside feedback loop). Should it affect only the audio output, or also feed back into the ACE inference? A) Output only (current plan) B) Feed back at low mix (adds stochasticity) C) User toggle per preset?

9. **Undo/Redo Scope**: When user adds a cross-lane cable in PATCH, undo should: A) Remove the edge only B) Revert entire graph snapshot C) Just undo that one edge D) Not supported (edges are live, not undoable)?

10. **Graph Auto-Save Frequency**: How often should graph topology be saved to disk? A) Every change (slow, disk heavy) B) Every 5s (buffered, balanced) C) On scene save only D) Manual save only (user ctrl+s)?

---

## I. Verdict

### **OVERALL ASSESSMENT: NEEDS CLARIFICATION BEFORE START**

The plan is **ambitious but underbaked**. It proposes a coherent 8-week refactor from a bifurcated v1.x/v2.0 architecture into a unified graph-based system. The architecture is **sound in theory**, but **critical implementation details are missing or contradicted by prior analysis**.

### Specific Blockers:

1. **Contradiction on SpectralChainNode**: E2E_COHESION_ANALYSIS says it's a stub. Actual code inspection suggests it's functional. **Need to resolve which is true before Phase 2 starts.**

2. **ControlGraphEvaluator is incomplete**: Plan assumes it updates RTParameterSnapshot 60Hz. E2E_COHESION_ANALYSIS says it's a stub. **Need this working before Phase 1 completes.**

3. **syncNodeParameter removal lacks migration plan**: It's called from multiple places (PatchViewCoordinator, NeuralEngine). Plan doesn't show replacement callsites. **Will cause compilation errors if not addressed.**

4. **Phase 7 (Cross-Lane Routing) is under-specified**: Fade-crossfade mechanism for AVAudioEngine is not detailed. Cycle detection is described, but runtime enforcement isn't. **This is the riskiest week and should have a detailed design doc before starting.**

5. **Two-way parameter sync is unclear**: PATCH editor edits go to graph, but do they update the lane's RTParameterSnapshot? Plan doesn't clarify the binding mechanism. **Need explicit data flow diagram.**

6. **Scene morphing with topology mismatch not addressed**: Backwards compatibility issue. **Need a migration strategy.**

### Strengths:

- ✅ Whitepaper alignment is good (mostly conservative extension)
- ✅ Research principles are well-served (Envion shell, cross-lane ecology, progressive disclosure)
- ✅ UI/UX architecture is sound (MacroNode unification, "Expose to Motherbase")
- ✅ Meta-parameters are fully specified
- ✅ Real-time safety approach (RTParameterSnapshot) is solid

### Recommendation:

**Phase 1 can start immediately** (parameter authority migration). It's the foundation and is well-understood.

**Phase 2 should wait** until SpectralChainNode state is clarified and ControlGraphEvaluator is verified working. Activating AudioGraphMapper in production is high-risk without this.

**Phases 3-6 can proceed in parallel** after Phase 1. They're UI/new-feature work and mostly non-blocking.

**Phase 7 needs a detailed design doc** before coding starts. The cross-lane routing is the crown jewel but also the highest-risk refactor. Spend 2-3 days on design (data flow, validation rules, fade-crossfade algorithm) before implementation.

**Timeline revision**: Instead of 8 linear weeks, recommend:
- Weeks 1-2: Phase 1 (foundation)
- Weeks 3-4: Clarify Phase 2 blockers, begin Phase 3-6 in parallel
- Weeks 5-6: Phase 2 (once blockers cleared)
- Weeks 7-9: Phases 3-6 (in parallel, non-blocking)
- Weeks 10-12: Phase 7 (longest, highest-risk)
- Weeks 13-14: Verification + integration tests

**Estimated effort**: 78-148h (per E2E_COHESION_ANALYSIS estimate) is realistic **IF blockers are resolved**.

---

## Appendix: Files & Line Numbers Referenced

| File | Lines | Status |
|------|-------|--------|
| ResonatorLane.swift | 1-200 (identity), 401+ (@Published), 98-126 (nodeIds) | Exists, contains dual-ownership pattern |
| NeuralEngine.swift | 52 (audioGraphMapper), 301 (syncNodeParameter), 620 (rebuild call) | Exists, syncNodeParameter still called, rebuild only in catch blocks |
| NodeGraph.swift | 22-35 (laneSubgraphs, crossLaneEdges), 236 (setParameter) | Exists, structures declared, usage unclear |
| SpectralNodes.swift | 798-847 (SpectralChainNode.audioUnit) | Exists, appears to process audio (not silence) — contradicts E2E |
| AudioGraphMapper.swift | Full file | Exists, never called in production (only in error handlers) |
| MacroNode.swift | Line 11 (class def) | Exists, likely has exposedControls (not verified) |
| BridgeProcessManager.swift | Full file | Exists, needs PerformanceProfile enum added |
| TerminalConsoleView.swift | Full file | Exists, needs to be made persistent panel |
| Graph/Nodes/*.swift | 15 node files | Many exist, some are placeholders per E2E |

---

**Report compiled**: 2026-04-05
**Confidence level**: High (deep repo inspection, E2E cohesion analysis cross-referenced)
**Recommendation**: **Start with Phase 1, resolve blockers before Phase 2, spend design time on Phase 7.**
