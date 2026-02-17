import Foundation
import CoreML
import Accelerate

// MARK: - Core ML Inference Pipeline
// Three-model architecture matching the ACE-Step conversion script output:
//
//   [PCM Audio] --> VAE Encoder --> [Latent] --> DiT (x N steps) --> [Latent] --> VAE Decoder --> [PCM Audio]
//
// The latent state from iteration i feeds back into iteration i+1,
// implementing the recursive formula:
//
//   z_{i+1} = α * Encode(S_i) + β * z_i     (latent mix)
//   z~_{i+1} = DiT(z_{i+1}, γ, N steps)      (diffusion)
//   S_{i+1} = Decode(z~_{i+1})                (reconstruction)
//
// Where α = audioInputStrength, β = recursiveInputStrength, γ = CFG guidance scale.
//
// When models are not available, all methods gracefully fall back to passthrough
// so the app remains fully functional with the DSP-only feedback path.

final class CoreMLInference {

    // MARK: - Models

    private var vaeEncoder: MLModel?
    private var dit: MLModel?
    private var vaeDecoder: MLModel?

    /// Legacy single-model fallback for monolithic exports.
    private var monolithicModel: MLModel?

    // MARK: - Latent State (Persists Across Iterations)

    /// The recursive feedback vector. Mixed with fresh encoder output
    /// each cycle to implement latent-space drift.
    private(set) var latentState: MLMultiArray?

    // MARK: - Configuration

    private let config: MLModelConfiguration

    // MARK: - Initialization

    /// Initialize with default configuration (no models loaded yet).
    /// Call `loadModels(...)` or `loadMonolithicModel(...)` afterward.
    init() {
        config = MLModelConfiguration()
        // Prefer Neural Engine -> GPU -> CPU fallback chain
        config.computeUnits = .all
        initializeLatentState()
    }

    /// Legacy initializer -- loads a single monolithic model.
    ///
    /// - Parameter modelURL: Path to a compiled .mlmodelc or .mlpackage
    /// - Throws: If model compilation or loading fails
    convenience init(modelURL: URL) throws {
        self.init()
        try loadMonolithicModel(at: modelURL)
    }

    // MARK: - Model Loading

    /// Load the three ACE-Step pipeline models.
    ///
    /// Any URL may be `nil` if that component is not yet available;
    /// the pipeline will use passthrough for missing stages.
    ///
    /// - Parameters:
    ///   - encoderURL: Path to the VAE Encoder .mlmodelc/.mlpackage
    ///   - ditURL: Path to the Diffusion Transformer .mlmodelc/.mlpackage
    ///   - decoderURL: Path to the VAE Decoder .mlmodelc/.mlpackage
    func loadModels(
        encoderURL: URL? = nil,
        ditURL: URL? = nil,
        decoderURL: URL? = nil
    ) throws {
        if let url = encoderURL {
            let compiled = try MLModel.compileModel(at: url)
            vaeEncoder = try MLModel(contentsOf: compiled, configuration: config)
            print(">> CoreML: VAE Encoder loaded")
        }

        if let url = ditURL {
            let compiled = try MLModel.compileModel(at: url)
            dit = try MLModel(contentsOf: compiled, configuration: config)
            print(">> CoreML: DiT loaded")
        }

        if let url = decoderURL {
            let compiled = try MLModel.compileModel(at: url)
            vaeDecoder = try MLModel(contentsOf: compiled, configuration: config)
            print(">> CoreML: VAE Decoder loaded")
        }

        print(">> CoreML: Pipeline ready -- compute units: all (ANE preferred)")
    }

    /// Load a single monolithic model (legacy fallback).
    ///
    /// - Parameter url: Path to the Core ML model
    func loadMonolithicModel(at url: URL) throws {
        let compiled = try MLModel.compileModel(at: url)
        monolithicModel = try MLModel(contentsOf: compiled, configuration: config)
        print(">> CoreML: Monolithic model loaded -- compute units: all (ANE preferred)")
    }

    /// Whether any Core ML model is loaded and ready for inference.
    var isModelLoaded: Bool {
        monolithicModel != nil || vaeEncoder != nil || dit != nil || vaeDecoder != nil
    }

    // MARK: - Three-Stage Pipeline

    /// Encode PCM audio samples into the VAE latent space.
    ///
    /// - Parameter stereoSamples: Interleaved or mono audio samples
    /// - Returns: Latent representation as MLMultiArray, or `nil` if encoder unavailable
    func encode(stereoSamples: [Float]) -> MLMultiArray? {
        guard let encoder = vaeEncoder else { return nil }

        do {
            let inputArray = try floatsToMultiArray(
                stereoSamples,
                shape: [1, NSNumber(value: LRConstants.vaeInputChannels),
                        NSNumber(value: stereoSamples.count / LRConstants.vaeInputChannels)]
            )

            let features = try MLDictionaryFeatureProvider(dictionary: [
                "audio_input": MLFeatureValue(multiArray: inputArray)
            ])

            let prediction = try encoder.prediction(from: features)

            // Expect output named "latent" -- shape [1, latentDim, seqLen]
            return prediction.featureValue(for: "latent")?.multiArrayValue

        } catch {
            print(">> CoreML Encode: \(error.localizedDescription)")
            return nil
        }
    }

    /// Run N denoising steps through the Diffusion Transformer in latent space.
    ///
    /// The prompt P is passed as a feature when the DiT supports text conditioning.
    /// When the model doesn't accept a "prompt" input, the parameter is silently ignored.
    ///
    /// - Parameters:
    ///   - latent: Input latent tensor from the encoder or previous iteration
    ///   - guidanceScale: CFG value γ controlling hallucination intensity
    ///   - prompt: Semantic prompt P for conceptual filtering (§6.1)
    ///   - steps: Number of denoising iterations (defaults to LRConstants.inferenceSteps)
    /// - Returns: Denoised latent tensor, or the input unchanged if DiT unavailable
    func diffuse(
        latent: MLMultiArray,
        guidanceScale: Float,
        prompt: String = LRConstants.defaultPrompt,
        steps: Int = LRConstants.inferenceSteps
    ) -> MLMultiArray {
        guard let ditModel = dit else { return latent }

        var currentLatent = latent

        do {
            for step in 0..<steps {
                let timestep = Float(steps - step) / Float(steps)

                // Build feature dictionary -- include prompt when DiT accepts it
                var dict: [String: MLFeatureValue] = [
                    "latent_input": MLFeatureValue(multiArray: currentLatent),
                    "guidance_scale": MLFeatureValue(double: Double(guidanceScale)),
                    "timestep": MLFeatureValue(double: Double(timestep))
                ]

                // Provide prompt conditioning vector P (§3.3 formula variable P)
                // If the compiled model doesn't have a "prompt" input, Core ML
                // will ignore it gracefully via try/catch.
                dict["prompt"] = MLFeatureValue(string: prompt)

                let features = try MLDictionaryFeatureProvider(dictionary: dict)
                let prediction = try ditModel.prediction(from: features)

                if let output = prediction.featureValue(for: "latent_output")?.multiArrayValue {
                    currentLatent = output
                }
            }
        } catch {
            print(">> CoreML Diffuse: \(error.localizedDescription)")
        }

        return currentLatent
    }

    /// Decode a latent tensor back into PCM audio samples.
    ///
    /// - Parameter latent: Latent tensor from the diffusion stage
    /// - Returns: Reconstructed audio samples, or empty array if decoder unavailable
    func decode(latent: MLMultiArray) -> [Float] {
        guard let decoder = vaeDecoder else { return [] }

        do {
            let features = try MLDictionaryFeatureProvider(dictionary: [
                "latent_input": MLFeatureValue(multiArray: latent)
            ])

            let prediction = try decoder.prediction(from: features)

            if let outputArray = prediction.featureValue(for: "audio_output")?.multiArrayValue {
                return multiArrayToFloats(outputArray)
            }
        } catch {
            print(">> CoreML Decode: \(error.localizedDescription)")
        }

        return []
    }

    // MARK: - Full Pipeline (Encode -> Mix -> Diffuse -> Decode)

    /// Run the complete three-stage pipeline with latent-space recursive feedback.
    ///
    /// Implements the recursive formula from §3.3:
    ///   z_mix = α * encode(audio) + β * z_prev + ε*N(0,1)
    ///   z_new = diffuse(z_mix, γ, P)
    ///   output = decode(z_new)
    ///
    /// - Parameters:
    ///   - inputSamples: Raw audio from the capture buffer
    ///   - guidanceScale: CFG value γ (higher = more hallucination)
    ///   - entropyLevel: Normalized noise injection ε [0..1]
    ///   - granularity: Grain size control [0..1] (unused in latent pipeline, applied in DSP)
    ///   - inputStrength: α blend for fresh vs recursive signal [0..1]
    ///   - prompt: Semantic prompt P for conceptual filtering (§6.1)
    /// - Returns: Processed audio samples
    func processPipeline(
        inputSamples: [Float],
        guidanceScale: Float,
        entropyLevel: Float,
        granularity: Float,
        inputStrength: Float = LRConstants.inputStrengthDefault,
        prompt: String = LRConstants.defaultPrompt
    ) -> [Float] {
        // Stage 1: Encode audio to latent space
        guard let freshLatent = encode(stereoSamples: inputSamples) else {
            // Encoder not available -- fall back to monolithic or passthrough
            return processMonolithic(
                inputSamples: inputSamples,
                guidanceScale: guidanceScale,
                entropyLevel: entropyLevel,
                granularity: granularity
            )
        }

        // Stage 2: Mix fresh encoding with recursive latent state
        //   α = inputStrength (fresh audio weight)
        //   β = 1.0 - inputStrength (recursive latent weight, §4.2.2)
        let mixedLatent = mixLatentStates(
            fresh: freshLatent,
            recursive: latentState,
            entropyLevel: entropyLevel,
            inputStrength: inputStrength
        )

        // Stage 3: Diffuse (denoise) in latent space with prompt conditioning
        let denoisedLatent = diffuse(
            latent: mixedLatent,
            guidanceScale: guidanceScale,
            prompt: prompt
        )

        // Persist latent state for next iteration (recursive feedback)
        latentState = denoisedLatent

        // Stage 4: Decode back to audio
        let decoded = decode(latent: denoisedLatent)
        return decoded.isEmpty ? inputSamples : decoded
    }

    // MARK: - Monolithic Fallback

    /// Process using a single monolithic model (legacy path).
    func processMonolithic(
        inputSamples: [Float],
        guidanceScale: Float,
        entropyLevel: Float,
        granularity: Float
    ) -> [Float] {
        guard let model = monolithicModel else {
            return inputSamples
        }

        do {
            let inputArray = try floatsToMultiArray(
                inputSamples,
                shape: [1, NSNumber(value: inputSamples.count)]
            )

            // Inject entropy into latent state
            injectEntropy(level: entropyLevel)

            let features = try MLDictionaryFeatureProvider(dictionary: [
                "audio_input": MLFeatureValue(multiArray: inputArray),
                "guidance_scale": MLFeatureValue(double: Double(guidanceScale))
            ])

            let prediction = try model.prediction(from: features)

            if let output = prediction.featureValue(for: "audio_output")?.multiArrayValue {
                let count = min(inputSamples.count, output.count)
                let src = output.dataPointer.bindMemory(to: Float.self, capacity: output.count)
                var result = Array(UnsafeBufferPointer(start: src, count: count))
                if result.count < inputSamples.count {
                    result.append(contentsOf: [Float](repeating: 0, count: inputSamples.count - count))
                }

                // Update latent state for recursive feedback
                if let ls = prediction.featureValue(for: "latent_state")?.multiArrayValue {
                    latentState = ls
                }

                return result
            }

            return inputSamples

        } catch {
            print(">> CoreML Monolithic: \(error.localizedDescription)")
            return inputSamples
        }
    }

    // MARK: - Latent Mixing

    /// Blend fresh encoder output with the recursive latent state.
    ///
    ///   z_mix = α * z_fresh + β * z_prev + ε * N(0,1)
    ///
    /// Where α = inputStrength (fresh audio weight),
    ///       β = 1.0 - inputStrength (recursive latent weight, §4.2.2),
    ///       ε = entropyLevel.
    ///
    /// White paper §4.2.1: α=0.60 initial, §4.2.2: α=0.45 for recursive drift.
    /// Now dynamically controlled by the Input Strength UI knob.
    private func mixLatentStates(
        fresh: MLMultiArray,
        recursive: MLMultiArray?,
        entropyLevel: Float,
        inputStrength: Float
    ) -> MLMultiArray {
        var alpha = inputStrength
        let beta = 1.0 - inputStrength  // Complementary weighting
        let count = fresh.count
        let freshPtr = fresh.dataPointer.bindMemory(to: Float.self, capacity: count)

        // If no recursive state exists yet, return scaled fresh + noise
        guard let prev = recursive, prev.count == count else {
            // Scale: fresh *= alpha (in-place vDSP)
            vDSP_vsmul(freshPtr, 1, &alpha, freshPtr, 1, vDSP_Length(count))
            // Add noise if entropy is above threshold
            if entropyLevel > 0.001 {
                let noiseScale = entropyLevel * 0.1
                for i in 0..<count {
                    freshPtr[i] += SignalGenerator.boxMullerNoise() * noiseScale
                }
            }
            return fresh
        }

        // Blend: result = α * fresh + β * recursive + ε * noise
        // Step 1: fresh *= alpha
        vDSP_vsmul(freshPtr, 1, &alpha, freshPtr, 1, vDSP_Length(count))
        // Step 2: fresh += beta * recursive (vDSP_vsma: scalar multiply + add)
        var betaVar = beta
        let prevPtr = prev.dataPointer.bindMemory(to: Float.self, capacity: count)
        vDSP_vsma(prevPtr, 1, &betaVar, freshPtr, 1, freshPtr, 1, vDSP_Length(count))
        // Step 3: add noise
        if entropyLevel > 0.001 {
            let noiseScale = entropyLevel * 0.1
            for i in 0..<count {
                freshPtr[i] += SignalGenerator.boxMullerNoise() * noiseScale
            }
        }

        return fresh
    }

    /// Inject Gaussian noise into the current latent state.
    private func injectEntropy(level: Float) {
        guard let latent = latentState, level > 0.001 else { return }
        let count = latent.count
        let ptr = latent.dataPointer.bindMemory(to: Float.self, capacity: count)
        let noiseScale = level * 0.1
        for i in 0..<count {
            ptr[i] += SignalGenerator.boxMullerNoise() * noiseScale
        }
    }

    // MARK: - State Management

    /// Reset the latent state vector to zero.
    /// Call when restarting the feedback loop.
    func resetLatentState() {
        initializeLatentState()
    }

    private func initializeLatentState() {
        latentState = try? MLMultiArray(
            shape: [1, NSNumber(value: LRConstants.latentDimensions),
                    NSNumber(value: LRConstants.latentSequenceLength)],
            dataType: .float32
        )
    }

    // MARK: - Helpers

    /// Convert a Float array to MLMultiArray with the given shape.
    private func floatsToMultiArray(_ floats: [Float], shape: [NSNumber]) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: shape, dataType: .float32)
        let count = min(floats.count, array.count)
        let dst = array.dataPointer.bindMemory(to: Float.self, capacity: array.count)
        floats.withUnsafeBufferPointer { src in
            guard let base = src.baseAddress else { return }
            dst.update(from: base, count: count)
        }
        return array
    }

    /// Convert an MLMultiArray to a Float array.
    private func multiArrayToFloats(_ array: MLMultiArray) -> [Float] {
        let count = array.count
        let src = array.dataPointer.bindMemory(to: Float.self, capacity: count)
        return Array(UnsafeBufferPointer(start: src, count: count))
    }

}
