# Whitepaper Alignment Guardian

**Trigger phrases:** "whitepaper", "recursive formula", "Lucier", "Xenakis", "Koenig", "theoretical", "research", "generative degradation", "latent drift", "Black Box Resonator"

**Purpose:** Ensure all features and changes maintain theoretical alignment with the research documented in `docs/whitepaper.md`. This skill validates that Latent Resonator remains a coherent research instrument rather than feature drift.

---

## WHEN TO LOAD THIS SKILL

- User mentions "whitepaper", "theory", "research"
- User proposes a feature that might diverge from research goals
- User asks "does this align with the whitepaper?"
- User wants to implement concepts from the whitepaper
- User is adding documentation or academic citations
- You're unsure if a change aligns with project philosophy

---

## STEP 1: UNDERSTAND THE WHITEPAPER STRUCTURE

The whitepaper (`docs/whitepaper.md`) is organized as:

### Section 1: Introduction — The Neural Network as Instrument of Erosion

**Key concepts:**
- Inversion of value system: error IS the aesthetic object
- Neural network as medium, not composer
- Historical lineage: Lucier, Xenakis, Schaeffer, Roads, Koenig
- Post-humanist cybernetics (Wiener)

**Philosophical stance:**
```
"The hallucinations of a high-temperature AI model are functionally 
analogous to the stochastic artifacts prized by Iannis Xenakis and 
Curtis Roads."
```

### Section 2: Implementation — Real-Time Instrument Architecture

**Implemented features:**
- Multi-lane topology (N independent feedback loops)
- Spectral-conditioned prompt evolution (flatness-based phase transitions) — **live thresholds/constants only**; closed-loop flatness → `PromptEngineNode` is **STATUS: roadmap — not wired in shipped runtime** (see STEP 3B, whitepaper §4.2.2)
- Auto-decay trajectory (inputStrength 0.60 → 0.45)
- Spectral feature extraction (centroid, flatness, flux)
- Colored spectral noise and per-band saturation
- Iteration archive (temporal navigation)
- Continuous saturation morphing (WARMTH macro)
- Motherbase performance surface (Elektron-style)
- Drum Lane (prompt-space sound locking)
- Layer carving (frequency slot painting)

### Section 3: Technical Architecture — ACE-Step 1.5

**Core understanding:**
- Hybrid LM + DiT architecture
- Bypassing the planner with abstract prompts
- Overdriving the renderer (CFG 15.0-18.0)
- The recursive formula:

```
S(i+1) = ACE( S(i) + N(μ,σ), P, γ )

S(i)   — audio signal at iteration i
N(μ,σ) — Gaussian noise (inputStrength)
P      — abstract prompt vector
γ      — Guidance Scale / CFG
```

### Section 4: Methodology — The Neural Feedback Loop Protocol

**Phase A: Koenig Seed (Euclidean Rhythm)**
- E(5,13) — 5 pulses over 13 steps
- Prime number asymmetry (13 avoids 4/4 symmetry)
- Dirac impulses (all frequencies at equal energy)
- Gaussian noise tails (20ms)

**Phase B: Xenakis Loop (Iterative Degradation)**
- High CFG (15.0-18.0) for hallucination
- Abstract prompts ("ferrofluid texture", "spectral degradation")
- Prompt evolution across phases (tonal → drift → saturation)
- Auto-decay trajectory (§4.2.2)

### Section 5: Emergent Phenomena

**Observed artifacts:**
- Metallic sheen (comb filter resonances)
- Granular disintegration (microsound windows)
- Spectral freeze (sustained frequency snapshots)
- Recursive drift (model bias exposure)

### Section 6: The Black Box Resonator

**DSP-only mode:**
- When neural models unavailable, SpectralProcessor IS the resonator
- FFT-based semantic filtering
- Spectral memory as latent state analogue
- Self-organizing feedback without neural inference

---

## STEP 2: VALIDATE PROPOSED CHANGES

### Question 1: Does This Align With Research Goals?

**Research goals (from whitepaper §1.3):**
1. Establish theoretical continuum with Xenakis/Schaeffer/Roads/Koenig
2. Define executive protocol for ACE-Step as stochastic processor
3. Analyze emergent artifacts (impulse → spectral mass)
4. Probe latent drift (expose "sound of the algorithm")

**If the proposed change serves these goals → ALIGNED**
**If the proposed change is "just a feature" → QUESTION IT**

Examples:

✓ **ALIGNED:** "Add Markov sequencer for probabilistic step transitions"
  - Aligns with stochastic synthesis (Xenakis)
  - Extends algorithmic composition (Koenig)
  - Serves research goal #1
  - **STATUS: roadmap — not wired in shipped runtime** (`MarkovSequencerNode`; see STEP 3B)

✗ **NOT ALIGNED:** "Add reverb effect"
  - Generic DSP effect, no theoretical grounding
  - Not mentioned in whitepaper
  - Doesn't serve research goals
  - (Unless: reverb is part of a feedback topology study)

✓ **ALIGNED:** "Implement cross-lane spectral modulation"
  - Creates coupled dynamical systems
  - Extends recursive feedback topology
  - Serves research goal #4 (latent drift in networked systems)
  - **STATUS: roadmap for live spectral-feature routing** until `SpectralAnalyzerNode` participates in pull-render (see STEP 3B, §3.3.8 in `ARCHITECTURE_v2_NODAL.md` RFC)

✗ **NOT ALIGNED:** "Add preset browser with tags and favorites"
  - UI convenience feature
  - No research value
  - Doesn't serve any whitepaper goal

### Question 2: Does This Implement Whitepaper Concepts Correctly?

**Check the math:**

The recursive formula is:
```
S(i+1) = ACE( S(i) + N(μ,σ), P, γ )
```

**In code this translates to the current `FeedbackLoopNode` (`Graph/Nodes/NeuralNodes.swift`)** — real-time `render()` only writes/reads lock-free ring buffers; the formula itself executes inside the async inference `Task` it triggers:

```swift
// render() — audio thread, every buffer: pointer-based, no allocation
captureBuffer.write(inputPtr, count: frameCount)          // accumulate S(i) + F(S(i))
let read = feedbackBuffer.read(into: outputPtr, count: frameCount)  // emit S(i) from the previous cycle
// trigger (not poll): availableToRead >= inferenceBufferSize → spawn one Task, guarded by
// os_unfair_lock_trylock so at most one inference cycle runs at a time.

// Inside the triggered Task (off the audio thread):
var inputSamples = captureBuffer.read(count: inferenceBufferSize)   // S(i)

// N(μ,σ) — entropy injection (whitepaper §4.2.2)
for i in inputSamples.indices { inputSamples[i] += SignalGenerator.boxMullerNoise() * noiseScale }

// ACE(..., P, γ) — neural inference with prompt P and guidance γ, read from the connected
// ACEStepInferenceNode's parameter surface (weak `inferenceNode` reference)
let result = try await bridge.infer(
    samples: inputSamples,
    prompt: params.prompt,          // P
    guidanceScale: params.cfg,      // γ
    ...
)

// S(i+1) — write back for the next render() cycle to read
feedbackBuffer.write(result)
```

No model loaded / bridge unavailable → the trigger still fires but `bridge.infer` isn't reachable, so `feedbackBuffer` stays empty and `render()` degrades to passthrough. That's intentional (§6.1, Black Box Resonator), not a bug to "fix" by blocking on the model.

**If implementing a whitepaper concept, trace it to the paper:**

```swift
// Whitepaper §4.2.2 — Spectral-Conditioned Prompt Evolution
//
// STATUS: roadmap — not wired in shipped runtime (see STEP 3B). Constants/thresholds
// exist; live flatness → prompt phase requires `SpectralAnalyzerNode` + call sites
// for `MacroNode.updatePromptForFlatness`.
//
// Phase transitions based on real-time spectral flatness:
//   flatness < 0.35  → Phase 1 (tonal, structured)
//   flatness >= 0.35 → Phase 2 (recursive drift)
//   flatness >= 0.65 → Phase 3 (deep saturation)

func updatePromptPhase() {
    let flatness = spectralProcessor.spectralFlatness
    
    if flatness < LRConstants.spectralPhase2Threshold {
        promptPhase = 1
    } else if flatness < LRConstants.spectralPhase3Threshold {
        promptPhase = 2
    } else {
        promptPhase = 3
    }
}
```

### Question 3: Does This Preserve Historical Lineage?

**Five theoretical pillars:**

1. **Alvin Lucier** — *I Am Sitting in a Room* (1969)
   - Recursive filtering through physical space
   - **Implemented as:** Neural Feedback Loop in latent space (formula live via `FeedbackLoopNode`; cybernetic spectral closure **STATUS: roadmap** — see STEP 3B, §3.3)

2. **Iannis Xenakis** — *Formalized Music* (1971)
   - Stochastic synthesis, mathematical composition
   - **Implemented as:** High-CFG hallucination, entropy injection; Markov sequencers — **STATUS: roadmap — not wired** (see STEP 3B)

3. **Pierre Schaeffer** — *Traité des objets musicaux* (1966)
   - Acousmatic listening, sound objects divorced from source
   - **Implemented as:** Abstract prompts, semantic filtering

4. **Curtis Roads** — *Microsound* (2001)
   - Granular synthesis, sub-audio-rate time domain
   - **Implemented as:** Spectral granularity, microsound windows

5. **Gottfried Michael Koenig** — *Project One/Two* (1970)
   - Algorithmic composition, mathematical structures
   - **Implemented as:** Koenig Seed (Euclidean rhythm), step sequencer

**If a feature extends one of these traditions → ALIGNED**
**If a feature has no historical precedent → QUESTION IT**

---

## STEP 3: CITE WHITEPAPER SECTIONS IN CODE

### Citation Format

**Always reference specific sections:**

```swift
// Whitepaper §3.3 — The Latent Space as Recursive Filter
// S_{i+1} = ACE(S_i + N(μ,σ), P, γ) — live via FeedbackLoopNode + ACEStepBridge.
// Cybernetic "output shapes input" closure via SpectralAnalyzer → control graph:
// STATUS: roadmap — not wired in shipped runtime (see STEP 3B).
func runInferenceCycle() async { ... }

// Whitepaper §4.1.1 — E(5,13) Euclidean Rhythm
// Prime number asymmetry: 13 steps avoid 4/4 symmetry
let pattern = euclideanRhythm(pulses: 5, steps: 13)

// Whitepaper §4.2.1 — CFG Overdrive
// 15.0-18.0 pushes model to extreme edges of probability distribution
let cfg = 16.0

// Whitepaper §5.4 — Metallic Sheen as Instrument
// Prime-number delay spacing creates inharmonic partials
let combDelay = 137  // prime
```

### Section Reference Guide

**Common citations:**

| Section | Concept | Code Location |
|---------|---------|---------------|
| §1.2 | Lucier's recursive chamber | `FeedbackLoopNode` (`Graph/Nodes/NeuralNodes.swift`) — the only node that may create a cycle in the graph |
| §3.3 | Recursive formula | `FeedbackLoopNode`'s async inference `Task` calling `ACEStepBridge.infer(...)` — triggered from inside `render()`, never blocking it |
| §3.3 / §3.3.8 (RFC) | SpectralAnalyzer as cybernetic sensor | `SpectralAnalyzerNode` — **STATUS: roadmap — not wired in shipped runtime** (see STEP 3B) |
| §4.1.1 | E(5,13) Euclidean rhythm | KoenigSeedGenerator |
| §4.1.2 | Dirac impulse (all frequencies) | Excitation generation |
| §4.2.1 | CFG overdrive (15-18) | Constants.swift CFG range |
| §4.2.2 | Auto-decay trajectory | inputStrength auto-decay |
| §4.2.2 | Prompt evolution thresholds | spectralPhase2/3Threshold |
| §5.2 | Spectral freeze | SpectralProcessor freeze logic |
| §5.4 | Metallic sheen (comb filters) | Comb filter, resonator |
| §6.1 | Black Box Resonator | SpectralProcessor DSP-only mode |
| §4.2.2 | Prompt evolution thresholds | `spectralPhase2/3Threshold` — **STATUS: roadmap, not wired in shipped runtime** (see STEP 3B) |

---

## STEP 3B: DECLARED-BUT-NOT-EXECUTED NODES (2026-07-21 perimeter audit)

Six independent audits (2026-07-21) converged on one finding: several nodes cited elsewhere in this skill as evidence of "cybernetic feedback" / "self-modulating systems" (§3.3) are registered in `NodeFactory` — so they're placeable on the canvas and pass graph validation — but are **not wired into the live pull-render graph**. `ExecutionPlan.build` silently skips any node that doesn't conform to `GraphNodeDSPProvider`/`DSPNode`, and several of these have zero call sites outside their own file. Citing them as if they close a feedback loop overclaims what the shipped runtime does. Until the roadmap below is executed, treat any claim in this skill that depends on one of these as **STATUS: roadmap — not wired in shipped runtime**, not as a description of current behavior. Do NOT delete or "simplify" these nodes to match this note — they're legitimate future work, just not live today.

| Node / mechanism | File:line | Why it's inert today |
|-------------------|-----------|----------------------|
| `SpectralAnalyzerNode` | `Graph/Nodes/AnalysisNodes.swift:9` | Whitepaper cybernetic sensor / RFC §3.3.8 ANALYSIS node. Overrides the dead `audioUnit() -> AVAudioNode?` hook (pre-pull-render `AudioGraphMapper` API); does not conform to `DSPNode`/`GraphNodeDSPProvider`, so `ExecutionPlan.build` skips it. Its `centroid`/`flatness`/`flux` control ports never carry a real value in the render graph. This is the node the "latent space as recursive filter" / cybernetic-feedback framing of §3.3 implicitly assumes exists. **STATUS: roadmap — not wired in shipped runtime.** |
| `PromptEngineNode` (§4.2.2 consumer) | `Graph/MacroNode.swift:779` (`updatePromptForFlatness`) | Fully implemented (phase thresholds, 3-phase prompt interpolation, `Graph/Nodes/NeuralNodes.swift:151`) but `updatePromptForFlatness` has zero call sites outside its own declaration — nothing feeds it live flatness, because the node that would supply it (`SpectralAnalyzerNode`, above) isn't wired either. **STATUS: roadmap — not wired in shipped runtime.** |
| `MarkovSequencerNode` | `Graph/Nodes/ControlNodes.swift:627` | Registered in `NodeFactory` (`"markov_sequencer"`); no `DSPNode`/control-evaluation wiring found beyond its own class body. The "flatness-driven temperature = cybernetic feedback" claim in its own doc comment has no live flatness source to read from (same root cause as above). **STATUS: roadmap — not wired in shipped runtime.** |
| `GestureRecorderNode` | `Graph/Nodes/ControlNodes.swift:919` | Registered in `NodeFactory` (`"gesture_recorder"`); no UI call site wires an actual XY pad / crossfader gesture into its record path. |
| `AudioInputNode` | `Graph/Nodes/SourceNodes.swift:241` | Same dead `audioUnit()` pattern as `SpectralAnalyzerNode` — wraps `AVAudioInputNode` but nothing in `GraphAudioEngine`/`ExecutionPlan` calls `.audioUnit()`. Placing "AUDIO IN" on the canvas does not route live mic input into the render graph. |
| `CoreMLInference` | `CoreMLInference.swift:32` | Zero instantiation sites anywhere in the target. Canonical inference remains `ACEStepBridge` + `Scripts/ace_bridge_server.py`, exactly as `CoreMLInference.swift`'s own header says. |

See `docs/ROADMAP_PERIMETER_2026-07-21.md` for fix priority (P1–P3) and what wiring each one actually requires. Don't implement any of the above as a side effect of an unrelated feature — wire deliberately, per the roadmap, or leave them declared-and-honest.

---

## STEP 4: EVALUATE AESTHETIC ALIGNMENT

### The Aesthetic Is Non-Negotiable

**What the system SHOULD sound like:**
- Metallic, granular, spectral textures
- Self-organizing acoustic complexity
- Stochastic artifacts and hallucinations
- Timbral evolution through recursive drift
- Microsound disintegration

**What the system SHOULD NOT sound like:**
- Polished, clean, commercial music
- Standard EDM or pop structures
- Predictable, safe, "nice" tones
- Generic synthesizer sounds

**If a feature makes the system sound "nicer" → QUESTION IT**
**If a feature increases chaos/entropy/drift → ALIGNED**

### Examples:

✓ **ALIGNED:** "Increase spectral noise injection in high-flatness regions"
  - Amplifies generative degradation
  - Serves entropic trajectory
  - Whitepaper §4.2.2 (Phase 3 deep saturation)

✗ **NOT ALIGNED:** "Add limiter to prevent distortion"
  - Reduces artifacts (but artifacts ARE the sound)
  - Conflicts with "overdrive" philosophy
  - (Unless: limiting for safety, not aesthetics)

✓ **ALIGNED:** "Add spectral freeze blending"
  - Sustains resonant frequencies (Lucier)
  - Creates temporal smearing
  - Whitepaper §5.2

✗ **NOT ALIGNED:** "Add chord progression generator"
  - Imposes Western harmony structure
  - Conflicts with stochastic synthesis
  - No precedent in Xenakis/Koenig tradition

---

## STEP 5: CHECK FOR DRIFT FROM CORE FORMULA

### The Sacred Formula

```
S(i+1) = ACE( S(i) + N(μ,σ), P, γ )
```

**Every feature should relate to one of these terms:**

- **S(i)** — Previous iteration audio
  - Feedback buffer, iteration archive, temporal recall
  
- **N(μ,σ)** — Noise injection
  - Gaussian noise, inputStrength, excitation sources
  
- **P** — Prompt vector
  - Prompt evolution, semantic filtering, DrumVoice P-Locks
  
- **γ** — Guidance Scale
  - CFG parameter, overdrive zone (15-18), hallucination intensity
  
- **S(i+1)** — Next iteration
  - Inference output, feedback loop closure

**If a feature doesn't map to this formula → QUESTION IT**

### Examples:

✓ **Maps to S(i):** "Add iteration archive with selective recall"
  - Stores previous S(i) states
  - Enables temporal branching in recursive drift

✓ **Maps to N(μ,σ):** "Add colored noise shaping by spectral profile"
  - Modulates noise injection
  - inputStrength controls μ,σ

✓ **Maps to P:** "Add prompt phase evolution based on spectral flatness"
  - Spectral state modulates prompt vector
  - Creates autonomous compositional trajectory
  - **STATUS: roadmap — not wired in shipped runtime** (§4.2.2 / `PromptEngineNode`; see STEP 3B)

✗ **Doesn't map:** "Add MIDI keyboard for note input"
  - Imposes pitch structure
  - No term in recursive formula for "notes"
  - Conflicts with Euclidean rhythm philosophy

---

## STEP 6: HISTORICAL PRECEDENT CHECK

### Five Pillars (Must Reference At Least One)

When proposing a feature, it should extend one of these traditions:

#### 1. Alvin Lucier — Recursive Filtering

**Precedent:** *I Am Sitting in a Room* (1969)
- Output fed back as input
- Physical space as resonant filter
- Semantic content destroyed, resonance revealed

**Aligned features:**
- Neural Feedback Loop itself
- Spectral memory (persistent resonance)
- Cross-lane feedback routing
- Delay lines (Lucier Chamber)

#### 2. Iannis Xenakis — Stochastic Synthesis

**Precedent:** *Formalized Music* (1971)
- Mathematical structures generate sound
- Probability distributions, cloud masses
- Microsound, granular density

**Aligned features:**
- Entropy injection, spectral noise
- Gaussian noise tails on Koenig Seed
- Markov sequencer (probabilistic transitions) — **STATUS: roadmap, not wired in shipped runtime** (see STEP 3B)
- Granularity parameter (microsound windows)

#### 3. Pierre Schaeffer — Musique Concrète

**Precedent:** *Traité des objets musicaux* (1966)
- Acousmatic listening (sound divorced from source)
- Sound objects, not musical notes

**Aligned features:**
- Abstract prompts ("ferrofluid texture")
- Semantic spectral filtering
- No MIDI note input (anti-pitch)

#### 4. Curtis Roads — Microsound

**Precedent:** *Microsound* (2001)
- Sub-audio-rate time domain
- Granular synthesis, particle clouds

**Aligned features:**
- Spectral granularity
- STFT overlap-add (granular windows)
- Noisiness as texture source

#### 5. Gottfried Michael Koenig — Algorithmic Composition

**Precedent:** *Project One/Two* (1970)
- Mathematical structures, sieves
- Euclidean distribution algorithms
- Deterministic yet complex

**Aligned features:**
- Koenig Seed (E(5,13) Euclidean rhythm)
- Step sequencer, chain length
- Parameter locks (algorithmic control)

### Precedent Test

**Ask:** Which pillar does this feature extend?

✓ **Has precedent:** "Add sample-and-hold LFO waveform"
  - Extends Koenig (algorithmic, step-based control)
  - Adds stochastic element (Xenakis)

✗ **No precedent:** "Add arpeggiator with musical scales"
  - Imposes Western harmony
  - No analog in avant-garde tradition
  - Conflicts with abstract/stochastic philosophy

✓ **Has precedent:** "Add spectral flux-driven parameter modulation"
  - Cybernetic feedback (output shapes input)
  - Extends Lucier (recursive influence)
  - Serves research goal (autonomous systems)
  - **STATUS: roadmap for live routing** until `SpectralAnalyzerNode` is on the pull-render path (STEP 3B)

---

## STEP 7: CHECK IMPLEMENTATION FIDELITY

### Are Parameters Within Whitepaper Ranges?

**From whitepaper §4.2.1:**

```
CFG (Guidance Scale):
  Standard: 3.0-7.0
  Experimental: 15.0-18.0 (overdrive/hallucination zone)
  
Input Strength:
  Initial: 0.60 (Phase 1)
  Recursive drift: 0.45 (Phase 2)
  
Inference Steps:
  Fast: 8-12 steps
  Quality: 20-30 steps
```

**Verify in Constants.swift:**
```swift
// CORRECT (matches whitepaper)
static let cfgScaleRange: ClosedRange<Float> = 3.0...20.0
static let cfgScaleDefault: Float = 10.0  // unity gain

// WRONG (diverges from research)
static let cfgScaleRange: ClosedRange<Float> = 1.0...10.0  // too low, no hallucination
```

### Are Thresholds Scientifically Justified?

**From whitepaper §4.2.2:**

```
Spectral flatness thresholds:
  Phase 1 → 2: 0.35 (signal becomes noisy)
  Phase 2 → 3: 0.65 (full entropic saturation)
```

**Verify in Constants.swift:**
```swift
// CORRECT
static let spectralPhase2Threshold: Float = 0.35
static let spectralPhase3Threshold: Float = 0.65

// WRONG
static let spectralPhase2Threshold: Float = 0.5  // arbitrary, no research basis
```

**If changing a threshold, document WHY:**
```swift
// Adjusted from whitepaper §4.2.2 (0.35) to 0.32 based on empirical
// observation: Phase 2 prompts engage more responsively with metallic
// textures at slightly lower flatness. Maintains same transition logic.
static let spectralPhase2Threshold: Float = 0.32
```

---

## STEP 8: EVALUATE SEMANTIC ALIGNMENT

### Prompt Language Must Be Abstract

**From whitepaper §4.1:**

The system uses **abstract DSP descriptors** to confuse the LLM planner:
- "ferrofluid texture"
- "granular synthesis"
- "spectral degradation"
- "metallic decay"
- "recursive drift"

**NOT musical genres or instruments:**
- ✗ "80s synthwave"
- ✗ "acoustic guitar"
- ✗ "trap beat"

**If adding prompts:**

✓ **ALIGNED:** "non-linear distortion, sub-bass saturation"
✗ **NOT ALIGNED:** "funky bass line with slap"

✓ **ALIGNED:** "stochastic grain cloud, chaotic modulation"
✗ **NOT ALIGNED:** "relaxing ambient pad"

### Lane Preset Philosophy

**Each preset name references:**
- Abstract/material texture that matches the preset's actual sonic behavior
  (FERROFLUID DRONE, SPECTRAL TIDE, NOISE SCAPE)
- OR algorithmic tradition (DRUM LANE via Koenig)
- OR (legacy exception) analog synthesizer lineage (BUCHLA PERC — West Coast
  synthesis, still standing; kept because Buchla's own tradition is closer to
  "resonador de agujero negro" abstraction than a literal gear name)

**2026-07-21 perimeter honesty pass:** "MOOG BASS" and "TB-303 ACID" were
renamed to FERROFLUID DRONE and SPECTRAL TIDE (`Config/Constants.swift`,
`LanePreset.moogBass`/`.tb303Acid` — the Swift symbol names and every DSP
parameter are unchanged, only the performer-facing `name` moved). Naming a
preset after a specific commercial synth implied a subtractive-synth lineage
this instrument doesn't have — it's a slow-feedback resonator, not a Moog or
a 303. Going forward, prefer abstract/material texture names over gear names
for new presets.

**Preset names should NOT be:**
- Genre-based ("TRAP BASS", "DUBSTEP WOBBLE")
- Mood-based ("CHILL VIBES", "EPIC STRINGS")
- Literal samples ("808 KICK", "ACOUSTIC SNARE")

---

## STEP 9: PROTECT THE RECURSIVE CORE

### The Feedback Loop Is Sacred

**The system's identity is the recursive cycle:**

```
Excitation → DSP → Capture → Inference → Feedback → (loop)
```

**Any feature that breaks this cycle must be questioned.**

Examples:

✓ **PRESERVES CYCLE:** "Add delay line in DSP chain"
  - Inserted in processing, output still feeds back
  
✗ **BREAKS CYCLE:** "Add one-shot sample playback"
  - Sample doesn't feed back, no recursion
  - Not part of the feedback topology

✓ **PRESERVES CYCLE:** "Add cross-lane feedback routing"
  - Lane A output → Lane B input
  - Extends recursive topology to networked system

✗ **BREAKS CYCLE:** "Add MIDI-triggered sample launcher"
  - External trigger, no feedback relationship
  - Not derived from recursive state

### The Koenig Seed Is the Primary Excitation

**From whitepaper §4.1:**

The Euclidean rhythm E(5,13) with Dirac impulses is the **canonical input**:
- All frequencies at equal energy (pings entire latent space)
- Prime-number asymmetry (13 steps)
- Mathematically pure (no "musical" content)

**Features that preserve Koenig Seed priority → ALIGNED**
**Features that replace it with "better" inputs → QUESTION**

Example:

✓ **ALIGNED:** "Add silence mode for pure hallucination"
  - Strips ALL input, forces model to rely on latent priors
  - Extends research into model biases

✗ **NOT ALIGNED:** "Replace Koenig Seed with MIDI sequencer"
  - Imposes pitch structure
  - Loses mathematical purity
  - Diverges from Koenig tradition

---

## STEP 10: DOCUMENTATION REQUIREMENTS

### When Implementing Whitepaper Features

**Required documentation:**

1. **Code comments** with section citations
2. **README update** if user-facing
3. **CHANGELOG entry** describing what and why
4. **Whitepaper update** if this is novel research

**Example implementation with full documentation:**

```swift
// Whitepaper §2.6 — Iteration Archive and Selective Recall
//
// Ring buffer of past iteration audio (up to 16 entries). Enables temporal
// navigation within recursive drift: performer can recall archived state,
// replay it through feedback path, and branch into new trajectory.
//
// Implementation: Each entry is [Float] buffer (48000 samples, 1s at 48kHz).
// Total memory: 16 * 48000 * 4 bytes = 3 MB per lane.

final class IterationArchive {
    private let maxSize: Int = LRConstants.iterationArchiveSize
    private var buffers: [[Float]] = []
    private var writeIndex: Int = 0
    
    func append(_ audio: [Float]) {
        if buffers.count < maxSize {
            buffers.append(audio)
        } else {
            buffers[writeIndex % maxSize] = audio
            writeIndex += 1
        }
    }
    
    func recall(at index: Int) -> [Float]? {
        guard index >= 0 && index < buffers.count else { return nil }
        return buffers[index]
    }
}
```

---

## STEP 11: DIVERGENCE PROTOCOL

### When a Proposed Feature Doesn't Align

**Three options:**

#### Option 1: Reject (Recommended)

If the feature:
- Has no theoretical grounding
- Conflicts with research goals
- Makes the system "nicer" instead of "stranger"

**Response:**
```
This feature doesn't align with the whitepaper's research goals. 
Latent Resonator is a stochastic synthesis instrument focused on 
generative degradation and recursive feedback topologies. Adding 
[feature] would diverge from the avant-garde tradition (Xenakis, 
Lucier, Koenig) that grounds the project.

Consider instead: [alternative that aligns with theory]
```

#### Option 2: Adapt

If the feature has merit but needs reframing:

**Example:**
- User: "Add reverb effect"
- Reframe: "Add recursive delay network (Lucier-style)"
  - Same sonic result (spaciousness)
  - Different theoretical framing (recursive filtering)
  - Aligns with §1.2 (Lucier's chamber)

#### Option 3: Extend the Theory

If the feature is genuinely novel and research-worthy:

**Steps:**
1. Implement with rigorous documentation
2. Add whitepaper appendix or new section
3. Cite new theoretical sources if needed
4. Update README with research context

**Example:**
- Feature: "Coupled oscillator network (cross-lane frequency locking)"
- Precedent: Norbert Wiener's *Cybernetics* (self-organizing systems)
- Whitepaper addition: New section on "Emergent Synchronization in Networked Resonators"

---

## QUICK DECISION TREE

```
Proposed feature
    |
    v
Does it serve research goals (§1.3)?
    |
    +-- NO --> REJECT or REFRAME
    |
    +-- YES
        |
        v
    Does it reference historical precedent?
    (Lucier/Xenakis/Schaeffer/Roads/Koenig)
        |
        +-- NO --> Can we cite new sources?
        |          |
        |          +-- NO --> REJECT
        |          +-- YES --> EXTEND THEORY
        |
        +-- YES
            |
            v
        Does it preserve recursive feedback?
            |
            +-- NO --> QUESTION IT
            |
            +-- YES
                |
                v
            Does it implement whitepaper math correctly?
                |
                +-- NO --> FIX IMPLEMENTATION
                |
                +-- YES
                    |
                    v
                ALIGNED — IMPLEMENT WITH CITATIONS
```

---

## WHITEPAPER SECTIONS (QUICK REFERENCE)

```
§1    — Introduction (Neural network as erosion instrument)
§1.1  — Teleology of semantic audio (why we invert it)
§1.2  — Historical lineage (Lucier, recursive systems)
§1.3  — Research objectives

§2    — Implementation (Real-time instrument architecture)
§2.1  — Multi-lane topology
§2.2  — Spectral-conditioned prompt evolution
§2.3  — Auto-decay trajectory
§2.4  — Spectral feature extraction (centroid, flatness, flux)
§2.5  — Colored spectral noise
§2.6  — Iteration archive
§2.7  — Continuous saturation morphing
§2.8  — Configurable FFT size
§2.9  — Motherbase performance surface
§2.10 — Drum Lane (prompt-space sound locking)
§2.11 — Layer carving (frequency slot painting)

§3    — Technical Architecture (ACE-Step 1.5 system)
§3.1  — Hybrid LM + DiT architecture
§3.2  — Exploiting the architecture
§3.3  — Latent space as recursive filter (THE FORMULA; cybernetic SpectralAnalyzer closure = roadmap, STEP 3B)
§3.3.8 — SpectralAnalyzer / ANALYSIS nodes (RFC catalog only; node **roadmap — not wired**, STEP 3B)

§4    — Methodology (Neural Feedback Loop protocol)
§4.1  — Phase A: Koenig Seed generation
§4.1.1 — E(5,13) Euclidean rhythm
§4.1.2 — Dirac impulse (all frequencies)
§4.2  — Phase B: Xenakis Loop
§4.2.1 — CFG overdrive (15-18)
§4.2.2 — Prompt evolution, auto-decay (thresholds/constants exist; closed-loop **roadmap**, STEP 3B)

§5    — Emergent Phenomena
§5.2  — Spectral freeze
§5.4  — Metallic sheen as instrument

§6    — The Black Box Resonator
§6.1  — DSP-only mode, SpectralProcessor as resonator
```

---

## EXAMPLE: FEATURE EVALUATION

### Proposal: "Add MIDI note input for melodic control"

**Evaluation:**

1. **Research goals?** No. Imposes pitch structure.
2. **Historical precedent?** No. Conflicts with Koenig's algorithmic purity.
3. **Maps to formula?** No term for "melody" in `S(i+1) = ACE(...)`.
4. **Aesthetic alignment?** No. Makes system more "musical", less stochastic.

**Decision:** **REJECT**

**Alternative suggestion:** "Add tunable resonator with MIDI note → frequency"
  - Maps to S(i) (modulates existing signal)
  - Precedent: Comb filters in §5.4
  - Doesn't impose melody, just pitch-tuned filtering
  - ALIGNED

---

### Proposal: "Add spectral feature → parameter modulation routing"

**Evaluation:**

1. **Research goals?** YES. Probes latent drift (§1.3, goal 4).
2. **Historical precedent?** YES. Cybernetics (Wiener), recursive systems (Lucier).
3. **Maps to formula?** YES. Output (spectral features) shapes input (parameters).
4. **Aesthetic alignment?** YES. Creates self-modulating, autonomous systems.

**Decision:** **ALIGNED — IMPLEMENT** (spec / roadmap; not live until STEP 3B nodes are wired)

**Whitepaper citation:**
```swift
// Whitepaper §3.3 + Wiener (Cybernetics, 1948)
// STATUS: roadmap — not wired in shipped runtime (needs SpectralAnalyzerNode on pull-render; STEP 3B).
// Self-modulating feedback: spectral state of output modulates
// processing parameters of input. Creates autonomous evolution
// where the system's acoustic behavior shapes its own trajectory.

let centroid = spectralProcessor.spectralCentroid
let modulatedCutoff = baseFilterCutoff * (1.0 + centroid * modulationDepth)
```

---

## PROTECTING THE SOUL

### The Instrument Has an Identity

Latent Resonator is NOT:
- A generic audio app
- A commercial music production tool
- A "user-friendly" synthesizer
- An EDM beat maker

Latent Resonator IS:
- A research instrument for recursive neural synthesis
- A tool for exploring generative degradation
- A cybernetic feedback system
- An implementation of avant-garde music theory
- A machine that reveals its own acoustic unconscious

### Features That Would Destroy the Soul

❌ **Song structure templates** (verse/chorus/bridge)
❌ **Genre presets** ("dubstep bass", "trap hi-hats")
❌ **Musical scale quantizers** (force notes to C major)
❌ **Auto-mastering** (make output "louder and better")
❌ **Social sharing** ("post your AI beat to SoundCloud")
❌ **Gamification** ("unlock new sounds by completing challenges")

These might make the app "successful" but would erase its identity.

### Features That Strengthen the Soul

✓ **Markov sequencer** (extends stochastic synthesis) — **STATUS: roadmap, not wired in shipped runtime** (see STEP 3B)
✓ **Cross-lane spectral routing** (networked feedback topologies)
✓ **Macro-nodes** (encapsulate signal processing blocks)
✓ **Temporal recall** (navigate recursive drift trajectories)
✓ **Spectral feature telemetry** (research analysis tools) — live for macro peak/RMS (`MacroNode.telemetrySnapshot`); centroid/flatness/flux telemetry depends on `SpectralAnalyzerNode`, which is **roadmap, not wired** (see STEP 3B)
✓ **Auto-generated control surface** (adapt to user's patch complexity)

These extend the research while maintaining theoretical coherence.

---

## FINAL VALIDATION

Before approving ANY change:

- [ ] Feature serves at least one research goal (§1.3)
- [ ] Feature references at least one historical precedent
- [ ] Feature preserves recursive feedback topology
- [ ] Feature uses abstract/stochastic language (not "musical")
- [ ] Implementation cites whitepaper sections in comments
- [ ] Parameters within scientifically justified ranges
- [ ] Constants.swift updated with new values
- [ ] README/CHANGELOG updated if user-facing

**If all checkboxes pass → ALIGNED**
**If any checkbox fails → QUESTION or REJECT**

---

## THE AXIOM

```
The error is the aesthetic object.
Generative degradation is not a defect.
Hallucinations are the instrument.
The recursive formula is sacred.
The machine reveals its own body.
```

**Protect the soul. Challenge everything that needs to be.**
