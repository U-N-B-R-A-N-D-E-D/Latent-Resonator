# Cross-Lane Audio Routing: Fade-Crossfade Design

## Overview

Cross-lane audio routing enables audio from one lane to be processed through another lane's spectral chain, creating complex feedback networks and modulation possibilities. This document specifies the fade-crossfade algorithm to prevent clicks/pops during graph reconfiguration.

## Problem Statement

Connecting Lane A.output → Lane B.input requires reconfiguring AVAudioEngine. Naive reconfiguration produces clicks/pops because:

1. Stopping the engine interrupts audio flow abruptly
2. Disconnecting/connecting nodes creates discontinuities
3. State in delay lines and filters is lost
4. Different processing paths have different latencies

## Solution: Parameter Ramp Crossfade

### Algorithm

The crossfade happens in four phases over 100ms total:

```
Phase 1 (0-50ms):   Fade down source lane output volume (linear ramp to 0.0)
Phase 2 (50-60ms):  Rebuild audio graph with new connection
Phase 3 (60-100ms): Fade up source lane output volume (linear ramp to 1.0)
```

### Volume Ramp Function

```swift
func rampVolume(lane: ResonatorLane, to targetValue: Float, duration: TimeInterval) {
    let startValue = lane.volume
    let startTime = CACurrentMediaTime()
    let frameCount = Int(duration * 60)  // 60Hz control rate
    
    for frame in 0...frameCount {
        let t = Float(frame) / Float(frameCount)  // 0.0...1.0
        // Linear interpolation
        lane.volume = startValue + (targetValue - startValue) * t
        
        // Wait for next frame (16.67ms at 60Hz)
        Thread.sleep(forTimeInterval: 1.0/60.0)
    }
}
```

### Graph Rebuild Sequence

```swift
func connectCrossLane(from sourceLane: ResonatorLane, to targetLane: ResonatorLane) {
    // Phase 1: Fade down
    rampVolume(lane: sourceLane, to: 0.0, duration: 0.05)
    
    // Phase 2: Rebuild graph
    audioEngine.stop()
    
    // Remove existing tap on source if any
    audioGraphMapper.removeTap(from: sourceLane)
    
    // Create new cross-lane edge in NodeGraph
    let edge = GraphEdge(
        id: UUID(),
        sourceNodeId: sourceLane.outputNodeId,
        sourcePortId: "out",
        targetNodeId: targetLane.spectralChainNodeId,
        targetPortId: "in",
        signalType: .audio,
        isCrossLane: true
    )
    nodeGraph.addCrossLaneEdge(edge)
    
    // Rebuild topology
    try? audioGraphMapper.rebuild(from: nodeGraph)
    
    audioEngine.start()
    
    // Phase 3: Fade up
    rampVolume(lane: sourceLane, to: 1.0, duration: 0.04)
}
```

## DECISION D5: DAG Validation (No Cycles)

Cross-lane connections must maintain a Directed Acyclic Graph (DAG). Cycles create feedback loops that:

1. Cause infinite recursion in topology sorting
2. Create unstable positive feedback in audio
3. Violate the ResonatorLane's internal feedback model

### Cycle Detection Algorithm

```swift
func validateCrossLaneConnection(from sourceId: UUID, to targetId: UUID) -> Bool {
    // Check if adding edge would create a cycle
    // DFS from target back to source
    var visited: Set<UUID> = []
    return !hasPath(from: targetId, to: sourceId, visited: &visited)
}

private func hasPath(from: UUID, to: UUID, visited: inout Set<UUID>) -> Bool {
    if from == to { return true }
    guard !visited.contains(from) else { return false }
    visited.insert(from)
    
    // Check all outgoing cross-lane edges from 'from'
    for edge in crossLaneEdges.values where edge.sourceNodeId == from {
        if hasPath(from: edge.targetNodeId, to: to, visited: &visited) {
            return true
        }
    }
    return false
}
```

### User Experience

When a user attempts to create a cycle:

1. **Visual**: The connection line turns red during drag
2. **Feedback**: Cursor changes to "not allowed" symbol
3. **Error**: If programmatically created, throws `GraphError.cycleDetected`
4. **Recovery**: Invalid edges are rejected, graph remains unchanged

## AudioGraphMapper Integration

### Tap-Based Connection Pattern

Cross-lane audio uses taps rather than direct AVAudioEngine.connect() to preserve the independence of each lane's subgraph:

```swift
// In AudioGraphMapper.rebuild()
for edge in allAudioEdges {
    if edge.isCrossLane {
        // Cross-lane: install tap to feed ring buffer
        let sourceNode = attachedAudioNodes[edge.sourceNodeId]
        let targetNode = findSpectralChainNode(edge.targetNodeId)
        
        // Target receives audio via tap callback writing to its input ring buffer
        sourceNode?.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            targetNode?.feedAudio(buffer.floatChannelData![0])
        }
    } else {
        // Intra-lane: standard connection
        avEngine.connect(sourceNode, to: targetNode, format: format)
    }
}
```

### Volume Control Architecture

Each lane has a volume node at the output:

```
Lane N Subgraph:
  [SpectralChain] -> [Effects] -> [LaneVolumeNode] -> [MasterMixer]
                                        |
                                        v
                                  [Cross-lane Tap]
```

The `LaneVolumeNode` is an `AVAudioMixerNode` that:
1. Receives the mixed output of the lane
2. Applies volume (for fade-crossfade)
3. Feeds both the master mixer AND cross-lane taps

## Latency Considerations

### Cross-Lane Latency Budget

| Component | Latency |
|-----------|---------|
| Tap buffer size | ~85ms (4096 @ 48kHz) |
| Ring buffer write/read | 0ms (lock-free) |
| Volume ramp (fade) | 50ms + 40ms |
| Graph rebuild | ~10ms |
| **Total reconfiguration** | **~100ms** |

### Compensation

The 100ms fade is perceptible but:

1. **Musical**: Equivalent to a brief rest in performance
2. **Masked**: Volume is at 0 during rebuild
3. **Context**: Graph reconfiguration is infrequent (setup-time operation)

## Error Handling

### Scenarios

| Scenario | Response |
|----------|----------|
| Cycle detected | Reject edge, throw error, UI shows warning |
| Engine restart fails | Revert to previous topology, fade back up |
| Tap installation fails | Degrade to direct connection, log warning |
| Buffer underrun | Zero-fill, continue (graceful degradation) |

### Recovery

```swift
do {
    try rebuildWithCrossLaneConnections()
} catch {
    // Revert
    nodeGraph.removeCrossLaneEdge(edge)
    try? audioGraphMapper.rebuild(from: nodeGraph)
    fadeVolumeUp()
    throw CrossLaneError.rebuildFailed(underlying: error)
}
```

## Testing

### Unit Tests

1. **Cycle Detection**: Verify DFS correctly identifies cycles
2. **Volume Ramp**: Verify linear interpolation over time
3. **Edge Validation**: Accept valid, reject cyclic

### Integration Tests

1. **Cross-lane audio flow**: Verify audio from Lane A reaches Lane B
2. **Fade smoothness**: Measure amplitude envelope during transition
3. **Graph topology**: Verify serialization preserves cross-lane edges

### Performance Tests

1. **Rebuild timing**: Measure actual graph rebuild time
2. **CPU impact**: Verify no dropouts during fade-crossfade
3. **Memory**: Ensure no leaks in tap/ring buffer system

## References

- Whitepaper §4.2.3: Cross-Lane Routing Architecture
- DECISION D5: DAG-only cross-lane connections (no cycles)
- `AudioGraphMapper.swift`: Implementation of tap-based routing
- `NodeGraph.swift`: Cross-lane edge management and validation
