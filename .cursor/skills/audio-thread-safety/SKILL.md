# Audio Thread Safety — Real-Time DSP Constraints

**Trigger phrases:** "audio thread", "real-time", "DSP", "DSPNode", "render", "GraphAudioEngine", "vDSP", "Accelerate", "glitch", "dropout", "latency", "buffer", "os_unfair_lock"

**Purpose:** Enforce real-time audio thread constraints for the pull-render graph engine. Prevents priority inversions, allocations, and blocking calls that cause audio dropouts. Protects the render budget of `DSPNode.render(...)`, the only function the audio thread calls into graph code.

---

## WHEN TO LOAD THIS SKILL

- User is modifying any `DSPNode` implementation in `Graph/Nodes/*.swift`
- User mentions "audio thread", "real-time", "render callback", "os_unfair_lock"
- User reports audio glitches, dropouts, or crackling
- User is implementing a new effect/filter node or touching `GraphAudioEngine`/`ExecutionPlan`/`BufferPool`
- You're about to modify code reachable from `DSPNode.render` or `FeedbackLoopNode`'s inference `Task`

There is no `ResonatorLane` and no `installTap`-based per-lane audio callback anymore (except `SpectralChainNode`, which is mid-migration and out of scope for most changes). The real-time entry point is `DSPNode.render(inputs:output:frameCount:sampleRate:controls:)`, called once per buffer from inside `GraphAudioEngine`'s single `AVAudioSourceNode`.

---

## THE REAL-TIME CONTRACT (`Graph/Engine/DSPNode.swift`)

```swift
protocol DSPNode: AnyObject {
    var nodeId: UUID { get }
    func render(
        inputs: UnsafeBufferPointer<AudioBuffer>,
        output: AudioBuffer,
        frameCount: Int,
        sampleRate: Double,
        controls: [String: Float]
    )
    func reset()
}
```

Straight from the protocol doc comment — this is the actual contract, not a paraphrase:

1. **No allocations.** No `Array`/`Dictionary`/`String` creation, no `.allocate`/`.deallocate`.
2. **No locks that can be held from the main thread.** Use `os_unfair_lock_trylock` for parameter snapshots; never block.
3. **No blocking I/O, no `print`, no `os_log` at info level.**
4. **Bounded work.** Complete well within the IO buffer deadline — typically **5 ms at 256 frames @ 48 kHz**, **21 ms at 1024 frames @ 48 kHz**. `LRConstants.bufferSize` is the actual configured value; check it before assuming a specific budget.

`GraphAudioEngine` guarantees in return: `inputs[k]`/`output` point to valid, non-aliasing memory for `frameCount` samples; `inputs.count` matches the node's connected audio-input edges **sorted by `targetPortId`**, not necessarily the node's full port list.

---

## FORBIDDEN OPERATIONS

### 1. Heap Allocations

```swift
// ❌ WRONG — allocates every render call
func render(inputs: UnsafeBufferPointer<AudioBuffer>, output: AudioBuffer, frameCount: Int, sampleRate: Double, controls: [String: Float]) {
    var temp = [Float](repeating: 0, count: frameCount)   // HEAP ALLOCATION
}

// ✓ CORRECT — pre-allocated at init, mirrors DelayLineNode/LadderFilterNode
final class MyNode: BaseGraphNode {
    private var delayBufferL: [Float]
    init(id: UUID = UUID(), params: [String: Any] = [:]) {
        self.delayBufferL = [Float](repeating: 0, count: Int(LRConstants.sampleRate * 2.0))
        super.init(...)
    }
}
```

### 2. Locks That Can Block

```swift
// ❌ WRONG — a real lock can be held by the main thread while the audio thread waits
func render(...) {
    mutex.lock(); defer { mutex.unlock() }
}

// ✓ CORRECT — os_unfair_lock_trylock, exactly as GraphAudioEngine.render() does for the plan swap
private var stateLock = os_unfair_lock_s()

func render(...) {
    var snapshot: MyParams?
    if os_unfair_lock_trylock(&stateLock) {
        snapshot = cachedParams
        os_unfair_lock_unlock(&stateLock)
    }
    guard let params = snapshot else { /* skip this block, render silence/passthrough */ return }
}
```

### 3. Blocking Calls (network, file I/O, print)

```swift
// ❌ WRONG
func render(...) { print("rendering") }             // stdout write blocks
func render(...) { let r = urlSession.dataTask(...) } // network blocks

// ✓ CORRECT — write to a lock-free ring buffer, let a Task consume it off-thread.
// This is exactly FeedbackLoopNode's pattern:
func render(...) {
    captureBuffer.write(inputPtr, count: frameCount)     // pointer-based, no alloc
    let read = feedbackBuffer.read(into: outputPtr, count: frameCount)
    // trigger check — cheap, no await here:
    if captureBuffer.availableToRead >= inferenceBufferSize {
        tryTriggerInference()   // os_unfair_lock_trylock check-and-set, spawns Task if free
    }
}
```

### 4. Main-Thread Dispatch From the Render Callback

```swift
// ❌ WRONG — DispatchQueue.main.sync from the audio thread risks deadlock
func render(...) { DispatchQueue.main.sync { self.uiState = newState } }

// ✓ CORRECT — write a plain Float/Int (torn reads are inaudible), let the main thread poll or
// use os_unfair_lock_trylock for anything larger than one primitive.
private var currentRMS: Float = 0.0
func render(...) { currentRMS = computeRMS(output) }
// Main thread, throttled to ~15 Hz elsewhere:
// DispatchQueue.main.async { self.displayedRMS = self.currentRMS }
```

---

## THE PLAN-SWAP PATTERN (`GraphAudioEngine`) — STUDY THIS, IT'S THE REAL THING

`GraphAudioEngine` is the canonical example of safe main-thread ⇄ audio-thread handoff in this codebase. Copy this shape whenever a `DSPNode` needs a "safely swap a chunk of state that the main thread produces and the audio thread consumes" pattern:

```swift
// Main thread — never blocks the audio thread even mid-swap
func adopt(_ plan: ExecutionPlan?) {
    os_unfair_lock_lock(&planLock)
    currentPlan = plan
    os_unfair_lock_unlock(&planLock)
}

// Audio thread — trylock, never lock(). If the main thread holds it, render silence
// for exactly one buffer (inaudible at 5-20ms) rather than wait.
var planSnapshot: ExecutionPlan?
if os_unfair_lock_trylock(&planLock) {
    planSnapshot = currentPlan
    os_unfair_lock_unlock(&planLock)
}
guard let plan = planSnapshot else { /* zero the ABL, return */ }
```

Use `lock()` (blocking) on the **producer** side only if the producer is the main thread and the critical section is a single pointer assignment (as above) — never on the audio-thread side. The audio thread always uses `trylock()` and has a defined fallback (silence / passthrough / previous value) for the "didn't get the lock" case.

---

## LOCK-FREE SPSC RING BUFFER (`CircularAudioBuffer.swift`) — THE REAL IMPLEMENTATION

The actual class uses `os_unfair_lock_s()` around the `_writePos`/`_readPos` *scalars* — not raw unguarded atomics. The critical section is a single `Int` read/write (~1ns), so this is still real-time safe; the lock exists purely for the cross-thread memory barrier, and the actual sample copy happens **outside** the lock:

```swift
final class CircularAudioBuffer: @unchecked Sendable {
    private var _writePos: Int = 0   // producer-owned
    private var _readPos: Int = 0    // consumer-owned
    private var _lock = os_unfair_lock_s()

    @discardableResult
    func write(_ source: UnsafePointer<Float>, count: Int) -> Int {
        let (w, r) = loadPositions()                 // locked, ~1ns
        let toWrite = min(count, capacity - 1 - ((w &- r) & mask))
        var wp = w
        for i in 0..<toWrite { storage[wp & mask] = source[i]; wp &+= 1 }  // unlocked copy
        storeWritePos(wp)                             // locked, ~1ns
        return toWrite
    }
}
```

Single producer (audio thread or inference `Task`, never both) writes `_writePos`; single consumer reads `_readPos`. `FeedbackLoopNode` uses two of these: `captureBuffer` (audio → inference) and `feedbackBuffer` (inference → audio).

---

## ALLOWED OPERATIONS

```swift
// Value types, fixed-size/pre-allocated array access, UnsafePointer access
let value = buffer[index]; buffer[index] = newValue
buffer.withUnsafeMutableBufferPointer { ptr in ptr[index] = newValue }

// Accelerate (vDSP) — pre-allocated internal state, vectorized, no syscalls
vDSP_vmul(a, 1, b, 1, &result, 1, vDSP_Length(count))
vDSP_rmsqv(samples, 1, &rms, vDSP_Length(count))

// Standard math, @inline(__always) hot functions
let y = sin(x); let z = tanhf(x)
```

---

## PATTERN: PARAMETER SMOOTHING (STILL REQUIRED)

Abrupt parameter jumps click. Every node that reads a user-facing `@Published`/`getParam` value directly in `render` should smooth it — see `LadderFilterNode.render` for the live example (`smoothedCutoff += alpha * (cutoff - smoothedCutoff)`, `alpha = 0.05`).

```swift
private var smoothedCutoff: Float = LRConstants.filterCutoffDefault

func render(...) {
    let alpha: Float = 0.05
    smoothedCutoff += alpha * (cutoff - smoothedCutoff)
    // use smoothedCutoff, not cutoff, in the DSP below
}
```

## PATTERN: NAN/INF VALIDATION

`CombFilterNode`/`DelayLineNode`/`TunableResonatorNode` all guard their feedback path the same way — copy this, don't invent a new idiom:

```swift
let mixed = input[i] + delayed * feedback
let safe = mixed.isNaN || mixed.isInfinite ? 0 : mixed
buffer[writePos] = safe
```

## PATTERN: TRIGGER, NOT POLL, FOR ASYNC WORK

**Do not** spawn an unconditional `Task` loop with a fixed `Task.sleep` in a node's `init`. That was the old `FeedbackLoopNode` pattern and it is explicitly banned now — it burns a thread forever and hides the actual trigger condition. Instead, check a real condition inside `render()` (buffer fullness, a flag) and spawn exactly one `Task` guarded by an `os_unfair_lock_trylock`-checked boolean, clearing it in a `defer` inside the `Task`:

```swift
private var isInferring = false
private var inferLock = os_unfair_lock_s()

func render(...) {
    // ... cheap buffer write/read ...
    guard captureBuffer.availableToRead >= inferenceBufferSize else { return }
    var shouldSpawn = false
    if os_unfair_lock_trylock(&inferLock) {
        if !isInferring { isInferring = true; shouldSpawn = true }
        os_unfair_lock_unlock(&inferLock)
    }
    guard shouldSpawn else { return }
    Task(priority: .utility) { [weak self] in
        defer {
            if let self { os_unfair_lock_lock(&self.inferLock); self.isInferring = false; os_unfair_lock_unlock(&self.inferLock) }
        }
        await self?.runInferenceCycle()
    }
}
```

---

## DEBUGGING AUDIO ISSUES

**Dropouts/glitches** → Instruments Time Profiler during playback; look for anything inside the `AVAudioSourceNode` render closure taking > budget, or `malloc`/`pthread_mutex_lock`/`write` syscalls in the stack. Thread Sanitizer (Scheme → Diagnostics) catches the data races that cause them.

**Crackling / zipper noise** → missing parameter smoothing, or phase discontinuity on an oscillator frequency change (keep the phase accumulator running, don't reset it).

**Silent output** → check `GraphAudioEngine.currentPlanStepCount` (0 means no `ExecutionPlan` was adopted — likely no `MasterOutputNode` reachable, or every node in the chain returned `nil` from `dspNode()`), NaN/Inf in the signal path, and `NeuralEngine.verifyAudioPipeline()`'s printed diagnostic.

---

## CODE REVIEW CHECKLIST

- [ ] No heap allocations, locks-that-block, blocking I/O, or `print` inside `render`/`reset`
- [ ] All buffers pre-allocated in `init`/`init(from:)`
- [ ] Cross-thread state uses `os_unfair_lock_trylock` (audio-thread side) or a `CircularAudioBuffer`, never a real mutex
- [ ] Parameters smoothed where an abrupt jump would click
- [ ] NaN/Inf guarded before writing into any feedback/delay buffer
- [ ] Any new async work is trigger-based (condition + trylock-guarded flag), not an unconditional polling loop
- [ ] vDSP used for vector math where it's a straight win; scalar loops fine for single-sample recursive filters (ladder, comb) where vDSP doesn't apply

---

## THE GOLDEN RULE

```
If it allocates, blocks, or locks (a real lock) — it does not belong in DSPNode.render.
Move it behind a trigger. Use lock-free buffers. Use os_unfair_lock_trylock. Snapshot state.

The audio thread is sacred. < 5ms or silence.
```
