# Full Migration to Bespoke Synth — 2026-09-11

## Why

The native canvas (SwiftUI, custom `GraphAudioEngine` → `ExecutionPlan` → `DSPNode`) is
the source of the current pain: poor UX, no smooth node interaction, lag, freezes. Four
months of work went into solving a problem (real-time visual patching) that has already
been solved elsewhere for 20+ years. What does work and doesn't deserve to be thrown away
is the "neural" half: the Python bridge to ACE-Step (9/9 tests) and the recursive
resonator concept from the whitepaper. See `docs/whitepaper.md` for the formula
`S(i+1) = ACE(S(i) + N(mu,sigma), P, gamma)`.

Decision: migrate everything onto **Bespoke Synth** (github.com/BespokeSynth/BespokeSynth,
GPL-3, active — last update June 2026) as the foundation **our own** project runs on.
This is our own fork/build, not a contribution to Cycling/BespokeSynth's project — no
PR is opened and nothing is coordinated on their Discord. There is already direct
technical precedent for the pattern we need: a **StableAudio3** module (May 2026)
generates audio from a prompt via a neural model, embedded as a patch node — we use it
as a real implementation reference, not as anyone's endorsement.

Key architectural fact (confirmed by research, not assumed): the real bottleneck is
ACE-Step's own inference (local CPU), not the host. No environment — Bespoke, Cardinal,
Pd — runs an audio diffusion model inside the audio callback. The pattern validated by
the industry (see ANIRA, arXiv:2506.12665) is decoupling inference to a thread pool and
handing the result back through a lock-free ring buffer — exactly what
`BridgeProcessManager.swift` already does by hand. Migrating isn't solving a new problem,
it's porting a solution we already proved, to a host with better UX.

Confirmed in Bespoke Synth's own source (`Source/` of the repo, via the GitHub API): it
already ships **embedded Python out of the box** —
`Source/ScriptModule_PythonInterface.i` (pybind11 bindings) +
`Source/cmake/bundle-python.cmake` (bundles a Python runtime with the app). Python isn't
a guest there, it's part of the official build. This opens a second integration path
(see Phase 3, option B) in addition to the subprocess+HTTP path we've already proven.

---

## What's "real juice" (kept) vs. "spam" (dropped)

### Real — ported or reused as-is

| Piece | Current path | Destination |
|---|---|---|
| Bridge server (Flask/waitress, WAV codec, `/health` `/status` `/infer` `/shutdown` endpoints) | `LatentResonator/LatentResonator/Scripts/ace_bridge_server.py` (994 lines) | Copied **unmodified** into a new `ace-bridge/` folder/repo. Pure Python, zero Swift dependency. |
| Bridge test suite (9/9) | `.../Scripts/test_bridge.py` | Copied unmodified. Remains the Python-side regression gate regardless of host. |
| Setup/env | `requirements_bridge.txt`, `setup_ace_bridge.sh`, `.venv-ace-bridge/` | Unmodified. |
| Vendored model | `ACE-Step/` (full upstream project repo) | Unmodified. |
| **Process lifecycle logic** (discover model, install package if missing, download model if missing, health-check polling, graceful shutdown waiting on in-flight inference, kill-by-port fallback) | `BridgeProcessManager.swift` (1097 lines) | **The Swift is not ported** — the already production-validated *behavior* is ported to C++ inside the new module (Phase 3). This file is the specification, not the final artifact. |
| Recursive resonator concept, §3.3/§6.1 formalism | `docs/whitepaper.md` (361 lines) | Kept as the canonical design doc; adapted into the new module's README. |
| Behavior prior art pinned in Swift tests (21 deliberate TODOs, edge cases in `AudioPipelineValidator`/`ParameterRouterController`) | `LatentResonatorTests/*` | Used as a manual verification checklist in Phase 4 — **no code is ported**; most of these TODOs simply stop applying (Bespoke's own graph already handles disconnected nodes, mixing, etc. natively). |

### Spam — dropped without regret

- The entire SwiftUI canvas: `PatchCanvasView`, `CableLayer`, `NodeCardChrome`, node
  cards (Oscillator/Delay/LadderFilter/Mixer/MasterOutput/etc.).
- The custom graph engine: `GraphAudioEngine`, `ExecutionPlan`, `DSPNode`, `NodeGraph`.
- `NeuralEngine.swift` (god-class), `ParameterRouterController.swift`,
  `AudioPipelineValidator.swift`, `MacroMixerController`, macro controllers, gesture
  recording, Motherbase/scene crossfader.
- `ACEStepBridge.swift` (the Swift bridge wrapper — replaced by the new C++ module).
- `stash@{0}` ("epitaxy: pre-switch") — confirmed dead in the prior review, dropped.
- `LatentResonator.xcodeproj`, old `dist/*.app` folders — archived, not migrated.
- The 122 Swift tests — not portable (they test an engine that stops existing). Read
  once as a behavior spec (Phase 4), then retired along with the rest of the engine.

---

## Phases

### Phase 0 — This is our fork, not a contribution to Bespoke

Bespoke doesn't load external modules — everything lives compiled inside the binary
itself. That means the only real path to running `ModuleACEResonator` is **our own
fork**, with our module added to its source tree and compiled as part of our own
binary. That is exactly what we did and continue to do — there is **no** intent to PR
`BespokeSynth/BespokeSynth`, nor to coordinate anything on their Discord. Their code
remains theirs (GPL-3, Copyright Ryan Challinor); we maintain our own fork/build with
the module added, for our own use.

Real implication (a licensing fact, not a community courtesy): Bespoke Synth is GPL-3.
If we ever distribute a compiled binary of our fork, GPL-3 obligates us to make that
fork's full source available to whoever receives it. This doesn't block anything today
(all the work lives in our own public repo), but it's a real obligation to keep in mind
before a binary release, not a nicety.

### Phase 1 — Freeze the "real juice" into a host-agnostic package

- Extract `ace_bridge_server.py`, `test_bridge.py`, `requirements_bridge.txt`,
  `setup_ace_bridge.sh` into an independent `ace-bridge/` folder/repo (repo split TBD).
- Run `test_bridge.py` standalone, with no Swift anywhere on the path — confirms this
  piece **never actually depended on the host**, which validates that the UI migration
  doesn't put it at risk.
- Freeze `docs/whitepaper.md` as-is; don't touch the formula or the theoretical
  foundation.

### Phase 2 — Bootstrap the Bespoke Synth build (sanity check before coding)

```bash
git clone https://github.com/BespokeSynth/BespokeSynth   # or your fork
cd BespokeSynth
git submodule update --init --recursive
cmake -Bignore/build -DCMAKE_BUILD_TYPE=Release
cmake --build ignore/build --parallel 4 --config Release
```

Confirm it builds clean BEFORE writing the new module. Meanwhile, read:
- `Source/IAudioProcessor.h` / `.cpp` — base class of every audio module.
- `Source/ModuleContainer.h` — how the host registers/orchestrates modules.
- `Source/ScriptModule.cpp` / `ScriptModule_PythonInterface.i` — the embedded Python,
  to evaluate Phase 3's option B.
- An existing comparable module in its source tree (ideally `StableAudio3` itself, or
  `SamplePlayer`, as already used) as a real style reference, not an invented one.

### Phase 3 — Port the bridge's lifecycle into a new module

New module: `Source/ModuleACEResonator.cpp/h`, inherits `IAudioProcessor`.

**Option A — subprocess + HTTP (recommended for the first landing, lowest risk):**
- Reuses `ace_bridge_server.py` unmodified.
- Ports *the behavior* (not the code) of `BridgeProcessManager.swift` to C++: model
  discovery, install/download if missing, `/health` polling, `/infer` fired on a
  background thread (never on the audio callback — same pattern validated by ANIRA),
  graceful shutdown via `/shutdown` waiting on in-flight inference, kill-by-port
  fallback. Use `juce::ChildProcess` (Bespoke is JUCE-based) instead of
  `Process`/`URLSession`.
- The result (WAV bytes) is decoded and written into a lock-free ring buffer that
  `Process()` drains every audio callback — this is the real reimplementation of
  `S(i+1) = ACE(S(i)+N(mu,sigma), P, gamma)` as a Bespoke node.
- Minimal Bespoke-style UI: prompt field, mu/sigma/gamma knobs, trigger button.

**Option B — native embedded Python (explore later, doesn't block v1):**
- Use the existing `ScriptModule` to call ACE-Step in-process, no Flask, no subprocess.
- Real risk: Bespoke's embedded interpreter has its own bundled Python
  (`bundle-python.cmake`) — installing torch + ACE-Step's deps there could conflict with
  what's already working in `.venv-ace-bridge/`. Evaluated as v2 once option A is
  working end to end in our fork.

### Phase 4 — Validate against the old behavior, not the old code

- Re-read the 21 production TODOs in `ParameterRouterController.swift` /
  `AudioPipelineValidator.swift` / `NeuralEngine.swift` as a checklist: confirm which no
  longer apply (Bespoke's own graph/mixer natively handles them) and which, if any,
  remain the new module's responsibility.
- Regression gate: `test_bridge.py` stays at 9/9, unmodified.
- Manual smoke test: launch Bespoke, add the new module, fire `/infer`, confirm clean
  subprocess start/stop with no orphaned processes — the same verification bar already
  used for the Swift `.app`.

### Phase 5 — Our own fork/release, no PR to anyone

- Run `clang-format` (the repo's own `.clang-format`) — good code hygiene, not a
  requirement for external approval.
- Maintain the Bespoke Synth fork with `ModuleACEResonator` added as the build we use
  and distribute ourselves. Clearly document in that fork's README that model weights
  are NOT bundled (they're local, not committed) — same criterion already used for the
  Swift repo.
- If sharing the module with the original project ever makes sense, that's a product
  decision to evaluate later — not a step in this plan.

### Phase 6 — Decommission the Swift repo

- Tag the final state (`v2.0-final-native-canvas`) before archiving — history is not
  deleted.
- Drop `stash@{0}` (already confirmed dead in the prior review).
- Retire `LatentResonator.xcodeproj`, the SwiftUI canvas, the custom graph engine, and
  the associated 122 Swift tests.
- Update the root `README.md` to point at our Bespoke Synth fork (with
  `ModuleACEResonator` folded in) as the live project, linking `docs/whitepaper.md` as
  the conceptual foundation.

---

## Risks to watch

- **Bespoke Synth's GPL-3 license**: by using its code as our fork's base, any binary
  we distribute from that fork is subject to GPL-3 — full source code available to
  whoever receives it. This isn't about "asking permission," it's a legal obligation to
  satisfy at release time, not before.
- **Local CPU remains the real ceiling**: migrating hosts doesn't change ACE-Step's
  inference speed on CPU. If per-block latency stays high, the ring-buffer + thread-pool
  pattern absorbs it (audio never blocks), but the live "feel" of the recursive
  resonator depends on getting a GPU at some point — that's independent of the migration
  and isn't solved by it alone.
- **Option B (embedded Python) is the least certain** — don't evaluate it until option A
  is working end to end in our fork.
- **Maintaining a fork means manually pulling in their future changes** (periodic
  rebase/merge against `BespokeSynth/BespokeSynth` upstream if we want their
  improvements) — a long-term maintenance cost that didn't exist with the fully custom
  canvas, in exchange for not having to maintain a real-time audio UI engine ourselves.
