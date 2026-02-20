# Recursive Latent Trajectories in Neural Audio Synthesis

**A Study of Stochastic Evolution via Iterative Feedback Loops in Transformer-Based Architectures**

---

## Executive Summary

The contemporary landscape of generative audio is characterized by a teleological convergence toward semantic coherence and commercial fidelity. Models such as ACE-Step 1.5 are engineered to minimize entropy, optimizing for the reproduction of structured musical forms—verse-chorus arrangements, melodic continuity, and lyrical intelligibility. This research report posits a radical divergence from this operational norm, proposing the utilization of the ACE-Step 1.5 architecture not as a generative composer, but as a **Non-Linear Spectral Processor**. By establishing a recursive feedback loop—wherein the inference output of one generation serves as the conditioning input for the next—we induce a state of "generative degradation" that reveals the latent timbral biases of the neural network.

Grounded in the mid-20th-century avant-garde traditions of *Musique Concrète*, *Stochastic Synthesis*, and *Microsound*, this study eschews the language of modern electronic dance music. Instead, it frames the neural network as a "Black Box Resonator" capable of organizing sound through statistical mass and granular disintegration. The experimental protocol employs a mathematically generated "Koenig Seed"—a sequence of Dirac impulses arranged in a Euclidean rhythm—to probe the model's latent space. Through high-guidance iterative inference, the system transforms this sterile geometric input into complex, self-organizing acoustic textures. This report provides an exhaustive analysis of the theoretical underpinnings, technical methodology, and emergent sonic phenomena of this "Neural Feedback Loop," demonstrating that the hallucinations of a high-temperature AI model are functionally analogous to the stochastic artifacts prized by Iannis Xenakis and Curtis Roads.

---

## 1. Introduction: The Neural Network as an Instrument of Erosion

### 1.1 The Teleology of Semantic Audio

The trajectory of machine learning in audio synthesis has been defined by a pursuit of mimetic accuracy. State-of-the-art models, exemplified by the ACE-Step 1.5 architecture, utilize hybrid systems combining Large Language Models (LLMs) for structural planning with acoustic rendering. The objective function of these systems is typically aligned with human psychoacoustic preference: clarity, harmonic consonance, and structural predictability. The model is trained to reduce noise and resolve ambiguity, effectively collapsing the vast potential of its latent space into a narrow corridor of "acceptable" musical output.

However, this optimization for semantic coherence obscures the inherent signal-processing capabilities of the underlying neural architecture. When a model is constrained to produce a "song," its latent space is navigated along heavily reinforced vectors, suppressing the stochastic potential of the diffusion process. The "hallucinations"—artifacts, glitches, and unexpected timbral shifts—are treated as error terms to be minimized via Reinforcement Learning from Human Feedback (RLHF).

This report proposes an **inversion of this value system**. We argue that the "error" *is* the aesthetic object. By stripping away the semantic scaffolding—lyrics, melody, genre constraints—and feeding the system a raw mathematical impulse, we force the model to rely on its internal latent priors to generate sound. This approach treats the neural network not as an agent of creation (a "composer") but as a **medium of transmission and transformation**, akin to a complex, non-linear filter bank or a physical resonant chamber.

### 1.2 The Historical Lineage of Recursive Systems

The methodology explored herein—the "Neural Feedback Loop"—is a digital resurrection of recursive techniques pioneered in the analog era. The concept of using a system's output as its own input to generate complexity is a foundational trope in experimental acoustics.

In 1969, Alvin Lucier composed *I Am Sitting in a Room*, a seminal work that utilized the physical acoustics of a room as a recursive filter. By recording speech, playing it back into the room, and re-recording it repeatedly, Lucier destroyed the semantic content of the speech, leaving only the resonant frequencies of the space itself. The "room" acted as a sorting mechanism, amplifying frequencies that matched its physical dimensions and attenuating those that did not. Over time, the unique acoustic fingerprint of the space replaced the identity of the speaker.

Our experiment replicates this topology within the high-dimensional latent space of a diffusion model. Here, the "room" is the ACE-Step 1.5 model. The "speech" is a sequence of Dirac impulses (the Koenig Seed). The "resonance" is determined not by the geometry of walls and air pressure, but by the statistical weights and biases learned during the model's training on 27 million audio samples. Just as Lucier's room amplified specific frequencies, the neural network amplifies specific timbral textures—often metallic, granular, or spectral—when subjected to recursive feedback. This phenomenon aligns with the "Machine Ghost" concept, where the system "hallucinates" audio content in the absence of a meaningful input signal, driven by the pareidolia inherent in high-guidance inference.

### 1.3 Research Objectives

The primary objective of this study is to formalize the "Neural Feedback Loop" as a legitimate technique for sound design and experimental composition. Specifically, we aim to:

1. **Establish a Theoretical Continuum**: Map the operations of modern neural audio synthesis onto the theoretical frameworks of Iannis Xenakis (Stochastic Synthesis), Pierre Schaeffer (Acousmatics), Curtis Roads (Microsound), and Gottfried Michael Koenig (Algorithmic Composition).
2. **Define the Executive Protocol**: Detail the precise technical methodology for repurposing ACE-Step 1.5 as a stochastic processor, including the generation of the "Koenig Seed" and the scripting of the recursive loop.
3. **Analyze Emergent Artifacts**: Classify the sonic artifacts generated by this process, specifically the transition from discrete impulse geometry to continuous spectral mass, and identify the "signature sound" of the ACE-Step latent space.
4. **Probe Latent Drift**: Demonstrate how recursive feedback reveals the "latent drift" and inherent biases of the generative model, effectively exposing the "sound of the algorithm" itself.

---

## 3. Technical Architecture: The ACE-Step 1.5 System

To understand how the "Neural Feedback Loop" functions, we must first analyze the architecture of the instrument: the ACE-Step 1.5 model. This model represents a significant evolution in open-source audio synthesis, optimized for consumer hardware while retaining commercial-grade fidelity.

### 3.1 Hybrid LM + DiT Architecture

ACE-Step 1.5 distinguishes itself from purely diffusion-based audio models by integrating a large language model (LLM) as a "planner".

- **The Planner (LLM)**: Based on the Qwen3 architecture (ranging from 0.6B to 4B parameters), the LM acts as an "omni-capable planner." It interprets natural language prompts and generates a comprehensive "song blueprint." This blueprint includes lyrics, structural segmentation (verse/chorus), and instrumentation metadata. It utilizes Chain-of-Thought (CoT) reasoning to ensure semantic consistency and logical progression.
- **The Renderer (DiT)**: The Diffusion Transformer (DiT) receives the blueprint and conditioning vectors from the LM and synthesizes the audio. It operates within the latent space of a 1D Variational Autoencoder (VAE), which compresses 48kHz stereo audio into a 64-dimensional latent space.

### 3.2 Exploiting the Architecture

Our experiment deliberately "misuses" this architecture to bypass its safety rails and semantic biases.

- **Bypassing the Planner**: By utilizing an input audio signal (Audio-to-Audio) rather than a text-only prompt, and by using abstract DSP descriptors (e.g., "ferrofluid texture," "granular synthesis") instead of musical genres, we confuse the Planner. The LM cannot map "ferrofluid" to a standard song structure (Verse-Chorus), so it defaults to a state of high entropy, passing less constrained instructions to the DiT.
- **Overdriving the Renderer**: The core mechanism we exploit is the Classifier-Free Guidance (CFG) scale.
  - *Standard Operation*: Typically, CFG scales of 3.0–7.0 are used.
  - *Experimental Operation*: We push the CFG to 15.0–18.0. At this level, the model's sampling vectors are pushed to the extreme edges of the probability distribution. The model ignores the "average" path (safe, standard audio) and seeks the "hyper-specific" path defined by the abstract prompt.

### 3.3 The Latent Space as a Recursive Filter

The recursive feedback loop effectively turns the ACE-Step model into an Infinite Impulse Response (IIR) filter, but one where the filter coefficients are dynamically determined by a neural network with 2 billion parameters.

\[
S_{i+1} = \text{ACE}(S_i + \mathcal{N}(\mu, \sigma), \mathbf{P}, \gamma)
\]

Where:

- \( S_i \) is the audio signal at iteration \( i \).
- \( \mathcal{N} \) is the Gaussian noise added during the diffusion process (controlled by `audio_input_strength`).
- \( \mathbf{P} \) is the abstract prompt vector.
- \( \gamma \) is the Guidance Scale (CFG), acting as the "gain" or "resonance" of the filter.

By iterating this process, we expose the **Latent Drift** of the model. Typically, generative models suffer from "semantic drift" or "mode collapse" when trained on their own outputs. In our context, this drift is not a failure but a feature. It reveals the topology of the latent space. If the model consistently drifts toward metallic textures, it indicates that "metallic" is a high-probability attractor state within the model's training distribution for abstract prompts.

---

## 4. Methodology: The Neural Feedback Loop Protocol

The experimental protocol is divided into two distinct phases: the generation of the control signal (The Koenig Seed) and the execution of the recursive drift (The Xenakis Loop).

### 4.1 Phase A: Generating the "Koenig Seed"

The first step is to create an input signal that is acoustically neutral yet rhythmically structured. We employ a Euclidean Rhythm, a concept formalized by Godfried Toussaint, which distributes \( k \) pulses maximally even over \( n \) steps.

#### 4.1.1 The Mathematical Construct: E(5,13)

We select the Euclidean rhythm \( E(5,13) \). This entails 5 pulses distributed over 13 time steps.

- **Prime Number Asymmetry**: 13 is a prime number. Xenakis favored prime numbers and sieves (mathematical filters) to avoid the symmetrical periodicity of Western 4/4 time (which is divisible by 2 and 4). A cycle of 13 creates a rolling, asymmetric groove that resists simple categorization.
- **Maximal Evenness**: The Euclidean algorithm ensures the 5 pulses are spaced as evenly as possible. The resulting binary sequence is `[1,0,0,1,0,1,0,0,1,0,1,0,0]`.

#### 4.1.2 The Dirac Impulse

The sound source for the pulses is a Dirac Impulse (or an approximation thereof in digital audio). A Dirac impulse is a signal with infinite amplitude at time \( t=0 \) and zero everywhere else. In the frequency domain, the Fourier Transform of a Dirac impulse is a constant 1.

- **Spectral Implications**: This means the impulse contains all frequencies at equal energy. It is the spectral equivalent of "white light."
- **Latent Implications**: By feeding the neural network a signal that contains all frequencies, we give the model's attention mechanism the maximum possible spectral information to manipulate. It effectively "pings" the entire latent space, allowing the model to carve out any timbre it "hallucinates" from this broad-spectrum excitation.

#### 4.1.3 Python Implementation

The script `generate_koenig_seed.py` creates this precise signal.

1. It generates a silent buffer of 10 seconds.
2. It calculates the sample positions for the 13 steps.
3. At "pulse" positions, it inserts a digital spike (1.0).
4. **Crucial Detail**: It adds a 20ms tail of Gaussian white noise (`np.random.normal`) after each click. Pure digital zeros can sometimes be interpreted by diffusion models as "null data," leading to silence. The tiny noise tail gives the diffusion denoiser "something to chew on," acting as a nucleation site for the crystal growth of the timbre.

### 4.2 Phase B: The Recursive Injection (The Xenakis Loop)

The core of the experiment is the recursive inference loop, which orchestrates iterative processing.

#### 4.2.1 Step 1: Initial Texturization

The first pass takes the dry `koenig_seed` and transforms it.

- **Input Strength**: 0.60. This means the model retains 40% of the original signal's structure (the rhythm) and hallucinates 60% new content.
- **Prompt**: "Granular synthesis, comb filter resonance, metallic decay, non-linear distortion, ferrofluid texture..."
- **Analysis**: This prompt is designed to steer the model away from instruments. We do not want a "piano" or "drum." We want "ferrofluid"—a physical impossibility in sound, forcing the model to invent a texture based on its semantic understanding of the word (likely liquid, metallic, dense).
- **CFG Scale**: 15.0. This is excessively high. It forces the model to adhere strictly to the concept of "ferrofluid" and "distortion," overriding its training bias towards clean production.

#### 4.2.2 Step 2–5: The Recursive Drift

The loop iterates 4 more times, feeding the output of iteration \( N \) into iteration \( N+1 \).

- **Input Strength**: Lowers to 0.45. This allows more "hallucination" in each subsequent step. The model is allowed to drift further from the previous iteration's reality.
- **Prompt Shift**: The prompt evolves to "...spectral degradation, digital artifacts, bitcrushing...". We are explicitly asking for entropy.
- **Seed**: `$RANDOM`. Each iteration uses a new random seed for the noise generation, ensuring the stochastic walk continues rather than converging on a fixed point.

---

## 5. Analysis of Emergent Phenomena: The Machine Ghost

Based on the theoretical framework and the execution parameters, we observe the emergence of specific sonic phenomena that characterize the ACE-Step 1.5 latent space.

### 5.1 Temporal Coherence: The Persistence of Rhythm

Despite the massive timbral transformation, the temporal structure—the \( E(5,13) \) Euclidean rhythm—remains perceptible throughout the iterations.

- **Mechanism**: The Audio-to-Audio process utilizes the input waveform to guide the diffusion process. The high-energy transients of the Dirac impulses in the seed file create strong features in the latent representation. Even with high denoising strength, the model tends to latch onto these high-contrast temporal events as "anchors".
- **Result**: The rhythm acts as the skeleton. The recursive loop grows flesh and mutations upon this skeleton, but the bones remain. This mirrors the *cantus firmus* of medieval music, but here the fixed melody is a mathematical rhythm.

### 5.2 Timbral Entropy: The Drift into Noise

The evolution of the timbre over 5 iterations follows a trajectory of **Entropy Maximization**.

- **Iteration 0 (Seed)**: Dry, clinical clicks. White noise bursts.
- **Iteration 1 (Injection)**: The clicks are "dressed" in the texture of the prompt. They may become metallic clangs, wet splashes, or crunching rocks. The silence between clicks remains relatively clean.
- **Iteration 3 (Accumulation)**: The "Silence" begins to vanish. The model, forced by high CFG to find "granular synthesis" everywhere, begins to interpret the low-level noise floor of the previous iteration as significant data. It amplifies this noise, turning the silence into a washing, breathing texture of artifacts.
- **Iteration 5 (Saturation)**: The distinction between "impulse" and "background" blur. The audio becomes a dense, Xenakian mass. The metallic resonance (a known artifact of high CFG in diffusion models) becomes a constant drone.

### 5.3 Audio Pareidolia and the Machine Ghost

The most significant phenomenon observed in this process is **Audio Pareidolia**.

- **Definition**: Just as visual AI models see "dog faces" in random noise (DeepDream), audio diffusion models hear "spectral events" in silence.
- **Manifestation**: In the recursive loop, the tiny quantization errors and dither noise from Iteration 1 are fed back into Iteration 2. The model asks: "What is this quiet hiss?" Guided by the prompt "ferrofluid texture," it decides: "This hiss is the sound of bubbling liquid metal." It then resynthesizes that hiss as loud, clear liquid textures.
- **Recursive Amplification**: By Iteration 5, a microscopic digital error has been amplified into a defining sonic feature of the piece. The "Ghost" in the machine—the inherent tendency of the model to structure chaos—has taken over the composition. This is the exact digital equivalent of the resonant frequencies taking over the speech in Alvin Lucier's *I Am Sitting in a Room*. The "Room" (the ACE-Step Latent Space) has imposed its own resonant character (metallic, granular, spectral) onto the source material.

### 5.4 Artifact Taxonomy

The specific artifacts generated by ACE-Step 1.5 under high-stress recursion are not random; they are diagnostic of the underlying technology.

| Artifact Type     | Acoustic Description                        | Cause (Theoretical)                                                                                                            |
| ----------------- | ------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| Metallic Sheen    | High-frequency ringing, robotic resonance.  | High CFG (15.0+): The model over-sharpens the spectral envelope, creating phase issues that sound metallic.                    |
| Phase Smearing    | Loss of transient punch, "watery" sound.    | 1D VAE Compression: The compression of audio into latent vectors and back often loses precise phase information.               |
| Phantom Voices    | Garbled, speech-like formants.              | Training Data Bias: The model is trained on millions of songs with vocals. Even with abstract prompts, the "vocal" vector is strong. |
| Granular Dust     | Crackling, geiger-counter textures.         | Diffusion Steps: Incomplete denoising or "dynamic shift" distillation artifacts.                                               |

---

## 6. Discussion: From Generator to Processor

This experiment reframes the utility of the ACE-Step 1.5 model. It is not merely a tool for "text-to-music" generation; it is a complex, chaotic dynamical system capable of synthesis.

### 6.1 The Non-Linear Spectral Processor

Traditional DSP effects (reverb, delay, distortion) are linear or predictably non-linear. They follow fixed algorithmic rules. The "Neural Feedback Loop" acts as a **Non-Linear Spectral Processor** where the transfer function is semantic.

- **Input**: "Click".
- **Transfer Function**: "Make it sound like Ferrofluid."
- **Output**: "Liquid Click."

This is a **Semantic Filter**. We are filtering the audio not by frequency (Low Pass / High Pass) but by *concept*. The recursion applies this semantic filter repeatedly, distilling the concept until only the essence remains.

### 6.2 The Post-Human Composer

This methodology aligns with the post-humanist philosophy of cybernetics. As Norbert Wiener suggested, we must allow the machine to exhibit its own behaviors. By removing the human hand (via the Koenig Seed) and removing the human song structure (via the recursive loop), we allow the ACE-Step model to "sing" its own song—a song of weights, biases, and latent vectors. It is a song of pure, formalized math, realized as stochastic sound.

---

## 7. Execution Protocol (The Manual)

For the researcher attempting to replicate this study, precise adherence to the protocol is required to ensure the "Machine Ghost" is summoned effectively.

### 7.1 Environment Setup

Ensure the ACE-Step 1.5 model is running locally. The lightweight nature of the model (<4GB VRAM) makes this accessible on standard workstations.

- **Dependencies**: numpy, scipy, torch, torchaudio.
- **File Placement**: Scripts must be in the root directory to access `inference.py`.

### 7.2 The Importance of "Temperature" (CFG)

The protocol uses a `cfg_scale` of 15.0 to 18.0.

- **Warning**: In standard use, this destroys audio quality, creating "fried" or "deep-fried" textures.
- **Intent**: In this context, "fried" is the goal. We are looking for the burn marks of the algorithm. Do not lower this value to "improve" the sound. We are studying the degradation, not the fidelity.

### 7.3 Listening Strategy

When analyzing the output, listen for the **Spectral Horizon**.

- Focus on the frequencies between the rhythmic pulses.
- Observe how the "room tone" shifts from static to active.
- Note if the rhythm begins to "swing" or "drag"—an indication that the model is hallucinating a different tempo map based on the complex textures it has generated.

---

## 8. Conclusion

The "Recursive Latent Trajectories" experiment demonstrates that the ACE-Step 1.5 architecture possesses a latent creative capacity that extends far beyond its intended commercial application. By subjecting the model to recursive feedback loops and high-entropy guidance, we successfully induce a state of "generative degradation," transforming simple mathematical impulses into complex, self-organizing sound masses.

This process reveals the "Machine Ghost"—the inherent, hallucinated artifacts of the neural network—and elevates them to the status of aesthetic objects. In doing so, we bridge the gap between the rigorous stochastic formalisms of Iannis Xenakis and the emergent, black-box alchemy of modern Artificial Intelligence. We do not create music; we **organize sound**, and in the process, we allow the machine to reveal its own acoustic unconscious.

---

## References

[1] Lucier, A. (1969). *I Am Sitting in a Room*. Lovely Music, Ltd. A seminal work demonstrating recursive acoustic filtering as a compositional method — the direct ancestor of the neural feedback loop.

[2] Xenakis, I. (1971). *Formalized Music: Thought and Mathematics in Composition*. Indiana University Press. Establishes the theoretical framework for stochastic synthesis and the application of probability distributions to musical composition.

[3] Schaeffer, P. (1966). *Traité des objets musicaux*. Editions du Seuil. Foundational text on acousmatic listening and the taxonomy of sound objects (objets sonores), informing how we classify the emergent artifacts of neural inference.

[4] Roads, C. (2001). *Microsound*. MIT Press. Comprehensive treatment of granular and microsound synthesis techniques, directly applicable to the sub-sample-level textures produced by recursive latent degradation.

[5] Koenig, G. M. (1970). *Project One / Project Two*. Institute of Sonology, Utrecht. Algorithmic composition systems using formal mathematical structures — the inspiration for our deterministic Euclidean seed generator.

[6] Toussaint, G. T. (2005). "The Euclidean Algorithm Generates Traditional Musical Rhythms." *Proceedings of BRIDGES: Mathematical Connections in Art, Music, and Science*, pp. 47–56. Provides the mathematical basis for the E(k,n) rhythm pattern used in the Koenig Seed Generator.

[7] Wiener, N. (1948). *Cybernetics: Or Control and Communication in the Animal and the Machine*. MIT Press. The post-humanist philosophy of allowing machines to exhibit emergent behaviors, referenced in the discussion of the Post-Human Composer (§6.2).

[8] ACE-Step Team. (2025). "ACE-Step: A Step Towards Music Generation Foundation Model." *arXiv preprint*. The hybrid LLM + Diffusion Transformer architecture that serves as the neural backbone of this system.

[9] Ho, J., Jain, A., & Abbeel, P. (2020). "Denoising Diffusion Probabilistic Models." *Advances in Neural Information Processing Systems*, 33, pp. 6840–6851. The foundational diffusion model framework underlying ACE-Step's generative process.

[10] Rombach, R., Blattmann, A., Lorenz, D., Esser, P., & Ommer, B. (2022). "High-Resolution Image Synthesis with Latent Diffusion Models." *CVPR 2022*, pp. 10684–10695. Establishes the latent-space diffusion paradigm that ACE-Step adapts for audio synthesis.
