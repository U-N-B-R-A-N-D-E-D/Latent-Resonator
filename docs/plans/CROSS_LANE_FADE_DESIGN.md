# Cross-Lane Fade Design Document

## Week 8 - D5: Cross-Lane Routing

### Overview

Cross-lane fade enables smooth transitions when audio or control signals route between lanes. This document specifies the fade behavior for cross-lane connections to prevent clicks, pops, and discontinuities during graph topology changes.

### Problem Statement

When cross-lane edges are added or removed:
- Audio signals may abruptly start/stop (click/pop)
- Control signals may jump discontinuously
- Modulation may cause zipper noise

Without cross-lane fade, these artifacts degrade the listening experience during live performance.

### Design Principles

1. **Click-free**: All signal level changes use smooth fade curves
2. **Consistent**: Same fade behavior for audio and control (scaled appropriately)
3. **Fast**: Fade duration < 50ms to feel responsive
4. **Automatic**: No manual intervention required

### Fade Architecture

```
Cross-Lane Connection Lifecycle:

1. Edge Creation Request
   ↓
2. Validate (no cycles)
   ↓
3. Start Fade In (0 → 1, 30ms)
   ↓
4. Connection Active (full level)
   ↓
5. Edge Removal Request
   ↓
6. Start Fade Out (1 → 0, 30ms)
   ↓
7. Remove Edge (when fade complete)
```

### Implementation Strategy

#### Option A: AVAudioMixerNode Gain (Selected)

Use the built-in `outputVolume` property of `AVAudioMixerNode` for fade:

```swift
// Cross-lane fade via mixer node volume
func fadeCrossLaneConnection(
    mixerNode: AVAudioMixerNode,
    to volume: Float,
    duration: TimeInterval = 0.03
) {
    mixerNode.outputVolume = volume  // Ramp happens in audio thread
}
```

**Pros:**
- Built into AVAudioEngine (no extra nodes)
- Optimized ramp in CoreAudio audio thread
- Works with existing AudioGraphMapper

**Cons:**
- Requires mixer node for each cross-lane edge
- Slightly more memory per connection

#### Option B: Custom Ramp in SourceNode (Not Selected)

Add per-output gain with smoothing in the source node's render callback.

**Pros:**
- No extra nodes needed
- Full control over curve shape

**Cons:**
- Adds complexity to every source node
- Risk of audio thread instability

### Selected Design: Option A

#### Fade Parameters

```swift
struct CrossLaneFadeParameters {
    /// Fade in duration when edge is created (seconds)
    static let fadeInDuration: TimeInterval = 0.030  // 30ms
    
    /// Fade out duration when edge is removed (seconds)
    static let fadeOutDuration: TimeInterval = 0.030  // 30ms
    
    /// Curve type for fade
    static let curve: FadeCurve = .equalPower
    
    enum FadeCurve {
        case linear
        case equalPower  // For audio: -3dB center
        case sigmoid     // For control: smooth S-curve
    }
}
```

#### AudioGraphMapper Changes

```swift
// In AudioGraphMapper.rebuild():

// For each cross-lane edge:
// 1. Create AVAudioMixerNode (fade bridge)
// 2. Connect source → fadeMixer (volume 0 initially)
// 3. Connect fadeMixer → target
// 4. Ramp volume to 1.0 over fadeInDuration

private var crossLaneFadeMixers: [UUID: AVAudioMixerNode] = [:]

func connectCrossLaneWithFade(
    source: AVAudioNode,
    target: AVAudioNode,
    edgeId: UUID
) {
    let fadeMixer = AVAudioMixerNode()
    avEngine.attach(fadeMixer)
    
    // Initial: volume = 0 (silent)
    fadeMixer.outputVolume = 0.0
    
    // Connect source → fadeMixer → target
    avEngine.connect(source, to: fadeMixer, format: format)
    avEngine.connect(fadeMixer, to: target, format: format)
    
    // Store for later fade out
    crossLaneFadeMixers[edgeId] = fadeMixer
    
    // Fade in
    fadeMixer.outputVolume = 1.0  // CoreAudio ramps over ~30ms
}
```

#### NodeGraph Changes

```swift
// Add to GraphEdge:
var fadeState: FadeState = .inactive

enum FadeState {
    case inactive      // Edge not yet connected
    case fadingIn      // Volume 0 → 1
    case active        // Full volume
    case fadingOut     // Volume 1 → 0
    case removing      // Ready for removal
}

// Add to NodeGraph:
/// Queue edges scheduled for removal (waiting for fade out)
var pendingRemovals: [UUID] = []
```

### Control Signal Fade

Control signals (modulation) use a different approach:

```swift
// Control fade happens in ControlGraphEvaluator

func applyModulationWithFade(
    outputs: [UUID: [String: Float]],
    graph: NodeGraph,
    dt: Double
) {
    for edge in graph.edges.values where edge.signalType == .control {
        let sourceValue = outputs[edge.sourceNodeId]?[edge.sourcePortId] ?? 0
        
        // Apply edge-specific fade multiplier
        let fadedValue = sourceValue * edge.fadeMultiplier
        
        // Smoothly approach target fade multiplier
        let targetMultiplier = edge.fadeState == .active ? 1.0 : 0.0
        edge.fadeMultiplier += (targetMultiplier - edge.fadeMultiplier) * min(1.0, dt / 0.03)
        
        // Apply modulated parameter...
    }
}
```

### UI Indicators

Visual feedback during fade:

```swift
// In PATCH view edge rendering:
EdgeView {
    // Edge opacity reflects fade multiplier
    opacity: edge.fadeMultiplier
    
    // Pulsing animation during fade
    animation: edge.fadeState == .fadingIn || edge.fadeState == .fadingOut 
               ? .pulse 
               : .none
}
```

### Performance Considerations

| Metric | Target | Notes |
|--------|--------|-------|
| Fade duration | 30ms | Imperceptible as discontinuity |
| Max concurrent fades | 16 | Arbitrary, based on expected usage |
| CPU overhead | <0.1% | One mixer node per cross-lane edge |
| Memory overhead | 8KB per edge | AVAudioMixerNode footprint |

### Testing Strategy

1. **Click Detection**: Automated test for zero crossings during fade
2. **Level Monitoring**: Verify gain curve follows expected profile
3. **Concurrency**: Multiple simultaneous cross-lane fades
4. **Cancellation**: Fade in interrupted by immediate fade out

### Future Enhancements (v2.1+)

1. **Configurable fade time**: User preference for faster/slower fades
2. **Custom curves**: Linear, equal-power, exponential, S-curve options
3. **Sync to tempo**: Fade duration locked to sequencer BPM
4. **Visual waveform**: Show fade curve in PATCH view

### Implementation Status

| Component | Status | Notes |
|-----------|--------|-------|
| Design document | COMPLETE | This document |
| Fade parameters | COMPLETE | Constants defined |
| Audio fade mixer | PENDING | Requires AudioGraphMapper changes |
| Control fade smoothing | PENDING | Requires ControlGraphEvaluator changes |
| UI indicators | PENDING | PATCH view enhancement |
| Automated tests | PENDING | Test suite creation |

### Related Documents

- `latent_resonator_v2.0_integration_EXPANDED.md` - Week 8 D5
- `CROSS_LANE_ROUTING_TESTS.swift` - Unit tests for cross-lane routing
- `AudioGraphMapper.swift` - Engine rebuild logic

---

**Version:** 1.0  
**Last Updated:** 2026-04-05  
**Status:** Design Complete, Implementation Pending
