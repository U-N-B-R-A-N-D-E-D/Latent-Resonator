# Recursive Latent Trajectories in Neural Audio Synthesis

**A Study of Stochastic Evolution via Iterative Feedback Loops in Transformer-Based Architectures**

> **Status note.** This paper began as a design essay. Passages describing sonic outcomes are *observations by the authors or hypotheses*, not controlled measurements, and are labelled as such. Section 9 lists the experiments that would turn them into results. The model the implementation loads is **ACE-Step v1 (3.5B)**; earlier drafts said "ACE-Step 1.5", which is not what the bridge runs.

---

## Executive Summary

Contemporary generative audio converges on semantic coherence and commercial fidelity. Models such as ACE-Step are engineered to reproduce structured musical forms: verse-chorus arrangements, melodic continuity, lyrical intelligibility. This report proposes a divergence: using the model not as a composer but as a **non-linear spectral processor**. By establishing a recursive feedback loop, in which the output of one generation is the conditioning input of the next, we aim to expose the latent timbral biases of the network as it degrades its own output.

The approach is grounded in *Musique Concrète*, *Stochastic Synthesis* and *Microsound*. The neural network is framed as a "Black Box Resonator." An experimental protocol uses a mathematically generated "Koenig Seed" (Dirac impulses in a Euclidean rhythm) to probe the model. We *hypothesize* that high-guidance iterative inference turns this sterile input into self-organizing textures, and that the resulting artifacts are functionally analogous to the stochastic artifacts prized by Xenakis and Roads. This is a hypothesis, not a demonstrated result.

The implementation is an **asynchronous** texture generator: one iteration takes tens of seconds on the measured hardware (Section 2.3). It is not a real-time effect.

---

## 1. Introduction: The Neural Network as an Instrument of Erosion

### 1.1 The Teleology of Semantic Audio

Machine learning in audio synthesis has been defined by a pursuit of mimetic accuracy. State-of-the-art music models, including ACE-Step, combine language-model style planning with acoustic rendering. Their objective is typically aligned with human preference: clarity, harmonic consonance, structural predictability. Training and post-training push the model toward a narrow corridor of "acceptable" output, and artifacts are treated as error.

This report proposes an inversion: the "error" is the aesthetic object. By stripping away semantic scaffolding (lyrics, melody, genre) and supplying a raw mathematical impulse, we force the model to rely on its learned priors. The network is treated not as a composer but as a **medium of transformation**, akin to a complex non-linear filter or a resonant chamber.

### 1.2 The Historical Lineage of Recursive Systems

In 1969, Alvin Lucier composed *I Am Sitting in a Room*: speech was recorded, played back into a room and re-recorded repeatedly. The semantic content dissolved, leaving the resonant frequencies of the space. The room acted as a sorting mechanism, amplifying frequencies matching its dimensions and attenuating others.

The Latent Resonator replicates this topology with a diffusion model as the "room." The "speech" is the captured or seed audio. The "resonance" is determined not by walls and air pressure but by the statistical regularities the model learned in training. By analogy with Lucier, we *hypothesize* that repeated passes amplify the model's preferred timbres (often described as metallic, granular or spectral in our informal listening). Whether this is a stable attractor or a transient is exactly what Section 9 sets out to test.

### 1.3 Research Objectives

1. **Establish a theoretical continuum** between neural audio synthesis and the frameworks of Xenakis (stochastic synthesis), Schaeffer (acousmatics), Roads (microsound) and Koenig (algorithmic composition).
2. **Define the protocol**: the Koenig Seed, and the recursive loop.
3. **Classify emergent artifacts** (candidate taxonomy in Section 5, unverified).
4. **Probe latent drift**: test whether recursive feedback exposes stable biases of the model or merely noise (Section 9).

---

## 2. Implementation: The Bespoke Synth Module

The theoretical loop of Section 1 is a batch protocol. The implementation is a custom module, registered as `latentresonator`, inside a fork of Bespoke Synth (an open-source, GPL-3.0 modular synthesizer), plus a Python bridge that runs the model. An earlier standalone Swift/AVAudioEngine application has been retired and is kept only as reference in the repository archive.

### 2.1 Two Clocks

The design separates two time scales.

- **Slow neural layer.** ACE-Step runs in a Python subprocess (the *bridge*), exposed over a local HTTP interface (`/health`, `/infer`, `/shutdown`), bound to `127.0.0.1`. One call takes tens of seconds.
- **Fast DSP layer.** Everything in Bespoke Synth's own node graph (looper, granulator, filters, effects) runs in real time at audio rate.

The module sits between them. It never runs inference on the audio thread or the UI thread.

### 2.2 Module Data Flow

The audio thread continuously fills a rolling snapshot buffer, `S(i)`. A trigger (a UI button or a patch-cable pulse) hands a copy to a dedicated background worker thread, which adds Gaussian noise `N(mu, sigma)`, encodes the audio as WAV and POSTs it to the bridge with the prompt and guidance settings. When the response arrives, the worker publishes the result into a double-buffered output by atomic handoff; the audio thread drains that buffer into a patch cable. The output can be routed to Bespoke's real-time nodes for auditioning and performance, and can be captured again as the next `S(i)`, closing the recursion. The module also launches the bridge subprocess, polls its health and shuts it down gracefully.

### 2.3 Measured Cost

On an Apple Silicon Mac (32 GB, MPS backend, ACE-Step v1 3.5B, 8 steps; machine under heavy load, load average 8-15, so indicative only), the first bridge configuration (float32) took 39-57 s for 3 s of audio, about 14 times slower than real time, with a fixed cost of 20-30 s per call. Timing instrumentation showed that cost sitting in the small conditioning-encode step and the vocoder rather than in diffusion. ACE-Step forces float32 on MPS, which makes the model roughly 14 GB; the stalls are consistent with memory pressure on a shared machine (inferred, not proven). Running the same pipeline in float16 with a start-up warm-up brought a 3 s take to about 1.1 s warm, a 10 s take to about 2.4 s and a 30 s take to about 7-8 s, independently re-measured with a different source signal and three seeds. Float16 output matched float32 at a correlation of 0.88 for the same seed and was quieter; it was not evaluated by ear. Model load takes about 60 s, and the CPU was about 6x slower than MPS in the float32 configuration.

Consequently the loop is faster than real time per take on this hardware but remains an asynchronous generator: it does not run at audio rate, its output has no fixed relationship to the input's waveform, and it is auditioned and played with real-time nodes. Claims of low-latency neural processing made in earlier drafts remain withdrawn.

### 2.4 Output Is Largely Regenerated

At `input_strength` 0.6 the measured waveform correlation between input and output was approximately zero. The model regenerates most of the signal. Any preservation of the input (for example rhythm, Section 5.1) is therefore at the level of coarse structure, if it occurs at all, and is a hypothesis to test rather than a property to assume.

---

## 3. Technical Background: The ACE-Step System

### 3.1 Architecture

ACE-Step is described by its authors as a diffusion-transformer (DiT) music-generation model operating in the latent space of a compressed audio autoencoder, conditioned on text and optional lyrics. Details of the released checkpoints (parameter counts, encoder/decoder, latent dimensionality, training data and its provenance) should be taken from the upstream repository and model card; we have not independently verified them and do not restate specific figures here. Earlier drafts of this paper quoted a hybrid LM planner, "27 million training samples", "<4 GB VRAM" and "2 billion parameters"; these were unverified, mutually inconsistent, or not applicable to the model actually loaded, and have been removed. What the bridge loads is ACE-Step v1 with roughly 3.5B parameters, and it requires about 16 GB of disk for weights.

### 3.2 Exploiting the Architecture

The loop deliberately "misuses" the model.

- **Abstract prompts.** Descriptors such as "ferrofluid texture" or "granular synthesis" carry no standard song structure. We *hypothesize* that this leaves the model less constrained by musical priors.
- **Overdriving guidance.** Classifier-free guidance (CFG) is typically run at modest scales. The experimental setting pushes it substantially higher (values around 15 to 18 in earlier sessions). We *hypothesize* this pushes sampling toward extreme regions of the conditional distribution and produces the "fried" character; this has not been isolated experimentally.

### 3.3 The Recursion as a Feedback System

The recursion

\[
S_{i+1} = \text{ACE}(S_i + \mathcal{N}(\mu, \sigma), \mathbf{P}, \gamma)
\]

has an IIR-like structure: the output at each iteration depends on the previous output through a fixed but nonlinear, learned operator. The analogy is loose. There are no linear filter coefficients; the operator is a stochastic, high-dimensional generative process.

- \( S_i \): audio at iteration \( i \).
- \( \mathcal{N}(\mu, \sigma) \): Gaussian noise added to the input.
- \( \mathbf{P} \): the prompt (conditioning).
- \( \gamma \): in the current module, the bridge's `denoise_strength`, which scales the number of diffusion steps actually run (`round(num_steps * gamma)`). It is not the classifier-free guidance scale. The SDEdit-style "how much of the input is kept" knob is the bridge's separate `input_strength`, which the module does not yet expose.

**SDEdit-style view.** Audio-to-audio generation with partial denoising follows the same idea as SDEdit (Meng et al., 2021, "SDEdit: Guided Image Synthesis and Editing with Stochastic Differential Equations"): noise the input to an intermediate level, then denoise under the new conditioning. The input-strength parameter sets that intermediate level. High strength means more noise and therefore more regeneration, which is consistent with the near-zero waveform correlation measured at 0.6 (Section 2.4). Applied repeatedly, each pass is a partial re-sampling from the model's conditional distribution.

**Model-collapse literature.** Iterating a generative model on its own output is the setting studied in the model-collapse literature. Alemohammad et al. (2023), "Self-Consuming Generative Models Go MAD" (arXiv:2307.01850), report that without fresh real data, successive generations lose quality or diversity (the "Model Autophagy Disorder"). Our setting differs (a single audio stream, no retraining, a text prompt held throughout), so their results do not transfer automatically; they motivate the diversity and contraction measurements in Section 9. Other collapse papers exist that we have not verified and do not cite.

We do not claim drift toward "metallic" textures is a stable attractor. That is hypothesis H1/H3 below.

---

## 4. Methodology: The Neural Feedback Loop Protocol

The protocol has two phases: generating a control signal (the Koenig Seed), then executing the recursive loop.

### 4.1 Phase A: The "Koenig Seed"

The first step is an input that is acoustically neutral yet rhythmically structured: a Euclidean rhythm (Toussaint), which distributes \( k \) pulses maximally evenly over \( n \) steps.

#### 4.1.1 E(5,13)

Five pulses over 13 steps. 13 is prime, avoiding the symmetrical periodicity of 4/4 in the spirit of Xenakis's preference for primes and sieves. Maximal evenness yields `[1,0,0,1,0,1,0,0,1,0,1,0,0]`.

#### 4.1.2 The Dirac Impulse

An ideal Dirac impulse has a flat spectrum: all frequencies at equal energy. Digitally we approximate it with a one-sample spike. The design rationale is that a broadband excitation gives the model the most spectral information to reshape. That is a motivation, not a demonstrated benefit.

#### 4.1.3 Noise tail

A 20 ms tail of Gaussian noise follows each click. Pure digital silence may be treated by diffusion models as near-null data; the tail is intended as something for the denoiser to work with. Whether it matters is untested.

### 4.2 Phase B: The Recursive Injection

#### 4.2.1 Initial texturization

The first pass transforms the dry seed. Illustrative settings from early sessions: input strength 0.60, a prompt such as "granular synthesis, comb filter resonance, metallic decay, non-linear distortion, ferrofluid texture", and a high CFG scale. The prompt is abstract by design, asking for a texture rather than an instrument.

#### 4.2.2 Subsequent passes

The output of iteration \( N \) becomes the input of iteration \( N+1 \). Illustrative choices: a lower input strength (e.g. 0.45), a prompt evolving toward "spectral degradation, digital artifacts, bitcrushing", and a fresh random seed per pass so that the stochastic walk is not locked to a fixed noise realization. These parameters were chosen by ear; they are not tuned or validated.

---

## 5. Candidate Phenomena (Observations and Hypotheses)

The following are informal listening impressions and predictions. None has been measured; Section 9 defines the tests. Given the correlation result in Section 2.4, claims about rhythm surviving iteration in particular are open.

### 5.1 Temporal coherence (hypothesis)

We hypothesize that high-energy transients in the seed create features that the model's conditioning partially latches onto, so that coarse rhythm might persist while timbre transforms. Given near-zero waveform correlation at strength 0.6, this may hold only at the level of onset envelope, or not at all. Test: onset-envelope correlation across iterations.

### 5.2 Timbral entropy (hypothesis)

We expect, by analogy with Lucier, a drift toward higher spectral flatness and denser texture over iterations, with quiet regions filling in as the model reinterprets the noise floor. This predicts rising spectral flatness and a rising noise floor. It is a prediction, not an observation we can cite.

### 5.3 Audio pareidolia (hypothesis)

By analogy with visual DeepDream, a conditional model may "hear" structure in low-level noise and amplify it toward the prompt. This would be a positive-feedback mechanism analogous to Lucier's room resonances. It is one plausible reading of informal listening and not a demonstrated mechanism.

### 5.4 Candidate artifact taxonomy

| Artifact | Acoustic description | Proposed cause (unverified) |
|---|---|---|
| Metallic sheen | High-frequency ringing, robotic resonance | High CFG over-sharpening the spectral envelope; possibly the autoencoder round-trip (H2) |
| Phase smearing | Loss of transient punch, "watery" sound | Lossy latent compression and reconstruction |
| Phantom voices | Garbled, speech-like formants | Vocal content in training data (plausible; not verified) |
| Granular dust | Crackling textures | Incomplete denoising at few steps |

---

## 6. Discussion: From Generator to Processor

### 6.1 The Non-Linear Spectral Processor

Traditional DSP effects follow fixed algorithmic rules. Here the transfer function is semantic: input "click", instruction "make it sound like ferrofluid", output a "liquid click". This is a filter by *concept* rather than by frequency, applied repeatedly. Because the output is largely regenerated (Section 2.4), the more accurate description is a *resampler*: the model re-imagines the signal, and the performer works with the takes. In the instrument, real-time character comes only from Bespoke's DSP nodes downstream.

### 6.2 The Post-Human Composer

The methodology aligns with the cybernetic tradition: as Wiener suggested, machines may be allowed to exhibit their own behaviors. Removing the human hand (via the seed) and the human song structure (via the loop) lets the model "sing" its own song of weights and biases. This is a framing, not a result.

---

## 7. Execution Protocol

### 7.1 Environment

A local Apple Silicon Mac, a Python 3.12 virtual environment for the bridge, and about 16 GB of disk for ACE-Step v1 3.5B weights (never bundled). The bridge loads the model in about 60 s and each call then costs tens of seconds (Section 2.3). Verified only on Apple Silicon macOS.

### 7.2 Guidance

Very high CFG is used deliberately; in conventional use it degrades quality. Here degradation is the object of study. The exact scale that matters is one of the things H1 asks about.

### 7.3 Listening strategy

Listen to the material between pulses; observe whether the noise floor becomes active; note whether apparent tempo drifts. These are prompts for observation, to be backed by the metrics in Section 9.

### 7.4 Operational notes

- The bridge binds to `127.0.0.1` only, with no authentication. Do not expose it.
- The bridge limits base64/WAV payload sizes to reduce denial-of-service risk from oversized input.
- Stopping while inference is in flight should cancel or discard the pending result; the worker must not publish after shutdown.

---

## 8. Conclusion

The Recursive Latent Trajectories project proposes using a text-conditioned diffusion music model as a recursive, non-linear resampler and studying what its own regularities do to a signal over repeated passes. The engineering result so far is modest and measured: an asynchronous module that generates takes at roughly 10x or worse real time on Apple Silicon, whose output is largely regenerated relative to its input. The scientific claims (timbral attractors, rhythmic persistence, the source of metallic character) are hypotheses. We have not shown that we "induce" any particular state; we have built the instrument with which to test for one.

In the words of the project: we do not create music, we organize sound, and allow the machine to reveal its own acoustic unconscious. Whether that reveals something stable is what the next section is for.

---

## 9. Hypotheses and Planned Experiments

**H1: A critical input strength.** There is a value \( s^* \) of the bridge's `input_strength` (possibly dependent on prompt, step count and guidance) separating a *contracting* regime, in which successive iterations converge toward a fixed point or small set, from a *mixing* regime, in which they keep diverging. Test: sweep `input_strength`, and separately \( \gamma \) (the step-count scale) and guidance scale; measure the contraction ratio below across iterations. Note that `input_strength` is the SDEdit noise-level analogue; \( \gamma \) is not.

**H2: The codec round-trip as a fixed lossy filter.** The autoencoder's encode-decode step is itself a deterministic, lossy transform, and repeated application may contribute the metallic character independent of the diffusion model. Control: a *codec-only loop* that repeatedly encodes and decodes audio without running the diffusion model, compared to the full loop under matched conditions.

**H3: Attractor versus chaos.** Run many seeds from the same input and prompt. If trajectories converge to similar textures, that suggests an attractor; if they diverge and stay diverse, chaotic mixing. Test: seed-divergence statistics on the metrics below.

**Per-iteration metrics** (logged for every take):

- spectral centroid
- spectral flatness
- CLAP embedding distance to the source audio
- CLAP embedding distance to the previous iteration
- contraction ratio \( \|S_{i+1} - S_i\| / \|S_i - S_{i-1}\| \), in a chosen feature space (waveform, spectrogram or embedding)

CLAP here refers to contrastive language-audio embedding models; which checkpoint is used will be recorded with each experiment. Onset-envelope correlation to the seed (Section 5.1) is added for rhythm claims.

Until these experiments are run, statements in Sections 5 and 6 should be read as conjecture.

---

## References

[1] Lucier, A. (1969). *I Am Sitting in a Room*. Lovely Music, Ltd.

[2] Xenakis, I. (1971). *Formalized Music: Thought and Mathematics in Composition*. Indiana University Press.

[3] Schaeffer, P. (1966). *Traité des objets musicaux*. Editions du Seuil.

[4] Roads, C. (2001). *Microsound*. MIT Press.

[5] Koenig, G. M. (1970). *Project One / Project Two*. Institute of Sonology, Utrecht.

[6] Toussaint, G. T. (2005). "The Euclidean Algorithm Generates Traditional Musical Rhythms." *Proceedings of BRIDGES*, pp. 47-56.

[7] Wiener, N. (1948). *Cybernetics: Or Control and Communication in the Animal and the Machine*. MIT Press.

[8] ACE-Step Team. (2025). "ACE-Step: A Step Towards Music Generation Foundation Model." *arXiv preprint*. Consult the upstream repository and model card for current, authoritative details and licensing.

[9] Ho, J., Jain, A., & Abbeel, P. (2020). "Denoising Diffusion Probabilistic Models." *NeurIPS 33*, pp. 6840-6851.

[10] Rombach, R., Blattmann, A., Lorenz, D., Esser, P., & Ommer, B. (2022). "High-Resolution Image Synthesis with Latent Diffusion Models." *CVPR 2022*, pp. 10684-10695.

[11] Alemohammad, S., et al. (2023). "Self-Consuming Generative Models Go MAD." arXiv:2307.01850.

[12] Meng, C., et al. (2021). "SDEdit: Guided Image Synthesis and Editing with Stochastic Differential Equations." arXiv:2108.01073. *(Citation details given from memory; verify before relying on them.)*
