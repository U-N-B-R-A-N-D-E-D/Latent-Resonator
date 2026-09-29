# Legacy Swift App: Distilled Learnings

The SwiftUI/AVAudioEngine app (`LatentResonator/`) was abandoned and removed from the tree. This document keeps what is worth porting to the Bespoke Synth module (C++) and the Python bridge. Full source, tests and the original docs remain in git history:

    git show swift-app-final:LatentResonator/<path>
    git ls-tree -r swift-app-final --name-only | grep LatentResonator/

Tag `swift-app-final` is the last commit that contains the app tree and `docs/archive/`. Paths below (for example `LatentResonator/LatentResonator/SpectralProcessor.swift`) are relative to that tag.

Port priority key: **high** = needed for the module to behave as designed; **medium** = clear value, not blocking; **low** = reference only.

---

## 1. Koenig seed (excitation source)

Port priority: **high** (the seed is the protocol's only input; the module needs a seed generator that can feed the loop).

Sources: `KoenigSeedGenerator.swift` (Euclidean algorithm), `SignalGenerator.swift` (streaming render), `Graph/Nodes/SourceNodes.swift` (`KoenigSeedNode`, the graph-node variant), `Scripts/generate_koenig_seed.py` (offline WAV).

### 1.1 Euclidean rhythm E(k,n), Bjorklund pairing form

```
euclid(k, n):
  if k <= 0 or n <= 0 or k > n: return [false] * max(n, 0)
  A = [[1]] * k          # groups
  B = [[0]] * (n - k)    # remainders
  while len(B) > 1:
      t = min(len(A), len(B))
      merged = [A[i] + B[i] for i in range(t)]
      leftA, leftB = A[t:], B[t:]
      A, B = merged, leftA + leftB
  return flatten(A + B)
```

Defaults: k = 5, n = 13 (13 is prime, avoids 4/4 symmetry). UI/preset bounds: k in 1..16, n in 2..32. `KoenigSeedNode` optionally snaps n up to the nearest prime (table of primes up to 113), clamps k to [1, n], and applies a rotation `pattern[rot:] + pattern[:rot]` with `rot = rotation % n`.

Verified by hand against the algorithm: E(5,13) = `1001010010100` (i.e. `[1,0,0,1,0,1,0,0,1,0,1,0,0]`), E(3,8) = `10010010`, E(4,8) = `10101010`, E(4,16) = `1000100010001000`.

### 1.2 Streaming render (SignalGenerator, the path the loop used)

Constants: `sampleRate = 48000`, `seedDurationSeconds = 10.0` (one full cycle of n steps), `noiseTailDurationMs = 20`, `diracAmplitude = 1.0`, `noiseTailAmplitude = 0.01`.

```
cycleLen      = int(10.0 * sr)               # 480000 samples
samplesPerStep= cycleLen // n                # 480000/13 = 36923
tailSamples   = int(0.020 * sr)              # 960
for each output sample, pos = sampleCounter % cycleLen:
    step = min(pos // samplesPerStep, n-1); inStep = pos % samplesPerStep
    if pattern[step]:
        if inStep == 0:                out = +1.0 (both channels)   # Dirac
        elif 0 < inStep < tailSamples: out = gauss(0,1) * 0.01     # nucleation tail
```

Gaussian by Box-Muller: `z = sqrt(-2 ln(max(u1, eps))) * cos(2 pi u2)`; audio-thread PRNG was xoshiro256** seeded through SplitMix64 (`z += 0x9e3779b97f4a7c15`, then the two multiply-xorshift rounds `0xbf58476d1ce4e5b9`, `0x94d049bb133111eb`). Uniform float from the top 24 bits: `float(next() >> 40) * 2^-24`.

If the rhythm parameters change, the cached pattern is regenerated and the position resets to 0.

### 1.3 Seed-as-node variant (KoenigSeedNode)

Tempo-driven instead of fixed 10 s cycle: `stepsPerSecond = clockRate if clockRate > 0 else bpm/60`; `samplesPerStep = sr / stepsPerSecond`. On each step start where the pattern is on and `rand() < eventProbability * nucleationDensity`, emit:

- Impulse phase (`impulseDecay` ms, default 5, clamp 0.1..100): `impulseAmp * exp(-t / (decaySamples * 0.3))`, `impulseAmp` default 0.8 (0..1).
- Tail (`tailDuration` ms, default 20, clamp 0..200): `tailAmp * impulseAmp * gauss * exp(-tailIdx / (tailSamples * tailDecay))`, `tailAmplitude` default 0.3, `tailDecay` default 0.5 (0.01..2).
- Other clamps: `tempo` 1..999 BPM (default 120), `nucleationDensity` 0..3, `eventProbability` 0..1.

Note the two variants disagree on tail level (0.01 absolute vs 0.3 relative to the impulse). The generator variant is what the recorded sessions used. The whitepaper only states "20 ms Gaussian tail"; whether the tail matters is untested (whitepaper section 4.1.3).

### 1.4 Manifesto gate ("listen before you adjust")

The seed does not fire on START. It is emitted only after the performer arms it (`triggerSeed()` toggles; K key / button / MIDI). Until armed, the buffer is zero. Port as an explicit "arm seed" toggle in the module; default off.

### 1.5 Other excitation modes (low)

`ExcitationMode`: koenigSeed, whiteNoise (uniform +-1 * 0.3), sineOsc (amp 0.5, default 110 Hz, range 20..2000), sawOsc/squareOsc (PolyBLEP, pulse width 0.1..0.9, amp 0.5), triangleOsc (amp 0.5, naive piecewise-linear), pulseTrain (density 0.5..100 pulses/s, default 8, each with the 20 ms tail), silence (forces "pure hallucination from latent priors"), audioInput (live ring buffer). PolyBLEP: `if t < dt: n = t/dt; return 2n - n^2 - 1; elif t > 1-dt: n = (t-1)/dt; return n^2 + 2n + 1; else 0`; saw = `2*phase-1 - polyBLEP(phase,dt)`. Bespoke already has oscillators; only silence/noise/pulse-train seeds are worth exposing.

### 1.6 Tests that define correct behavior (`KoenigSeedNodeTests`)

- Cardinality: for random n in 1..64, k in 1..n, output length n and exactly k trues (500 iterations).
- k = 0 gives all false; k = n gives all true; k > n clamps to n pulses.
- Maximal evenness: cyclic gaps between consecutive pulses differ by at most 1 and never exceed ceil(n/k) (300 random cases each).
- Known patterns: E(5,13), E(3,8), E(4,16), E(4,8) as above. The fixture for E(7,16) in that file (`[1,0,1,1,0,1,1,0,1,1,0,1,1,0,1,0]`) contains 10 pulses, not 7, so it contradicts the cardinality property. The algorithm yields `1001010100101010` for E(7,16); trust the property tests, not that literal.
- Rotation by `r` preserves pulse count; rotation by n returns the base pattern.
- Setters clamp: pulses <= steps, steps >= 1, `impulseDecay` 0.1..100, `tailDuration` 0..200, amplitude 0..1, tempo 1..999.
- Speed: mean compute time < 0.1 ms; large n (1000) still valid.

---

## 2. Spectral analysis features and prompt phases

Port priority: **high** (features drive the prompt-evolution logic and the per-take metrics in whitepaper section 9).

Source: `SpectralProcessor.computeSpectralFeatures`, `Graph/Nodes/NeuralNodes.swift` (`PromptEngineNode`), `Config/Constants.swift`.

### 2.1 Feature definitions (computed per STFT frame from magnitudes `m[i]`, i = 1..halfN-1, `halfN = fftSize/2`, DC excluded, `eps = 1e-10`)

```
centroid = (sum(i * m[i]) / sum(m[i])) / halfN          # normalized 0..1, 0=DC, 1=Nyquist
flatness = min( exp(mean(ln(m[i] + eps))) / mean(m[i]), 1 )   # 0 tonal .. 1 noise-like; 0 if mean(m) <= eps
flux     = sqrt( sum( (m[i] - prev_m[i])^2 ) )           # unnormalized, prev frame stored per bin
```

Snapshot record for telemetry: iteration, centroid, flatness, flux, promptPhase, inputStrength, timestamp. Retention: 256 entries (about 85 min at one snapshot per ~20 s cycle). Iteration archive: 16 past buffers.

### 2.2 Flatness-driven 3-phase prompt engine

Thresholds: `spectralPhase2Threshold = 0.35`, `spectralPhase3Threshold = 0.65`.

```
phase = 1 if flat < 0.35; 2 if flat < 0.65; else 3
if flat < t1:            prompt = phase1
elif flat < t2:          w = smoothstep((flat - t1)/(t2 - t1)); blend(phase1, phase2, w)
else:                    w = smoothstep((flat - t2)/(1 - t2));  blend(phase2, phase3, w)
smoothstep(x) = x*x*(3-2x) on clamped x
blend(a, b, w): if w < 0.01 -> a; if w > 0.99 -> b;
                else "{pct_dominant}% {dominant}, {pct_other}% {other}"   # pct = int(100*w) style, dominant first
phase_cv = 0.0 / 0.5 / 1.0 for phase 1/2/3
```

Default phase prompts: P1 "ferrofluid, subharmonic, warm resonance"; P2 "spectral drift, evolving texture"; P3 "granular chaos, noise as structure". Default global prompt: "granular synthesis, comb filter resonance, metallic decay, non-linear distortion, ferrofluid texture". Whitepaper 4.2.2 alternative later-pass prompt: "spectral degradation, digital artifacts, bitcrushing". The percent-weighted text blend is a heuristic; whether ACE-Step honours "70% x, 30% y" is unverified.

Note the older preset-level rule was iteration-based (phase 1 iterations 0-2, phase 2 iterations 3-8, phase 3 from 9). The flatness version replaced it.

### 2.3 Tests

`SpectralProcessorTests` is only a placeholder (`SpectralAnalyzerNodeTests` was not reviewed). The only spectral tests with content are in 3.4 below. When porting, add: flatness of white noise close to 1, of a pure sine close to 0; centroid of a sine at fs/4 close to 0.5; flux 0 on repeated identical frames.

---

## 3. Spectral processing chain (semantic filter)

Port priority: **medium** (Bespoke already has filters/granulator/saturation; the semantic 4-band EQ, the spectral memory and the recursive-drift pieces are the distinctive parts).

Two implementations existed; keep the parameters, drop the structure.

### 3.1 Legacy 13-stage SpectralProcessor (buffer-based, used in the shipping app)

Chain: Hann -> FFT -> semantic 4-band EQ -> [spectral saturation if smoothed CFG > 5] -> spectral noise (if entropy > 0.001) -> spectral memory (if feedback > 0.001) -> granularity (if > 0.01) -> freeze -> features -> IFFT -> overlap-add -> ladder filter -> comb filter -> tunable resonator (if pitch > 0) -> bit crush (if > 0.001) -> waveshaper.

Key constants and formulas:

- FFT 1024 (choices 512/1024/2048), hop = fftSize/2 (50 %), Hann analysis window only. Parameter smoothing one-pole `y += 0.15*(target - y)` for CFG, crush, resonator pitch/decay, feedback, filter cutoff/resonance.
- Semantic EQ: split bins into 4 equal-width bands, multiply by `profile[band]` (gains 0.2..2.0, see section 4).
- Coloured spectral noise: `amp = level^2 * 0.5 + level * 0.1` (0->0, 0.5->0.175, 1->0.6), added as Gaussian to real and imag of every bin except DC, scaled per band by the semantic profile. Entropy UI range 0..100, default 35; drum lane cap 28. Entropy at the time-domain level (FeedbackLoopNode): `noiseScale = entropy * 0.5` added to captured samples before inference.
- Spectral saturation: `gain = (max(cfg,0.1)/10)^1.5`, per band `tanh(|X| * gain * profile[band]) / |X|` applied to the complex bin (phase preserved).
- Spectral memory: `alpha = 0.85 * feedback`; `mem[k] = alpha*mem[k] + (1-alpha)*|X[k]|`; `X[k] *= clamp(1 + feedback*(mem[k]/|X[k]| - 1), 0.1, 4.0)` (DC skipped, guard `|X| > 1e-4`).
- Granularity: zero each non-DC bin with probability `granularity * 0.7` (max 70 %), granularity normalized 0..1.
- Freeze: on first active frame capture magnitudes; while active, `target = 0.92*frozen + 0.08*live`, scale each bin by `target/live`. Release drops the snapshot.
- Ladder filter: 4-pole TPT (Zavalishin). `g = tan(pi * min(fc, 0.49*sr)/sr)`, `G = g/(1+g)`, `k = 4*resonance`, resonance 0..0.95, cutoff 20..20000 (bypass when cutoff >= 19900 and resonance <= 0.01). Per sample: `u = x - k*s3`; each stage `v = G*(in - s); y = v + s; s = y + v`. Outputs: LP = stage4, HP = x - stage4, BP = stage2 - stage4. Flush states below 1e-15; if any state is NaN/Inf reset all four to 0.
- Comb: `combFilterTaps = 5`, base delay 137 samples (prime; presets 137..271 for dark/bright), tap delays `base*(t+1)`, feedback `0.78 * min(cfg/20, 1)`, average of taps, NaN-sanitised write.
- Tunable resonator: delay = `sr / pitchHz` (MIDI 24..96 -> 32.7..2093 Hz), feedback = `min(decay, 0.99)` (decay range 0..0.99, default 0.7), `wet = 0.3 + 0.5*decay`, `dry = 1 - 0.6*wet`.
- Bit crush: `bits = 16 - depth^1.5 * 14`, `y = round(x * 2^bits) / 2^bits`.
- Waveshaper gain `g = (max(cfg,0.1)/10)^1.5`. Modes: clean `tanh(g x)`; tube `s = gx/(1+|gx|); s + 0.1*s*|s|`; transistor `0.8*tanh(2.5 g x)`; diode `gx > 0 ? min(gx, 0.6) : max(1.2*gx, -1)`. Morph crossfades linearly to the next mode in enum order.
- CFG scale UI range 3..20 (default 10 = unity gain under the `^1.5` law); feedback cap `0.999` for every recirculating path (0.99 was found too conservative, 1.0 diverges).

### 3.2 Newer 8-stage SpectralPipeline (RT-safe, sample-block API)

Stages: FFT (frame scaled by 0.5 after forward) -> semantic EQ -> saturation -> noise -> memory -> granularity -> freeze -> IFFT (scale 1/fftSize). Differences from the legacy chain worth knowing:

- EQ gain is `1 + profile[band]` (additive, so 0 = flat) with band edges at 250 / 1000 / 4000 Hz, not equal quarters.
- Saturation blends by amount: `< 0.5` soft `m/(1+drive*m)` mix; `>= 0.5` blend of `m/(1+m)` and `min(m,1)`, phase kept.
- Noise is a crossfade: `X = X*(1-level) + N(0,1)*level`. Memory is a complex-valued leaky average: `X = mem*c + X*(1-c); mem = X`, default c 0.85. Granularity: multiply bin by 0.01 with probability `amount`. Freeze: blend complex bins with the captured snapshot by `blend` (default 0.9).
- Smoothing factor 0.01 per block on saturation/noise/memory/granularity.
- Input history ring holds one hop from the previous block plus the current block; an `overlapTail` of hopSize samples is carried between calls so block boundaries stay continuous. No allocation on the audio path.

### 3.3 COLA bug worth remembering

A synthesis window was applied on the way out in addition to the analysis window. Hann squared does not satisfy constant-overlap-add at 50 % hop; the sum ripples between 0.5 and 1.0 (6 dB), i.e. amplitude modulation at `2*sr/fftSize` Hz baked into all audio even with every stage bypassed. Fix: analysis-only Hann at 50 % hop, no synthesis window. Do not re-add a window without re-deriving the COLA identity. Run periodic-Hann, hop N/2 overlap-add on DC input and check the output is flat.

Another bug: a DFT setup created with length fftSize while the packed real/imag buffers held fftSize/2 samples overflowed the buffers (SIGSEGV). Real-input packing (even -> real, odd -> imag) needs a complex FFT of length N/2.

### 3.4 Tests that define correct behavior

`SpectralChainTests` (pipeline, fft 1024, 48 kHz, neutral settings = profile `[0,0,0,0]`, all amounts 0):

- Exponential sine sweep 20 Hz..20 kHz over 1 s: output length equals input, RMS ratio in (0.9, 1.1), no NaN/Inf.
- Impulse (index 512 of 2048 samples): peak > 0.01 and located in `[fft/4, 3*fft/2]`, i.e. latency up to about fft/2.
- Different saturation amounts produce different output (max diff > 0.001).
- Latency: mean processing time over 100 runs of a 10 ms block < 5 ms (50 % of the block).
- Recursive memory: with memory coefficient 0.5 and two different constant blocks, the second output deviates from the plain input by mean abs > 0.001.

`SpectralPipelineOverlapAddTests`: DC input stays continuous across block boundaries (boundary overlap span < 1e-2 for blocks 2 and 3, mean abs > 1e-3); silence in gives exactly 0 out (accuracy 1e-7); `reset()` clears the overlap tail so the next block starts from 0 (accuracy 1e-7).

`AudioQualityABTests`: compared a legacy path with a graph path on 7 presets, requiring Pearson correlation >= 0.999 on a 10 s (100->10000 Hz sweep * 0.8 + uniform noise +-0.1) signal, and graph time < 2x legacy. It referenced types that no longer exist in the tree (`SpectralProcessorShim`, `LRConstants.useGraphAudioPath`), so it never compiled against the final code. Only the method survives as an idea: correlate two implementations of the same chain; note that any comparison that includes random noise stages needs a fixed seed or those stages disabled.

---

## 4. Semantic profiles (prompt keyword -> 4-band gains)

Port priority: **medium** (cheap to port, gives the "semantic filter" identity; bands `[low, lowMid, highMid, high]`).

Mechanism (`updateProfile`): lower-case the prompt; for every keyword contained as a substring, accumulate its gains; divide by the number of matches; if none match use the fallback (default `[1,1,1,1]`). Substring matching means "percussion" also matches "percuss" and "303"/"tb303" double-count; keep or fix deliberately.

| keyword | gains | keyword | gains |
|---|---|---|---|
| metallic | 0.3 0.5 1.8 2.0 | bass | 1.9 1.3 0.6 0.3 |
| granular | 1.0 1.2 1.2 1.0 | sub | 2.0 1.0 0.4 0.2 |
| ferrofluid | 1.5 0.8 1.5 1.8 | fundamental | 1.8 1.0 0.5 0.3 |
| distortion | 1.2 1.5 1.5 1.2 | sine | 1.5 0.8 0.5 0.3 |
| decay | 0.5 0.8 1.0 1.5 | low | 1.7 1.2 0.7 0.4 |
| spectral | 0.8 1.0 1.5 1.8 | high | 0.4 0.6 1.4 1.8 |
| degradation | 1.5 1.0 0.8 0.5 | bright | 0.5 0.8 1.5 1.8 |
| bitcrushing | 1.0 0.5 2.0 0.5 | dark | 1.6 1.2 0.7 0.4 |
| noise, synthesis, formless | 1 1 1 1 | air | 0.3 0.5 1.2 2.0 |
| resonance | 0.5 2.0 2.0 0.5 | shimmer | 0.4 0.6 1.5 2.0 |
| texture | 1.0 1.0 1.3 1.0 | breath | 0.5 0.7 1.3 1.7 |
| entropy | 1.2 0.8 0.8 1.2 | hiss | 0.3 0.5 1.5 2.0 |
| saturation | 1.5 1.5 0.8 0.5 | rumble | 2.0 1.3 0.5 0.2 |
| static | 0.5 0.5 1.5 1.5 | body | 1.4 1.5 0.9 0.5 |
| analog | 1.6 1.3 0.9 0.6 | punch | 1.4 1.3 1.2 0.9 |
| vintage | 1.5 1.2 0.9 0.5 | crack | 0.6 1.4 1.8 1.2 |
| warm | 1.4 1.3 1.0 0.7 | pluck | 0.7 1.3 1.6 1.1 |
| fat | 1.8 1.4 0.8 0.5 | pad | 1.2 1.3 1.2 0.9 |
| acid | 0.8 1.8 1.5 0.7 | lush | 1.3 1.4 1.1 0.8 |
| squelchy | 0.7 1.9 1.6 0.6 | vocal | 0.6 1.6 1.6 0.7 |
| buchla | 0.9 1.1 1.5 1.3 | cutting | 0.5 1.0 1.8 1.3 |
| west coast | 0.8 1.0 1.4 1.4 | lead | 0.6 1.3 1.7 1.2 |
| moog | 1.8 1.4 0.8 0.4 | drone | 1.5 1.4 1.0 0.6 |
| minimoog | 1.9 1.5 0.7 0.3 | reverb | 0.9 1.1 1.3 1.3 |
| arp | 0.7 1.2 1.5 1.4 | percuss | 1.2 1.5 1.3 0.8 |
| sequential | 0.8 1.1 1.4 1.3 | percussion | 1.2 1.1 1.4 1.5 |
| roland | 1.2 1.2 1.1 0.9 | transient | 0.8 1.3 1.5 1.2 |
| juno | 1.3 1.2 1.1 0.8 | kick | 2.0 1.2 0.5 0.2 |
| jupiter | 1.4 1.3 1.0 0.8 | snare | 0.8 1.5 1.5 0.9 |
| tb303, 303 | 0.9 1.7 1.4 0.6 | hat | 0.3 0.5 1.5 2.0 |
| tape | 1.3 1.1 0.9 0.5 | cymbal | 0.3 0.6 1.6 1.8 |
| cassette | 1.2 1.0 0.8 0.4 | 808 | 1.6 1.3 1.0 0.7 |
| transistor | 1.1 1.4 1.3 0.8 | industrial | 1.0 1.5 1.5 1.0 |
| tube, valve | 1.3 1.3 1.0 0.6 | mechanical | 0.8 1.4 1.6 0.9 |
| glass | 0.4 0.7 1.5 1.8 | dust | 0.9 1.0 1.3 1.4 |
| erosion | 1.2 0.9 1.1 1.3 | dissolution | 1.1 0.8 0.9 1.4 |
| blur | 1.2 1.2 1.0 0.8 | infrasonic | 2.0 0.8 0.3 0.1 |
| filter | 0.6 1.8 1.5 0.6 | sweep | 0.7 1.5 1.5 0.8 |
| pwm | 0.8 1.3 1.5 1.0 | | |

Drum-voice prompts (per-step prompt override, "prompt = sample"): kick "808 kick drum, sine pitch drop, sub bass punch, short decay, NO reverb"; snare "808 snare, crack, body, short decay, NO reverb tail"; hat "808 closed hi-hat, metallic tick, short decay, NO reverb"; cymbal "808 ride cymbal, metallic decay, short, NO long tail"; mixed "808 drum machine, kick snare hats, punchy, short decay". Lesson: put explicit "NO ..." exclusions in prompts to carve frequency slots and keep drums from turning into pads.

### 4.1 Factory lane presets (recipes that worked as starting points)

Slot map (layer carving to avoid one blurred "reverberant landscape"): sub 20-120 Hz, acid 120-350, drum 350-500, perc 500-2k, lead 800-5k, pad 400-6k, noise 2.5k+.

| preset | prompt gist | CFG | shift | infer | steps | input strength | entropy | feedback | seed source | auto-decay target / iters |
|---|---|---|---|---|---|---|---|---|---|---|
| FERROFLUID DRONE | sub bass only, fundamental, NO highs | 10 | 4 | sde | 8 | 0.62 | 12 | 0.50 | saw | 0.50 / 18 |
| ARP LEAD | midrange lead, cutting, vocal, PWM, NO sub NO air | 12 | 5 | ode | 8 | 0.48 | 22 | 0.42 | square | 0.38 / 12 |
| BUCHLA PERC | midrange pluck, metallic, west coast | 13 | 3 | ode | 8 | 0.52 | 28 | 0.38 | Koenig | 0.38 / 10 |
| ROLAND PAD | high shimmer, air, lush pad, NO bass | 10 | 6 | sde | 8 | 0.55 | 18 | 0.58 | triangle | 0.48 / 22 |
| SPECTRAL TIDE | acid bass, squelchy 303, low-mid, NO air | 14 | 4 | ode | 8 | 0.50 | 18 | 0.48 | saw | 0.35 / 10 |
| NOISE SCAPE | high-frequency hiss, air, breath, NO body | 16 | 9 | sde | 8 | 0.32 | 58 | 0.72 | silence | 0.15 / 14 |
| DRUM LANE | percussion transient, punch, 808, NO long tail | 13 | 4 | ode | 8 | 0.65 | 10 | 0.22 | Koenig | 0.38 / 11 |

Per-lane 3-phase prompt trajectory example (FERROFLUID DRONE): "sub bass only, fundamental, sine-like, fat low end, NO highs" -> "sub harmonics, saturated bass, moog filter, NO midrange" -> "infrasonic dissolution, sub rumble, low frequency entropy". NOISE SCAPE: "high frequency hiss, air, breath, NO body" -> "static dissolution, spectral erosion, formless hiss" -> "white noise saturation, total spectral mass, heat death". Fixed comb base delay per preset from 137 up to 271.

---

## 5. Prompt bank and Markov sequencer

Port priority: **low** for the bank (a string map), **medium** for the Markov sequencer (small, useful to vary prompts between takes).

### 5.1 PromptBankNode

Dot-notation keys (must start with "."), active key default `.kick`, recents list capped at 10 (move to front on use), cannot delete the active key or the last key, importing a bank re-selects the alphabetically first key if the active one vanished. `active_cv` = index of active key in sorted keys / max(count-1, 1). Factory bank (key: text): `.kick` sub-bass pulse, metallic decay, 60Hz resonance; `.snare` noise burst, spectral snap, transient attack; `.hat` high-pass noise, metallic shimmer, 8kHz peak; `.tom` tuned resonance, wooden timbre, pitch decay; `.crash` broadband noise, chaotic spectrum, long decay; `.ride` bell-like overtones, sustained ring, metallic; `.pad_warm` analog chorus, spectral drift, warm saturation; `.pad_cold` digital shimmer, ice crystal texture, high-pass; `.pad_evolving` recursive feedback, spectral memory, slow drift; `.bass_moog` ladder filter sweep, resonance buildup, sub-bass; `.bass_acid` 303 squelch, resonance peak, filter modulation; `.bass_sub` pure sine, sub-harmonic generation, 40Hz; `.drone_metal` harmonic saturation, comb filter metallic, sustained; `.texture_granular` microsound windows, grain cloud, temporal smearing; `.texture_ferrofluid` liquid metal, viscous motion, magnetic pull; `.chaos_low` controlled drift, slight hallucination, 60% coherence; `.chaos_high` deep saturation, recursive hallucination, 10% coherence; `.chaos_pure` silence input, pure latent prior, model unconscious. Per-lane curation: drum lanes see only percussion keys.

### 5.2 MarkovSequencerNode (first-order, Xenakis lineage)

- State count 2..16, row-stochastic N x N matrix, per-state output value `i/(N-1)` (0..1), optional per-state text label used as a prompt output.
- Matrix factories: uniform `1/N`; cyclic `P[i][(i+1)%N] = 1`; self-loop `P[i][i] = stay (0.85)`, others `(1-stay)/(N-1)`. Editing one transition clamps to 0..1 and renormalizes the row.
- Clock: rising edge advances; debounce 10 ms; gate output high for 50 ms after a transition; reset input returns to state 0.
- Temperature `T_eff = temperature * tempCV`: `T < 1`: `p_i^(1/T)` normalized (sharpen); `T > 1`: `p_i^T` normalized (as written; this actually sharpens for T > 1 as well, so the "more random" claim was wrong: a correct flatten is `p_i^(1/T)` for T > 1). `T = 0` or 1 leaves probabilities unchanged.
- RNG xorshift (12/25/27); pick by cumulative sum; the last index is the fallback.
- Flatness-driven temperature was the intended cybernetic coupling (spectral flatness -> temperature).
- Test (`MarkovSequencerNodeTests`): with matrix `[[0,1],[0,1]]` a clock low->high edge moves state 0 -> 1, `value_out` = 1.0, `gate_out` = 1.0 shortly after; `value_out` routed to `frequency_cv` of a 100 Hz oscillator gives `100 + 1.0 * 400 = 500 Hz` (control-rate frequency CV depth 400 Hz).

### 5.3 Step sequencer, pattern chain (low)

Step sequencer: 16 steps, chain length 1..16, trig types note/lock/one-shot/skip, per-step probability 0..1, parameter locks for cfg/feedback/texture/chaos on four outputs, gate pulse 50 ms, advance either per feedback-loop iteration (with a divisor) or by time (30..300 BPM, default 120). One-shot memory clears on pattern wrap. Pattern chain: list of `(sceneID, crossfadeBars >= 1, holdBars >= 1)`, 4 beats per bar, `secondsPerBar = 240 / bpm`, loops or stops at the end; crossfade begins when a step is entered. Scene crossfade max 10 s, default 2 s, 8 scenes.

---

## 6. Recursion parameters that worked

Port priority: **high** (these are the defaults to seed the module UI and the bridge calls).

- Recursion: `S(i+1) = ACE(S(i) + N(mu, sigma), P, gamma)`. The module snapshot buffer is about 1 s (48000 samples) in the app; the capture/feedback rings held 2 s (96000) and the shared audio-input ring was 131072 samples (about 2.7 s, power of two). ACE-Step needs seconds of context; a 4096-sample (85 ms) input mismatched a 10 s model window and was replaced.
- Whitepaper 4.2.1 first pass: input strength 0.60, high CFG (15..18 in early sessions), abstract texture prompt. Later passes 4.2.2: input strength lowered to 0.45 (auto-decay from 0.60 to 0.45 over 10 iterations by default; range 1..50 iterations), prompt drifting toward degradation/bitcrushing, a fresh random seed per pass. These were chosen by ear, not validated.
- CFG used in the app UI: range 3..20, default 10; 15..18 is the "saturation" zone. 8 diffusion steps default (range 4..100), "shift" 1..10 default 5 (low = structure, high = texture), infer method `ode` (deterministic) vs `sde` (stochastic; used for drone/pad/noise lanes), task type `cover`, `thinking = false` (bypass the LM planner).
- Nucleation noise: additive Gaussian on the input, `sigma = entropy * 0.5` (entropy normalized; app default 0.25 in the fallback snapshot; UI default 35/100 for the DSP path). 20 ms noise tail on seeds.
- Bridge request body fields: audio (base64 WAV, float32 mono, 48 kHz), prompt, guidance_scale, num_steps, seed, input_strength, entropy, granularity, task_type, thinking, shift, infer_method, audio_duration, denoise_strength. `denoise_strength` scales steps actually run (`round(num_steps * gamma)`); `input_strength` is the SDEdit-style noise level. They are different knobs; the whitepaper section 3.3 is the corrected statement.
- Measured cost (whitepaper 2.3): CPU 45..95 s per diffusion step; float32 on MPS 39-57 s for 3 s of audio; float16 with warm-up about 1.1 s for a 3 s take. Health timeout 15 s (health can queue behind an infer), inference timeout 300 s.
- Arrival crossfade for results: when a new inference result lands, linear crossfade dry -> neural over about 80 ms (`max(64, 0.08*sr)` samples) and back to dry at the tail. A hard cut clicks. Neural gain `min(feedback, 0.999)`, NaN/Inf samples replaced by 0.
- Circuit breaker: skip inference after 3 consecutive failures, but do not count "bridge unreachable" as a failure (or a routine bridge restart would disable the node for the session). The app-level constants were 5 consecutive failures and a 10 s backoff. Only one inference in flight at a time, guarded by a try-lock so the audio thread never blocks.
- Auto-restore of a silent source: if a source amplitude < 0.01 at START, lift it once to 0.5 (never mid-performance).

---

## 7. Bridge process lifecycle (behavior spec)

Port priority: **high** (the module launches and supervises the Python bridge; these rules cost days to discover). Source: `BridgeProcessManager.swift`, `ACEStepBridge.swift`, `Constants.swift`.

### 7.1 States

`idle -> venv setup -> installing -> launching -> running -> stopping -> idle`, with `error` reachable from any launching step. Launch is a no-op unless `idle` or `error`. The setup work runs on a background queue; state and log updates are marshalled to the UI thread. The client status enum: disconnected, connecting, connected, model loaded, error, recovering.

### 7.2 Launch sequence

1. Verify the server script exists, else error.
2. If the venv interpreter is missing: create the venv in a user-writable location (Application Support; the app bundle may be read-only), pick a system Python 3.9..3.12 (ACE-Step deps need `< 3.13`; candidates in order: Homebrew 3.12, Homebrew 3.11, `/usr/local/bin/python3`, `/usr/bin/python3`, generic Homebrew `python3`, then `which python3`), each verified by printing `major.minor`. Upgrade pip, `pip install -r requirements_bridge.txt`; on failure fall back to `flask numpy`; on failure of that, error.
3. Whether the venv existed or not: verify the ACE-Step package by importing both `acestep` and `acestep.pipeline_ace_step.ACEStepPipeline`. If the package imports but the pipeline does not, install requirements again and retest. If absent, clone `https://github.com/ace-step/ACE-Step` next to the project (or `git pull` if present), `pip install -e <repo> --no-deps` first (avoid version conflicts) then the requirements file (single source of truth for dependencies). Failure to clone leaves the server in passthrough mode.
4. Model discovery: ordered search, first directory that contains a non-empty subdirectory wins: (a) user-configured path, rejected if it contains `..` or lies outside home, `/tmp` or the project root; (b) default user-visible models directory; (c) Application Support `Models/`; (d) `<project>/models/`. If none, download from Hugging Face with `snapshot_download` (about 7 GB for the older model, the current v1 3.5B needs about 16 GB) with a `DOWNLOAD_COMPLETE` sentinel in stdout; on failure run in passthrough mode.
5. Reuse: if `/health` already answers 200 within 2 s, mark running and reuse it (a healthy bridge already survived model load; killing it to relaunch on CPU throws away a proven session).
6. Otherwise start the child: `python ace_bridge_server.py --host 127.0.0.1 --port 8976 [--model-path P] --device {cpu|auto} <profile flags>`; cwd = scripts dir; env `VIRTUAL_ENV`, `PATH=venv/bin:...`, `PYTHONUNBUFFERED=1`, `PYTORCH_ENABLE_MPS_FALLBACK=1`, `PYTORCH_MPS_HIGH_WATERMARK_RATIO=0.0` (the last one fixed "MPS backend out of memory" on ACE-Step 1.5), and a force-CPU env var when CPU is forced. The app was started from Xcode, where `PATH` lacked the user's Python; fix was to build PATH explicitly (see lessons).
7. Health poll with exponential backoff: first probe after 8 s, doubling to a 16 s cap, per-probe timeout 2 s, overall budget 120 s, abort early if the child died ("process exited before ready"). Steady-state polling every 30 s once up. Model load in practice is 10-20 s (about 60 s for v1 3.5B).

### 7.3 Profiles

ULTRA: `--performance-mode --max-steps 4 --quantization q8`; BALANCED (default): `--performance-mode --max-steps 8 --quantization q8`; STUDIO: `--max-steps 20 --quantization fp16`. Profile switching is disabled while running; a switch restarts the bridge (terminate, wait 0.5 s, launch).

### 7.4 Crash handling and MPS latch

On unexpected exit: if the state was `stopping` it is a normal stop. Otherwise set error; if the device was `auto`/MPS, latch "force CPU" for the rest of the session and attempt exactly one automatic relaunch after 1 s on CPU; a second failure stays in error (no relaunch loops). A crash on CPU is a plain error. The latch is never auto-cleared.

### 7.5 Graceful shutdown

1. If an `/infer` is in flight, wait up to 5 s (polling every 0.2 s) so a working inference is not destroyed (killing it mid-request surfaces as a "network connection lost" error on the client).
2. Set state to stopping; `POST /shutdown` (timeout 2 s, wait <= 1.5 s); if still alive send SIGTERM; wait up to 2 s (poll 0.15 s); if still alive SIGKILL and wait 0.3 s.
3. Belt and braces: `lsof -ti :8976` and kill every PID except self (SIGTERM, 0.5 s, SIGKILL). This also stops a reused, externally started bridge.
4. Also run on object teardown. Never let the bridge outlive the host.

### 7.6 Log noise filtering

Both stdout and stderr of the child are captured line by line (Flask logs to stderr). Drop any line (case-insensitive) containing: `nw_socket_handle_socket_event`, `nw_protocol_socket_set_no_wake_from_sleep`, `nw_endpoint_flow_failed_with_error`, `nw_socket_connect`, `nw_connection_`, `nw_protocol_`, `nw_endpoint_`, `nw_path_`, `so_nowakefromsleep`, `setsockopt so_`. These are the OS network stack's loopback teardown messages and buried real bridge status. Keep bounded in-memory logs (setup log 200 lines, trim 50; realtime log 100, trim 20).

### 7.7 Client-visible failure text

Connection-lost / cannot-connect / timed-out errors are shown as "bridge unreachable, reconnecting" rather than the raw OS text (there is no other network involved; the bridge binds loopback only). Truncate other messages to 48 characters for status strips.

---

## 8. Lock-free single-producer/single-consumer ring buffer

Port priority: **high** (the module needs exactly this between the audio thread and the inference worker; in C++ use `std::atomic` with acquire/release instead of a lock). Source: `CircularAudioBuffer.swift`.

Design: capacity rounded up to a power of two (`cap = 1 << ceil(log2(max(capacity, 2)))`, default 131072 samples), `mask = cap - 1`, one slot always left empty (`writable = cap - 1 - ((w - r) & mask)`, `readable = (w - r) & mask`). The producer owns `writePos`, the consumer owns `readPos`, both are free-running integers used with the mask. `write` copies `min(count, writable)` samples then publishes the new write position; `read` copies `min(count, readable)` then publishes the read position. Partial reads/writes return the count actually transferred; nothing blocks. The Swift version guarded the two position words with `os_unfair_lock` for memory ordering (held for a single word, about 1 ns); a C++ port should use `store(release)` / `load(acquire)` on atomics instead and no lock. `reset()` zeroes both positions and must only be called when neither thread is active.

Usage pattern: audio thread writes captured input into `captureBuffer` and reads results from `feedbackBuffer`; the inference task reads `captureBuffer` (one needed-size block, about 1 s) and writes `feedbackBuffer`. When `feedbackBuffer` is empty the output falls back to the dry input; that is the no-model passthrough, not a special case. Inference is started from the audio callback only via a non-blocking try-lock "in flight" flag; it schedules a background job and returns.

Tests: `CircularAudioBufferTests` is a placeholder in the final tree. Port with: wraparound correctness across capacity, a full buffer accepts `cap - 1` samples, read on empty returns 0, concurrent producer/consumer stress with a counting sequence (no loss, no reorder).

---

## 9. WAV codec (bridge transport)

Port priority: **medium** (Bespoke has its own writers, but the bridge contract needs exact bytes). Source: `WAVCodec.swift`.

Encode: mono, IEEE float32 (`audioFormat = 3`, 32 bits, 48000 Hz default), 44-byte header: `RIFF`, `36 + dataSize`, `WAVE`, `fmt ` (16, format, channels, sampleRate, byteRate = sr*ch*4, blockAlign = ch*4, bits), `data`, `dataSize`; all little endian, then raw samples. Decode: require length >= 44, `RIFF`/`WAVE`, walk chunks (`fmt ` then `data`, skipping others by chunk size, no assumption that `data` starts at byte 36), formats supported: float32 (3), PCM16 (divide by 32768), PCM24 (sign-extend, divide by 8388608); multi-channel is averaged to mono; unsupported formats return empty. Read fields byte by byte (chunk boundaries are not aligned) instead of casting pointers. Sent base64 inside JSON; the bridge caps payload size (DoS mitigation).

Tests: `WAVCodecTests` is a placeholder in the final tree. Port with: encode/decode round trip is bit-exact for float32, PCM16 round trip within 1/32768, header bytes match the layout above, truncated input returns empty.

---

## 10. Modulation engine (GRM Atelier-inspired)

Port priority: **low** (Bespoke's own modulation covers this; keep for ideas). Source: `ModulationEngine.swift`, tested by `ModulationEngineTests` (about 60 tests, the only large suite with real assertions).

- Polyadic: each source-to-destination connection owns its phase, RNG state, slew value, envelope stage; the same LFO to four targets yields four independent trajectories. Offsets accumulate additively per destination; graph evaluated about 60 Hz, cached offsets read lock-free from the audio thread (torn float read is inaudible; one-cycle meta-modulation latency about 16 ms).
- Agitation (LFO): rate min 0.001, depth clamp 0..1, waveforms sine `sin(2 pi p)`, triangle `p<0.5 ? 4p-1 : 3-4p`, saw `2p-1`, square (`p < symmetry ? 1 : -1`), sample-and-hold (new value on step boundary, steps per cycle = `4 * rate`, value `r%20001/10000 - 1`), random walk (step `(r%10001/5000 - 1) * dt * rate`, clamped to +-1). Output `raw * depth`; zero rate or zero depth returns 0.
- Control: target `value*2 - 1`; per-connection slew `alpha = min(1, slew * dt * 20)`; `y += alpha * (target - y)`; default slew 0.1.
- Peak envelope: stages idle/attack/hold/decay, defaults attack 0.01 s, hold 0.1 s, decay 0.3 s, minimum times 0.001 s, curve `phase^exponent` (attack) and `(1-phase)^exponent` (decay), trigger probability roll per connection.
- Meta-modulation targets: agitation rate/depth, control value/slew, peak attack/decay; cycle detection must reject self-loops (the shipped `findSourceOwning` always returned nil, so the cycle check was effectively dead; do not copy it).
- RNG: xorshift64* `x ^= x>>12; x ^= x<<25; x ^= x>>27; return x * 0x2545F4914F6CDD1D`.
- Tests cover: waveform quarter-phase values, triangle range and 50 % peak, saw ramp, square symmetry, depth/rate zero, slew convergence, control bipolar mapping, envelope cycle and minimum times, trigger probability 0 never fires, multi-source accumulation, per-parameter isolation, snapshot contents, deterministic sequences from fixed seeds, bounded random walk, JSON round trips, stability at tiny and huge `dt`.

---

## 11. Cross-lane routing and other design notes (from the archived docs)

Port priority: **low**.

- Cross-lane audio reroute without clicks: ramp source volume down over 50 ms, rebuild the audio graph (about 10 ms), ramp up over 40 ms (about 100 ms total). Volume ramps were driven at 60 Hz. Reject routes that create a cycle (DFS from target back to source); cross-lane audio used taps feeding ring buffers (4096-sample tap, about 85 ms) rather than direct engine connections. Failure modes: engine restart fails -> revert topology; tap failure -> direct connection; underrun -> zero fill.
- Control-rate spectral routing: analyzer outputs (centroid, flatness, flux) can drive any control input on any lane; two lanes modulating each other (e.g. centroid -> other lane's filter cutoff, flatness -> other lane's CFG, flux -> noise amount) gives a coupled system. Modulation is additive: `param = base + modulation`; the `_cv` suffix on a port id names the parameter it offsets; frequency CV depth 400 Hz.
- Exposed-control surface: any parameter can be promoted to a performance page; auto-layout by count (<= 4 large knobs 96 pt; <= 8 two rows 74 pt; <= 16 grid of 4 columns 56 pt; above that a scrollable grid grouped by source node). Macro binding: one control drives many parameters with curves linear, `x^2`, log, `1-x`, smoothstep `3x^2 - 2x^3`. Example "MUTATION": CFG 10..20 exponential, filter cutoff 20000..200 inverted, noise 0..100 linear. Macro nesting depth capped at 4.
- Macros texture/chaos/warmth: texture blends spectral noise, granularity and filter resonance; chaos blends entropy, feedback and guidance instability; warmth tilts cutoff low and adds saturation.
- Retired UX direction: one conceptual atom (the recursive loop), named stages instead of generic nodes, factory topologies, a slow restrained UI, a three-mode workflow (config / patch / perform).

---

## 12. Lessons learned

1. **The native canvas lagged.** The custom SwiftUI patch canvas (cables, cards) became the bottleneck; a patching UI is not worth rebuilding when the host (Bespoke Synth) already provides a mature modular canvas. This was the main reason for the migration.
2. **`AudioGraphMapper` was dormant code.** An AVAudioEngine mapper design was abandoned for a pull-render `DSPNode` graph, but tests, docs and comments kept referencing it, and A/B tests referenced types that had been deleted. Dead abstractions kept alive by docs cost more than they earned; delete the loser of a redesign in the same change.
3. **Placeholder nodes and placeholder tests.** Several nodes and test files were empty scaffolds (`testPlaceholder`), giving false confidence: `CircularAudioBufferTests`, `WAVCodecTests`, `SignalGeneratorTests` and `SpectralProcessorTests` contained only `testPlaceholder`. Only the Euclidean rhythm, the overlap-add, the modulation engine and a handful of graph tests were meaningful. Do not count a test file that has no assertion.
4. **SIGTERM orphaned the bridge.** Quitting the host (or a debugger stop) killed the parent without a graceful path, leaving the Python process holding port 8976 and the model in memory. Fixes: HTTP `/shutdown` first, SIGTERM, bounded wait, SIGKILL, then kill-by-port sweep; run the whole path on teardown; reuse of an existing bridge must also be stoppable. Startup must also tolerate an orphan from the previous run (reuse if healthy).
5. **MPS crashes.** A Metal validation abort in `rsub` (`validateComputeFunctionArguments`, "Read-only bytes bound with write access enabled") killed the bridge with exit code 6 (SIGABRT) when a stop landed mid-inference, only under Xcode's debug + Metal API validation, and/or that exact torch build. Standalone runs on MPS worked. Mitigations: default CPU device for a while, a runtime crash latch that forces CPU for the session after any GPU crash, a single auto-relaunch, and memory env vars (`PYTORCH_ENABLE_MPS_FALLBACK=1`, `PYTORCH_MPS_HIGH_WATERMARK_RATIO=0.0`). Later work moved to float16 on MPS with warm-up (see whitepaper 2.3). CPU inference at 45-95 s per step is not viable for performance.
6. **Python not found when launched from the IDE.** GUI-launched processes do not inherit the interactive shell `PATH`; discover Python by absolute candidate paths and version-check them (3.9 <= v < 3.13), and build the child's `PATH` explicitly.
7. **Health checks queue behind inference.** With a single-threaded server, `/health` waited behind `/infer` for tens of seconds and the UI reported "disconnected". A 2 s health timeout was far too short; use 15 s, thread the server, and treat "busy" as alive.
8. **Boot probes too early.** Probing at 1 s intervals produced four noisy failures before the first realistic chance of success; first probe at 8 s, doubling to 16 s.
9. **Circuit-breaker deadlock.** Counting "bridge unreachable" toward the failure limit permanently disabled inference after a routine restart because the counter only reset on success. Only count real inference failures.
10. **Audio-thread rules.** No allocation, no locks that can block, no `await`; pre-allocate every buffer; snapshot parameters into locals at the top of a block (reading a copy-on-write dictionary can allocate); sanitise NaN/Inf; flush denormals; smooth every user-facing parameter (about 50 ms) to prevent zipper noise. Ladder-filter stability came from the TPT form, not the older Huovilainen form.
11. **Overlap-add correctness** (section 3.3): a squared window silently modulated all audio by 6 dB at `2*sr/N` Hz; the DFT-length mismatch caused a buffer overflow. Add a DC and silence test to any STFT code.
12. **Infinite recursion in topology loading.** A macro node built its internal graph by reloading the default topology, which itself contained that macro node: stack overflow before any audio. Use a non-macro scaffold and a re-entrancy guard for any "expand template" path.
13. **Do not over-claim.** Early docs said "real-time neural processing", "ACE-Step 1.5", "27M samples", "<4 GB". Measurements showed an asynchronous generator, model v1 3.5B, about 16 GB weights, output largely regenerated (waveform correlation about 0 at input strength 0.6). The rewritten whitepaper is the reference; hypotheses H1-H3 there are the open science.
14. **Feedback cap.** 0.99 killed the edge; 1.0 diverges; 0.999 with NaN guards works. Any recirculating gain needs a hard ceiling plus a NaN reset.
15. **Manifesto over automation.** Auto-firing the seed on START contradicted the "listen first" design; make seed injection an explicit performer action.
16. **Docs in a second language rotted.** Spanish bodies of several archived docs were stripped during cleanup; keep documentation in one language.

## 13. Where to find full source

- Tag `swift-app-final` holds the last commit containing `LatentResonator/` (Xcode project, app sources, `LatentResonatorTests/`) and `docs/archive/` (`ARCHITECTURE_v2_NODAL.md`, `ARCHITECTURE_v2_RESONANCE_FIELD.md`, `cross_lane_fade.md`, `ROAD_TO_V2_UX.md`, `TECHNICAL_GAP_GUIDE_2026-04-17.md`, `UX_MODE_GUIDE.md`). Example: `git show swift-app-final:LatentResonator/LatentResonator/SpectralProcessor.swift`.
- The active implementation is the Bespoke module and bridge under `bespoke-migration/`; the theory and measurements are in `docs/whitepaper.md`; the migration rationale is in `docs/MIGRATION_BESPOKE_SYNTH_2026-09-11.md`.
- The old `ARCHITECTURE_v2_NODAL.md` (about 50 KB) has a full node catalog (section 3.3), a JS/Swift message protocol (section 7) and an implementation roadmap (section 12); read it from the tag if a graph-node catalog is ever needed. Its lasting ideas are summarized in section 11 above.
