# Latent Resonator — Implementation Plan to Close Technical Gaps

> **Date:** 2026-04-17  
> **Objective:** Complete cohesive plan to transform LR from current state to production-ready instrument with native ACE inference and per-node prompting  
> **Alignment:** Whitepaper — `S(i+1) = ACE(S(i) + N(μ,σ), P, γ)`

---

## Executive Summary

This plan closes the gap between LR's current state and the instrument described in the whitepaper. The work is organized into 6 phases with clear dependencies, deliverables, and success criteria. **Total timeline: 10-14 weeks** (phases 1-3 can execute in parallel after Phase 0).

---

## Phase 0 — Audio Vivo (2-3 days) 🔴 CRITICAL PATH

**Goal:** Nothing else matters if audio doesn't flow. Fix the 7 blockers preventing sound output.

### A.1: ClosedRange<Float> Codable Conformance

**Problem:** `ClosedRange<Float>` cannot be serialized to JSON for node parameters with range constraints.

**Solution:** Create a wrapper type that conforms to Codable.

**Implementation:**
```swift
// In GraphNode.swift or new CodableTypes.swift
struct CodableFloatRange: Codable {
    let lowerBound: Float
    let upperBound: Float
    
    init(_ range: ClosedRange<Float>) {
        self.lowerBound = range.lowerBound
        self.upperBound = range.upperBound
    }
    
    var range: ClosedRange<Float> {
        lowerBound...upperBound
    }
}

// Extend ClosedRange<Float> for convenience
extension ClosedRange<Float> {
    var codable: CodableFloatRange {
        CodableFloatRange(self)
    }
}
```

**Files to modify:**
- `LatentResonator/Graph/GraphNode.swift` — Add CodableFloatRange struct
- `LatentResonator/Graph/CGPoint+Codable.swift` — Add to same file or rename to `CodableExtensions.swift`

**Success Criteria:** Node parameters with ranges serialize/deserialize without crashes.

---

### A.2: KickstartTemplate.json Format Validation

**Problem:** Template uses `{"float": 65.41}` wrapper format that may not deserialize correctly into Swift's `[String: Any]` parameter dictionaries.

**Current format:**
```json
"parameters": {
  "frequency": {"float": 65.41},
  "amplitude": {"float": 0.6}
}
```

**Solution:** Update `NodeGraphStore` to handle both flat and wrapped formats during deserialization.

**Implementation:**
```swift
// In NodeGraphStore.swift
static func normalizeParameterValue(_ value: Any) -> Any {
    // Handle wrapped format {"float": 65.41} → 65.41
    if let dict = value as? [String: Any],
       let floatVal = dict["float"] as? Float {
        return floatVal
    }
    if let dict = value as? [String: Any],
       let intVal = dict["int"] as? Int {
        return intVal
    }
    if let dict = value as? [String: Any],
       let stringVal = dict["string"] as? String {
        return stringVal
    }
    if let dict = value as? [String: Any],
       let boolVal = dict["bool"] as? Bool {
        return boolVal
    }
    return value
}
```

**Files to modify:**
- `LatentResonator/Graph/NodeGraphStore.swift` — Add normalization helper

**Success Criteria:** KickstartTemplate.json loads without parameter parsing errors.

---

### A.3: MasterOutputNode Mixer Connectivity

**Problem:** `MasterOutputNode.audioUnit()` returns `AVAudioMixerNode` but the node may not be properly attached to engine output.

**Current implementation analysis:**
- `MasterOutputNode` owns `private let mixer = AVAudioMixerNode()`
- `audioUnit()` returns this mixer
- `AudioGraphMapper` connects terminal nodes to `masterVolumeNode`, not directly to engine output

**Root cause:** The `masterVolumeNode` passed to `AudioGraphMapper` must be connected to `avEngine.outputNode`.

**Solution:** Verify the connection chain in `NeuralEngine` initialization.

**Implementation:**
```swift
// In NeuralEngine.swift initialization
private func setupAudioEngine() {
    // ... existing setup ...
    
    // CRITICAL: Connect master volume node to output
    let outputNode = avEngine.outputNode
    avEngine.connect(masterVolumeNode, to: outputNode, format: format)
    
    // Verify connection
    print("Audio Engine: masterVolumeNode → outputNode connected")
}
```

**Files to verify:**
- `LatentResonator/NeuralEngine.swift` — Ensure master volume connects to output

**Success Criteria:** Audio flows from source → graph → masterVolumeNode → system output.

---

### A.4: isGraphConnected() Validation

**Problem:** `AudioGraphMapper.validateGraphConnected()` may reject valid graphs or accept invalid ones.

**Current issues to fix:**
1. Only considers nodes with `audioUnit() != nil` as audio nodes (correct)
2. Must have exactly one `MasterOutputNode` (correct)
3. Must verify all audio nodes reachable from output

**Implementation improvements:**
```swift
// In AudioGraphMapper.swift
func validateGraphConnected(_ graph: NodeGraph) throws {
    // 1. Find all audio-producing nodes
    let audioNodes = graph.nodes.values.filter { $0.audioUnit() != nil }
    
    // 2. Must have at least one source
    let sourceNodes = audioNodes.filter { node in
        !graph.edges.values.contains { $0.targetNodeId == node.id && $0.signalType == .audio }
    }
    guard !sourceNodes.isEmpty else {
        throw MapperError.invalidConfiguration("Graph has no audio source nodes")
    }
    
    // 3. Must have exactly one MasterOutputNode
    let masterOutputs = graph.nodes.values.compactMap { $0 as? MasterOutputNode }
    guard masterOutputs.count == 1 else {
        throw MapperError.invalidConfiguration(
            "Graph must have exactly one MasterOutputNode. Found: \(masterOutputs.count)"
        )
    }
    
    // 4. Walk backwards from MasterOutputNode to verify connectivity
    let masterId = masterOutputs[0].id
    var reachable = Set<UUID>()
    var toVisit = [masterId]
    
    while !toVisit.isEmpty {
        let nodeId = toVisit.removeFirst()
        guard reachable.insert(nodeId).inserted else { continue }
        
        // Find all nodes feeding into this one
        for edge in graph.edges.values where edge.targetNodeId == nodeId && edge.signalType == .audio {
            toVisit.append(edge.sourceNodeId)
        }
    }
    
    // 5. All audio nodes must be reachable
    let unreachable = audioNodes.filter { !reachable.contains($0.id) }
    guard unreachable.isEmpty else {
        let names = unreachable.map { "\($0.name) (\($0.nodeType))" }.joined(separator: ", ")
        throw MapperError.invalidConfiguration("Unreachable audio nodes: \(names)")
    }
    
    print("✓ Graph connectivity validated: \(audioNodes.count) audio nodes, \(reachable.count) reachable")
}
```

**Files to modify:**
- `LatentResonator/Graph/AudioGraphMapper.swift` — Update validateGraphConnected()

**Success Criteria:** Valid graphs pass validation; invalid graphs get clear error messages.

---

### A.5: Remove Early-Return Silencioso

**Problem:** There may be silent early returns in `AudioGraphMapper.rebuild()` that skip audio processing.

**Investigation points:**
1. Line 188-191: Skip rebuild if `currentIds == newIds`
2. Line 234-237: Skip tap installation if engine running

**Solution:** Add explicit logging for all early returns and ensure they're intentional.

**Implementation:**
```swift
// In AudioGraphMapper.rebuild()

// Current early return - add explicit reason
if currentIds == newIds {
    print("AudioGraphMapper: Topology unchanged (same \(currentIds.count) nodes), skipping rebuild")
    return  // INTENTIONAL: No topology change means no rebuild needed
}

// Tap installation deferral
if !canInstallTaps {
    print("AudioGraphMapper: WARNING - Engine running, deferring tap installation")
    print("AudioGraphMapper: Taps will be installed on next engine stop/restart cycle")
    // Store deferred taps for later installation
    deferredTaps.append((edge.targetNodeId, sourceAVNode))
}
```

**Files to modify:**
- `LatentResonator/Graph/AudioGraphMapper.swift` — Add logging to all early returns

**Success Criteria:** Every code path has explicit logging; no silent failures.

---

### A.6: loadGraphOrBootstrap() Logging

**Problem:** Graph loading at app startup may fail silently, leaving user with empty graph.

**Solution:** Add comprehensive logging to graph loading pipeline.

**Implementation:**
```swift
// In NodeGraphStore.swift
static func loadGraphOrBootstrap() -> NodeGraph {
    let storeURL = getStoreURL()
    print("[GraphStore] Loading from: \(storeURL.path)")
    
    // Try to load saved graph
    if FileManager.default.fileExists(atPath: storeURL.path) {
        do {
            let data = try Data(contentsOf: storeURL)
            print("[GraphStore] Found saved graph (\(data.count) bytes)")
            
            let decoder = JSONDecoder()
            let graph = try decoder.decode(NodeGraph.self, from: data)
            print("[GraphStore] ✓ Loaded saved graph: \(graph.nodes.count) nodes, \(graph.edges.count) edges")
            return graph
        } catch {
            print("[GraphStore] ✗ Failed to load saved graph: \(error)")
            print("[GraphStore] Falling back to KickstartTemplate")
        }
    } else {
        print("[GraphStore] No saved graph found")
    }
    
    // Load KickstartTemplate
    return loadKickstartTemplate()
}

private static func loadKickstartTemplate() -> NodeGraph {
    guard let url = Bundle.main.url(forResource: "KickstartTemplate", withExtension: "json") else {
        print("[GraphStore] ✗ KickstartTemplate.json not found in bundle!")
        print("[GraphStore] Creating minimal emergency graph")
        return createEmergencyGraph()
    }
    
    do {
        let data = try Data(contentsOf: url)
        print("[GraphStore] Loading KickstartTemplate (\(data.count) bytes)")
        
        let decoder = JSONDecoder()
        let graph = try decoder.decode(NodeGraph.self, from: data)
        print("[GraphStore] ✓ Loaded KickstartTemplate: \(graph.nodes.count) nodes")
        return graph
    } catch {
        print("[GraphStore] ✗ Failed to load KickstartTemplate: \(error)")
        return createEmergencyGraph()
    }
}

private static func createEmergencyGraph() -> NodeGraph {
    print("[GraphStore] Creating emergency graph with basic oscillator")
    let graph = NodeGraph()
    // Add minimal nodes for 220 Hz saw
    let osc = OscillatorNode(params: ["frequency": 220.0, "waveform": "saw"])
    let master = MasterOutputNode(name: "Master Out")
    graph.addNode(osc)
    graph.addNode(master)
    graph.connect(osc.id, port: "out", to: master.id, port: "in", signalType: .audio)
    return graph
}
```

**Files to modify:**
- `LatentResonator/Graph/NodeGraphStore.swift` — Add comprehensive logging

**Success Criteria:** Every graph load path is logged; failures are diagnosed immediately.

---

### A.7: Verify 220 Hz Saw Output

**Problem:** Even with graph properly connected, no sound may be audible.

**Verification steps:**

1. **Oscillator output:** Verify `OscillatorNode.audioUnit()` creates working `AVAudioSourceNode`
2. **Signal generation:** Confirm saw wave is actually generated in render callback
3. **Volume levels:** Check master volume, node amplitude, system volume
4. **Engine state:** Verify `avEngine.isRunning` after rebuild

**Diagnostic code:**
```swift
// In NeuralEngine.swift
func verifyAudioPipeline() {
    print("=== AUDIO PIPELINE VERIFICATION ===")
    
    // 1. Check engine state
    print("Engine running: \(avEngine.isRunning)")
    print("Engine output node: \(avEngine.outputNode)")
    
    // 2. Check attached nodes
    print("Attached nodes: \(audioMapper.attachedNodeCount)")
    
    // 3. Check node graph
    print("Graph nodes: \(nodeGraph.nodes.count)")
    print("Graph edges: \(nodeGraph.edges.count)")
    
    // 4. Check for audio sources
    let sources = nodeGraph.nodes.values.compactMap { $0 as? OscillatorNode }
    print("Oscillator sources: \(sources.count)")
    for source in sources {
        print("  - \(source.name): freq=\(source.frequency), amp=\(source.amplitude)")
    }
    
    // 5. Check MasterOutputNode
    if let master = nodeGraph.nodes.values.first(where: { $0 is MasterOutputNode }) as? MasterOutputNode {
        print("Master output: volume=\(master.volume)")
    }
    
    print("===================================")
}
```

**Files to modify:**
- `LatentResonator/NeuralEngine.swift` — Add verification method
- `LatentResonator/LatentResonatorApp.swift` — Call verification on startup

**Success Criteria:** App launches and 220 Hz saw is audible through speakers.

---

## Phase 1 — Per-Node Prompting (1-2 weeks) 🟡 PARALLELIZABLE

**Goal:** Transform LR from "one global prompt" to "per-macro-node semantic control" — the killer feature.

### 1.1: Enhanced PromptEngineNode with 3-Phase Evolution

**Current state:** `PromptEngineNode` stores a single `text` parameter.

**Target state:** 3-phase evolution driven by spectral flatness, as described in `NeuralNodes.swift` comments.

**Implementation:**
```swift
// In NeuralNodes.swift - Enhance PromptEngineNode
final class PromptEngineNode: BaseGraphNode {
    
    // MARK: - 3-Phase Evolution Parameters
    
    /// Phase 1: Low spectral flatness (harmonic/tonal)
    var phase1Prompt: String {
        get { getParam("phase1Prompt", default: "ferrofluid, subharmonic, warm resonance") }
        set { setParam("phase1Prompt", value: newValue) }
    }
    
    /// Phase 2: Medium spectral flatness (transitional)
    var phase2Prompt: String {
        get { getParam("phase2Prompt", default: "spectral drift, evolving texture") }
        set { setParam("phase2Prompt", value: newValue) }
    }
    
    /// Phase 3: High spectral flatness (chaotic/noise-like)
    var phase3Prompt: String {
        get { getParam("phase3Prompt", default: "granular chaos, noise as structure") }
        set { setParam("phase3Prompt", value: newValue) }
    }
    
    /// Threshold for phase 1→2 transition (flatness value 0-1)
    var phase1to2Threshold: Float {
        get { getParam("phase1to2Threshold", default: 0.3) }
        set { setParam("phase1to2Threshold", value: newValue) }
    }
    
    /// Threshold for phase 2→3 transition
    var phase2to3Threshold: Float {
        get { getParam("phase2to3Threshold", default: 0.7) }
        set { setParam("phase2to3Threshold", value: newValue) }
    }
    
    /// Smoothing factor for phase transitions (0-1)
    var transitionSmoothing: Float {
        get { getParam("transitionSmoothing", default: 0.5) }
        set { setParam("transitionSmoothing", value: newValue) }
    }
    
    // MARK: - Dynamic Prompt Evaluation
    
    /// Get the effective prompt based on current spectral flatness
    func effectivePrompt(forFlatness flatness: Float) -> String {
        if flatness < phase1to2Threshold {
            return phase1Prompt
        } else if flatness < phase2to3Threshold {
            // Interpolate between phase 1 and 2
            let t = (flatness - phase1to2Threshold) / (phase2to3Threshold - phase1to2Threshold)
            let smoothed = smoothstep(t, edge0: 0, edge1: 1)
            return "\(Int((1-smoothed)*100))% \(phase1Prompt), \(Int(smoothed*100))% \(phase2Prompt)"
        } else {
            return phase3Prompt
        }
    }
    
    private func smoothstep(_ x: Float, edge0: Float, edge1: Float) -> Float {
        let t = ((x - edge0) / (edge1 - edge0)).clamped(to: 0...1)
        return t * t * (3 - 2 * t)
    }
}

extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
```

**Files to modify:**
- `LatentResonator/Graph/Nodes/NeuralNodes.swift` — Expand PromptEngineNode

---

### 1.2: Per-MacroNode Prompt Wiring

**Goal:** Each `MacroNode` can have its own `PromptEngineNode` that controls how ACE transforms audio for that macro.

**Architecture:**
```
MacroNode "MOOG BASS"
├── OscillatorNode (excitation)
├── LadderFilterNode (shaping)
├── PromptEngineNode (semantic control) ─┐
├── ACEStepInferenceNode ◄───────────────┘ (prompt input)
└── FeedbackLoopNode (recursive processing)
```

**Implementation:**
```swift
// In MacroNode.swift
final class MacroNode: BaseGraphNode {
    
    /// Reference to internal PromptEngineNode (if present)
    var promptEngine: PromptEngineNode? {
        internalGraph.nodes.values.compactMap { $0 as? PromptEngineNode }.first
    }
    
    /// Reference to internal ACEStepInferenceNode
    var inferenceNode: ACEStepInferenceNode? {
        internalGraph.nodes.values.compactMap { $0 as? ACEStepInferenceNode }.first
    }
    
    /// Get the current effective prompt based on spectral analysis
    func currentPrompt(spectralFlatness: Float) -> String {
        guard let promptEngine = promptEngine else {
            return "spectral texture" // Default fallback
        }
        return promptEngine.effectivePrompt(forFlatness: spectralFlatness)
    }
    
    /// Update inference node with current prompt
    func updatePromptForInference(spectralFlatness: Float) {
        guard let inference = inferenceNode else { return }
        inference.prompt = currentPrompt(spectralFlatness: spectralFlatness)
    }
}
```

**Files to modify:**
- `LatentResonator/Graph/MacroNode.swift` — Add prompt engine wiring

---

### 1.3: PATCH Editor Prompt UI

**Goal:** Add expandable editor panel for 3-phase prompts in the React Flow editor.

**Implementation:**
```tsx
// In PatchEditor/src/nodes/PromptEngineNode.tsx
import { useState, useCallback } from 'react';

export function PromptEngineNode({ id, data }: NodeProps) {
  const nodeData = data as unknown as GraphNodeData;
  const nodeId = nodeData.id || id;
  
  // 3-phase parameters
  const phase1 = (nodeData.parameters?.phase1Prompt as string) ?? '';
  const phase2 = (nodeData.parameters?.phase2Prompt as string) ?? '';
  const phase3 = (nodeData.parameters?.phase3Prompt as string) ?? '';
  const threshold12 = (nodeData.parameters?.phase1to2Threshold as number) ?? 0.3;
  const threshold23 = (nodeData.parameters?.phase2to3Threshold as number) ?? 0.7;
  
  const [isExpanded, setIsExpanded] = useState(false);
  const [editingPhase, setEditingPhase] = useState<1 | 2 | 3 | null>(null);
  
  return (
    <div className="react-flow__node-default node-category-neural">
      <div className="node-header">
        <span>PROMPT ENGINE</span>
        <button onClick={() => setIsExpanded(!isExpanded)}>
          {isExpanded ? '▼' : '▶'}
        </button>
      </div>
      
      {isExpanded ? (
        <div className="prompt-editor-expanded">
          {/* Phase 1 */}
          <div className="phase-section">
            <div className="phase-label">PHASE 1 (Harmonic) &lt; {threshold12.toFixed(2)}</div>
            <textarea 
              value={phase1}
              onChange={(e) => bridge.setParameter(nodeId, 'phase1Prompt', e.target.value)}
              placeholder="e.g., ferrofluid, warm, subharmonic"
            />
          </div>
          
          {/* Phase 2 */}
          <div className="phase-section">
            <div className="phase-label">PHASE 2 (Transitional) {threshold12.toFixed(2)} - {threshold23.toFixed(2)}</div>
            <textarea 
              value={phase2}
              onChange={(e) => bridge.setParameter(nodeId, 'phase2Prompt', e.target.value)}
              placeholder="e.g., spectral drift, evolving"
            />
          </div>
          
          {/* Phase 3 */}
          <div className="phase-section">
            <div className="phase-label">PHASE 3 (Chaotic) &gt; {threshold23.toFixed(2)}</div>
            <textarea 
              value={phase3}
              onChange={(e) => bridge.setParameter(nodeId, 'phase3Prompt', e.target.value)}
              placeholder="e.g., granular chaos, noise structure"
            />
          </div>
          
          {/* Threshold sliders */}
          <div className="threshold-controls">
            <label>1→2 Threshold: {threshold12.toFixed(2)}</label>
            <input 
              type="range" min="0" max="1" step="0.05"
              value={threshold12}
              onChange={(e) => bridge.setParameter(nodeId, 'phase1to2Threshold', parseFloat(e.target.value))}
            />
            <label>2→3 Threshold: {threshold23.toFixed(2)}</label>
            <input 
              type="range" min="0" max="1" step="0.05"
              value={threshold23}
              onChange={(e) => bridge.setParameter(nodeId, 'phase2to3Threshold', parseFloat(e.target.value))}
            />
          </div>
        </div>
      ) : (
        <div className="prompt-preview">
          <div>3-Phase Evolution</div>
          <div className="phase-indicators">
            <span className={phase1 ? 'active' : ''}>1</span>
            <span className={phase2 ? 'active' : ''}>2</span>
            <span className={phase3 ? 'active' : ''}>3</span>
          </div>
        </div>
      )}
      
      {/* Port handles */}
      {nodeData.ports?.map((port) => (
        <Handle
          key={port.id}
          type={port.direction === 'input' ? 'target' : 'source'}
          position={port.direction === 'input' ? Position.Left : Position.Right}
          id={port.id}
        />
      ))}
    </div>
  );
}
```

**Files to modify:**
- `LatentResonator/PatchEditor/src/nodes/PromptEngineNode.tsx` — Complete rewrite for 3-phase UI

**Success Criteria:** User can edit 3-phase prompts per MacroNode with visual threshold controls.

---

## Phase 2 — MLX Backend (2-4 weeks) 🟡 PARALLELIZABLE

**Goal:** Accelerate LLM planner inference by 2-3x using Apple Silicon MLX.

### 2.1: Update Bridge Server for MLX

**Current:** PyTorch MPS backend for LLM planner (~25s for 0.6B model inference).

**Target:** MLX backend for LLM planner (~10s for 0.6B model inference).

**Implementation:**
```python
# In ace_bridge_server.py - Update ACEStepWrapper.load()

def load(self, model_path: str):
    self.model_type = self._detect_model_type(model_path)
    logging.info(f"Detected model type: {self.model_type}")
    
    try:
        import torch
        
        # Check for MLX backend availability
        mlx_available = False
        try:
            import mlx.core as mx
            import mlx_lm
            mlx_available = True
            logging.info("MLX backend available")
        except ImportError:
            logging.info("MLX not available, using PyTorch")
        
        # Device selection with MLX priority on Apple Silicon
        target_device = self._requested_device
        if target_device == "auto":
            if mlx_available and self._is_apple_silicon():
                target_device = "mlx"
            elif torch.backends.mps.is_available():
                target_device = "mps"
            else:
                target_device = "cpu"
        
        logging.info(f"Using backend: {target_device}")
        
        # Load with MLX if available
        if target_device == "mlx" and mlx_available:
            self._load_with_mlx(model_path)
        else:
            self._load_with_pytorch(model_path, target_device)
            
    except Exception as e:
        self.load_error = f"Model load failed: {e}"
        logging.error(f"{self.load_error}\n{traceback.format_exc()}")

def _load_with_mlx(self, model_path: str):
    """Load ACE-Step with MLX backend for LLM planner."""
    from mlx_lm import load as mlx_load
    from transformers import AutoTokenizer
    
    # Load tokenizer (still from transformers)
    self.tokenizer = AutoTokenizer.from_pretrained(model_path)
    
    # Load model with MLX
    self.model, self.config = mlx_load(model_path)
    
    self.device = "mlx"
    self.is_loaded = True
    logging.info(f"✓ ACE-Step loaded with MLX backend")

def _is_apple_silicon(self) -> bool:
    """Detect if running on Apple Silicon."""
    import platform
    return platform.system() == "Darwin" and platform.machine() == "arm64"
```

**Files to modify:**
- `LatentResonator/LatentResonator/Scripts/ace_bridge_server.py` — Add MLX backend support

---

### 2.2: BridgeProcessManager Environment Setup

**Implementation:**
```swift
// In BridgeProcessManager.swift - Update startServerProcess()

private func startServerProcess(profile: PerformanceProfile? = nil) throws {
    let process = Process()
    process.executableURL = pythonInVenv
    
    let effectiveProfile = profile ?? currentProfile
    
    var args = [
        serverScript.path,
        "--host", "127.0.0.1",
        "--port", "\(LRConstants.ACEBridge.defaultPort)"
    ]
    
    // Device selection
    let device: String
    if LRConstants.ACEBridge.forceCPU {
        device = "cpu"
    } else if isAppleSilicon() {
        device = "mlx"  // Prefer MLX on Apple Silicon
    } else {
        device = "auto"
    }
    
    args += ["--device", device]
    
    // Environment variables
    var env = ProcessInfo.processInfo.environment
    env["VIRTUAL_ENV"] = venvDir.path
    env["PYTORCH_ENABLE_MPS_FALLBACK"] = "1"
    env["PYTORCH_MPS_HIGH_WATERMARK_RATIO"] = "0.0"
    
    // MLX specific environment
    if device == "mlx" {
        env["ACESTEP_LM_BACKEND"] = "mlx"
        log("Using MLX backend for LLM planner (2-3x faster)")
    }
    
    process.environment = env
    // ... rest of setup
}

private func isAppleSilicon() -> Bool {
    #if arch(arm64)
    return true
    #else
    return false
    #endif
}
```

**Files to modify:**
- `LatentResonator/LatentResonator/BridgeProcessManager.swift` — Add MLX environment setup

**Success Criteria:** LLM inference time reduces from ~25s to ~10s on M1 Pro.

---

## Phase 3 — PERFORM Mode (2-3 weeks) 🟡 PARALLELIZABLE

**Goal:** Make LR playable as a real-time instrument with XY pad, auto-generated controls, and scene morphing.

### 3.1: XY Pad Parameter Binding

**Current:** `PerformanceMotherbaseView` has XY pad UI but needs proper parameter binding.

**Implementation:**
```swift
// In PerformanceMotherbaseView.swift - Update xyBindingX/Y

private func xyBindingX(macroNode: MacroNode) -> Binding<Float> {
    switch xyAxisMode {
    case .txtChs:
        return Binding(
            get: { macroNode.getParam("texture", default: 0.5) },
            set: { 
                macroNode.setParam("texture", value: $0)
                // Notify audio engine of parameter change
                engine.parameterDidChange.send((macroNode.id, "texture", $0))
            }
        )
    case .cfgFbk:
        return Binding(
            get: { macroNode.getParam("guidanceScale", default: 7.5) },
            set: { 
                macroNode.setParam("guidanceScale", value: $0)
                engine.parameterDidChange.send((macroNode.id, "guidanceScale", $0))
            }
        )
    // ... other cases
    }
}
```

---

### 3.2: Exposed Controls Auto-Generation

**Current:** `PerformLayoutEngine.swift` exists (211 lines) but needs integration.

**Implementation:**
```swift
// In PerformLayoutEngine.swift - Ensure full implementation

struct PerformLayoutEngine {
    
    /// Generate control layout for a MacroNode's exposed parameters
    static func generateControls(for macroNode: MacroNode) -> [PerformControl] {
        let exposed = macroNode.exposedControls
        
        return exposed.map { control in
            PerformControl(
                id: control.id,
                label: control.label,
                type: controlType(for: control.paramId),
                range: control.range,
                defaultValue: control.defaultValue,
                binding: { value in
                    macroNode.setParam(control.paramId, value: value)
                }
            )
        }
    }
    
    private static func controlType(for paramId: String) -> ControlType {
        switch paramId {
        case "frequency", "cutoff": return .knobLogarithmic
        case "resonance", "feedback": return .knobLinear
        case "amplitude", "mix": return .fader
        default: return .knobLinear
        }
    }
}

struct PerformControl: Identifiable {
    let id: String
    let label: String
    let type: ControlType
    let range: ClosedRange<Float>
    let defaultValue: Float
    let binding: (Float) -> Void
}

enum ControlType {
    case knobLinear
    case knobLogarithmic
    case fader
    case toggle
    case selector(options: [String])
}
```

**Files to verify:**
- `LatentResonator/Views/PerformLayoutEngine.swift` — Ensure complete implementation

---

### 3.3: Scene Crossfader

**Current:** `SceneCrossfaderView.swift` exists but needs full implementation.

**Implementation:**
```swift
// In SceneManager.swift

final class SceneManager: ObservableObject {
    
    /// Capture current graph state as a scene
    func captureScene(at index: Int, from graph: NodeGraph) {
        let scene = Scene(
            name: "Scene \(index + 1)",
            nodeParameters: captureAllParameters(from: graph),
            timestamp: Date()
        )
        sceneBank.scenes[index] = scene
        sceneBank.save()
    }
    
    /// Apply scene to graph with crossfade
    func applyScene(at index: Int, to graph: NodeGraph, crossfadeDuration: TimeInterval = 0.1) {
        guard index < sceneBank.scenes.count else { return }
        let scene = sceneBank.scenes[index]
        
        // Animate parameter changes
        let currentParams = captureAllParameters(from: graph)
        let targetParams = scene.nodeParameters
        
        animateParameters(
            from: currentParams,
            to: targetParams,
            duration: crossfadeDuration,
            onUpdate: { interpolatedParams in
                applyParameters(interpolatedParams, to: graph)
            }
        )
    }
    
    /// Morph between two scenes based on crossfader position (0-1)
    func morphScenes(sceneAIndex: Int, sceneBIndex: Int, position: Float, in graph: NodeGraph) {
        guard sceneAIndex < sceneBank.scenes.count,
              sceneBIndex < sceneBank.scenes.count else { return }
        
        let sceneA = sceneBank.scenes[sceneAIndex]
        let sceneB = sceneBank.scenes[sceneBIndex]
        
        // Interpolate all parameters
        let morphed = zip(sceneA.nodeParameters, sceneB.nodeParameters).map { paramA, paramB in
            MorphParameter(
                nodeId: paramA.nodeId,
                paramId: paramA.paramId,
                value: lerp(paramA.value, paramB.value, t: position)
            )
        }
        
        applyParameters(morphed, to: graph)
    }
}

private func lerp(_ a: Float, _ b: Float, t: Float) -> Float {
    a + (b - a) * t
}
```

**Files to modify:**
- `LatentResonator/SceneManager.swift` — Ensure full implementation

**Success Criteria:** User can morph between scenes A and B using crossfader; all parameters interpolate smoothly.

---

## Phase 4 — Whitepaper Topology (1-2 weeks) 🟢 DEPENDENT ON PHASES 0, 1

**Goal:** Implement the complete graph topology from whitepaper §3.3.

### 4.1: Full Graph Structure

**Target topology:**
```
KoenigSeed ──→ LadderFilter ──→ SpectralChain ──→ FeedbackLoopNode ──→ Mixer ──→ MasterOutput
                                                        ↑ feedback edge │
                                                        │               │
                                              ACEStepInferenceNode     │
                                                        ↑               │
                                              PromptEngine (3 phases)   │
                                                                         │
SequencerNode ──→ (gate) ──→ KoenigSeed.trigger                        │
SequencerNode ──→ (control) ──→ FeedbackLoopNode.feedbackAmount (P-Lock)
```

**Implementation:**
```swift
// In NeuralEngine.swift - createWhitepaperTopology()

func createWhitepaperTopology() -> NodeGraph {
    let graph = NodeGraph()
    
    // 1. Excitation: Koenig geometric seed
    let koenig = KoenigSeedNode(
        params: [
            "baseFrequency": 220.0,
            "complexity": 0.5,
            "chaosAmount": 0.2
        ]
    )
    graph.addNode(koenig)
    
    // 2. Initial shaping: Ladder filter (Moog-style)
    let ladder = LadderFilterNode(
        params: [
            "cutoff": 800.0,
            "resonance": 0.4,
            "drive": 0.3
        ]
    )
    graph.addNode(ladder)
    
    // 3. Spectral processing chain
    let spectral = SpectralChainNode(
        params: [
            "granularity": 0.3,
            "saturation": 0.2,
            "freezeAmount": 0.0
        ]
    )
    graph.addNode(spectral)
    
    // 4. Neural inference
    let aceInference = ACEStepInferenceNode(
        params: [
            "guidanceScale": 12.0,
            "numSteps": 20,
            "inputStrength": 0.6
        ],
        bridge: aceBridge
    )
    graph.addNode(aceInference)
    
    // 5. 3-Phase Prompt Engine
    let promptEngine = PromptEngineNode(
        params: [
            "phase1Prompt": "ferrofluid, subharmonic, warm resonance",
            "phase2Prompt": "spectral drift, evolving texture",
            "phase3Prompt": "granular chaos, noise structure",
            "phase1to2Threshold": 0.3,
            "phase2to3Threshold": 0.7
        ]
    )
    graph.addNode(promptEngine)
    
    // 6. Feedback loop (the recursive core)
    let feedback = FeedbackLoopNode(
        params: [
            "delayTime": 0.1,
            "feedback": 0.5,
            "inferenceBufferSize": Int(LRConstants.sampleRate)
        ],
        inferenceNode: aceInference
    )
    graph.addNode(feedback)
    
    // 7. Output chain
    let mixer = MixerNode(params: ["outputGain": 0.8])
    let master = MasterOutputNode(name: "Master Out")
    graph.addNode(mixer)
    graph.addNode(master)
    
    // Connect the graph
    graph.connect(koenig.id, port: "out", to: ladder.id, port: "in", signalType: .audio)
    graph.connect(ladder.id, port: "out", to: spectral.id, port: "in", signalType: .audio)
    graph.connect(spectral.id, port: "out", to: feedback.id, port: "in", signalType: .audio)
    graph.connect(promptEngine.id, port: "text_out", to: aceInference.id, port: "prompt_in", signalType: .control)
    graph.connect(feedback.id, port: "out", to: mixer.id, port: "in0", signalType: .audio)
    graph.connect(mixer.id, port: "out", to: master.id, port: "in", signalType: .audio)
    
    return graph
}
```

**Files to create:**
- `LatentResonator/Graph/Topologies/WhitepaperTopology.swift` — Factory for full topology

---

## Phase 5 — Factory Macro-Nodes (3-4 weeks) 🟢 DEPENDENT ON PHASES 1, 3, 4

**Goal:** Create 7 production-ready virtual instruments, each with unique DSP chains and semantic prompts.

### 5.1: Factory Preset Definitions

```swift
// In LatentResonator/Config/FactoryMacros.swift

enum FactoryMacro: String, CaseIterable {
    case moogBass = "MOOG BASS"
    case tb303Acid = "TB-303 ACID"
    case buchlaPerc = "BUCHLA PERC"
    case rolandPad = "ROLAND PAD"
    case noiseScape = "NOISE SCAPE"
    case koenigDrone = "KOENIG DRONE"
    case spectralPluck = "SPECTRAL PLUCK"
    
    var configuration: MacroConfiguration {
        switch self {
        case .moogBass:
            return MacroConfiguration(
                excitation: .oscillator(waveform: .saw, frequency: 65.41),
                filterChain: [.ladder(cutoff: 120, resonance: 0.6)],
                promptEngine: PromptConfiguration(
                    phase1: "subharmonic warmth, analog saturation, Moog ladder",
                    phase2: "filter sweep motion, resonance bloom",
                    phase3: "distorted bass, aggressive growl",
                    thresholds: (0.25, 0.6)
                ),
                exposedControls: [
                    ExposedControl(param: "frequency", label: "Pitch", range: 32.7...261.6),
                    ExposedControl(param: "cutoff", label: "Filter", range: 80...3000),
                    ExposedControl(param: "resonance", label: "Res", range: 0...1)
                ]
            )
            
        case .tb303Acid:
            return MacroConfiguration(
                excitation: .oscillator(waveform: .square, frequency: 440),
                filterChain: [.ladder(cutoff: 350, resonance: 0.8)],
                promptEngine: PromptConfiguration(
                    phase1: "acid squelch, resonant filter sweep, 303 character",
                    phase2: "decay modulation, envelope driven",
                    phase3: "distorted acid, feedback scream",
                    thresholds: (0.3, 0.7)
                ),
                exposedControls: [
                    ExposedControl(param: "frequency", label: "Pitch", range: 110...880),
                    ExposedControl(param: "cutoff", label: "Cutoff", range: 200...2000),
                    ExposedControl(param: "resonance", label: "Res", range: 0.3...0.95)
                ]
            )
            
        case .buchlaPerc:
            return MacroConfiguration(
                excitation: .koenig(complexity: 0.7, chaos: 0.4),
                filterChain: [.comb(radius: 0.8), .bandpass(center: 1400, bw: 0.3)],
                promptEngine: PromptConfiguration(
                    phase1: "metallic percussion, Buchla timbres, plucked resonance",
                    phase2: "striking overtones, bell-like decay",
                    phase3: "chaotic percussion, noise bursts",
                    thresholds: (0.35, 0.65)
                ),
                exposedControls: [
                    ExposedControl(param: "trigger", label: "Trig", range: 0...1),
                    ExposedControl(param: "complexity", label: "Complex", range: 0...1),
                    ExposedControl(param: "decay", label: "Decay", range: 0.01...2.0)
                ]
            )
            
        case .rolandPad:
            return MacroConfiguration(
                excitation: .oscillator(waveform: .sine, frequency: 110),
                filterChain: [.highpass(cutoff: 400), .chorus(rate: 0.5, depth: 0.3)],
                promptEngine: PromptConfiguration(
                    phase1: "ethereal pad, spectral shimmer, slow evolution",
                    phase2: "breathing texture, chorus drift",
                    phase3: "dissolved harmonics, cloud texture",
                    thresholds: (0.4, 0.75)
                ),
                exposedControls: [
                    ExposedControl(param: "frequency", label: "Root", range: 55...220),
                    ExposedControl(param: "shimmer", label: "Shimmer", range: 0...1),
                    ExposedControl(param: "attack", label: "Attack", range: 0.1...3.0)
                ]
            )
            
        case .noiseScape:
            return MacroConfiguration(
                excitation: .noise(type: .white),
                filterChain: [.highpass(cutoff: 2500), .granular(windowSize: 0.01)],
                promptEngine: PromptConfiguration(
                    phase1: "granular entropy, noise floor as structure, microsound",
                    phase2: "textured static, rhythmic grains",
                    phase3: "chaotic density, noise storm",
                    thresholds: (0.5, 0.8)
                ),
                exposedControls: [
                    ExposedControl(param: "density", label: "Density", range: 0...1),
                    ExposedControl(param: "grainSize", label: "Grain", range: 0.001...0.1),
                    ExposedControl(param: "filter", label: "Filter", range: 1000...8000)
                ]
            )
            
        case .koenigDrone:
            return MacroConfiguration(
                excitation: .koenig(complexity: 0.5, chaos: 0.2),
                filterChain: [.lowpass(cutoff: 2000)],
                promptEngine: PromptConfiguration(
                    phase1: "geometric harmony, Koenig structure, pure ratios",
                    phase2: "evolving geometry, ratio modulation",
                    phase3: "chaotic harmony, dissonant structure",
                    thresholds: (0.3, 0.7)
                ),
                exposedControls: [
                    ExposedControl(param: "baseFreq", label: "Root", range: 55...110),
                    ExposedControl(param: "complexity", label: "Complex", range: 0.2...0.9),
                    ExposedControl(param: "chaos", label: "Chaos", range: 0...0.5)
                ]
            )
            
        case .spectralPluck:
            return MacroConfiguration(
                excitation: .oscillator(waveform: .saw, frequency: 440),
                filterChain: [.spectralFreeze(threshold: -40), .resonator(frequency: 880, decay: 2.0)],
                promptEngine: PromptConfiguration(
                    phase1: "spectral pluck, harmonic resonance, bell sustain",
                    phase2: "frozen attack, spectral sustain",
                    phase3: "dissolved pluck, spectral bloom",
                    thresholds: (0.4, 0.7)
                ),
                exposedControls: [
                    ExposedControl(param: "frequency", label: "Pitch", range: 220...880),
                    ExposedControl(param: "decay", label: "Decay", range: 0.5...5.0),
                    ExposedControl(param: "harmonics", label: "Harm", range: 1...8)
                ]
            )
        }
    }
}
```

**Files to create:**
- `LatentResonator/Config/FactoryMacros.swift` — All factory configurations

---

## Timeline & Dependencies

```
Week 1-2:   [PHASE 0] Audio Vivo (A.1-A.7)
            ↓
Week 2-4:   [PHASE 1] Per-Node Prompting ─┐
            [PHASE 2] MLX Backend ─────────┼── Parallel execution
            [PHASE 3] PERFORM Mode ────────┘
            ↓
Week 4-5:   [PHASE 4] Whitepaper Topology (depends on 0, 1)
            ↓
Week 5-8:   [PHASE 5] Factory Macros (depends on 1, 3, 4)
```

**Critical path:** Phase 0 → Phase 1 (affects 4, 5) → Phase 4 → Phase 5

**Parallelizable:** Phases 1, 2, 3 can execute simultaneously after Phase 0 completes.

---

## Success Criteria Summary

| Phase | Success Criteria | Verification |
|-------|-----------------|--------------|
| 0 | 220 Hz saw audible on launch | Manual audio test |
| 0 | No silent failures | Log inspection |
| 1 | 3-phase prompts editable per MacroNode | UI test |
| 1 | Prompts change with spectral flatness | Audio analysis |
| 2 | LLM inference < 15s on M1 Pro | Timer measurement |
| 3 | XY pad controls parameters in real-time | UI interaction test |
| 3 | Scene crossfade morphs all parameters | Visual/audio verification |
| 4 | Whitepaper topology loads without errors | Graph validation |
| 4 | Recursive feedback loop produces emergent sound | Audio evaluation |
| 5 | 7 factory macros load with unique sound | Factory preset test |
| 5 | Each macro has distinct 3-phase prompts | Prompt inspection |

---

## Risk Mitigation

| Risk | Probability | Impact | Mitigation |
|------|------------|--------|------------|
| MLX backend incompatible with ACE-Step | Medium | High | Keep PyTorch fallback; test both paths |
| Audio graph deadlocks on rebuild | Medium | High | Extensive testing of fade-crossfade algorithm |
| 3-phase prompt blending sounds bad | Low | Medium | Allow manual override; iterate on interpolation |
| Factory macros don't sound distinct | Low | Medium | Extensive sound design iteration |
| Performance mode UI unresponsive | Medium | Medium | Profile on target hardware; optimize early |

---

*Document aligned to whitepaper §3.3, §4.2, §6.1, §7.*
*Implementation preserves existing structure while closing gaps.*
*No new files created without explicit need — all changes modify existing architecture.*
