import Foundation
import SwiftUI
#if canImport(ObjectiveC)
import ObjectiveC
#endif

// MARK: - Multi-Lane Template (Whitepaper v2 — Composition Starting Points)
//
// A MultiLaneTemplate is a complete, loadable composition: 2-4 lanes with
// roles assigned, recipes applied, and step grid pre-configured. Solves the
// "blank canvas" problem — users get a working sound immediately.
//
// Templates ship with the app and appear in the "New Composition" dialog.
// Unlike single presets, templates configure the ENTIRE instrument state.

struct MultiLaneTemplate: Identifiable {
    let id = UUID()
    let name: String
    let description: String
    let bpm: Int
    let lanes: [LaneTemplateConfig]
    let stepGridPresets: [StepGridPreset]?  // Optional: pre-programmed patterns

    /// Human-readable summary of what this template provides
    var summary: String {
        let roleList = lanes.map { $0.role.label }.joined(separator: " + ")
        return "\(lanes.count) lanes: \(roleList)"
    }
}

/// Configuration for one lane within a template
struct LaneTemplateConfig {
    let name: String
    let role: LaneRole
    let recipe: PatchRecipe
    let presetOverrides: PresetOverrides?
    let steps: [StepPreset]?  // Optional: pre-configured step pattern
}

/// Parameter overrides from the recipe defaults
struct PresetOverrides {
    let volume: Float?
    let guidanceScale: Float?
    let feedbackAmount: Float?
    let prompt: String?
    // Add others as needed
}

/// Pre-configured step for a lane
struct StepPreset {
    let index: Int
    let trigType: TrigType
    let hasLock: Bool
}

// MARK: - Factory Templates

extension MultiLaneTemplate {

    /// All factory templates available to users
    static let factoryTemplates: [MultiLaneTemplate] = [
        .technoStarter,
        .ambientDrone,
        .rhythmBassGroove,
        .noiseSculpture,
        .neuralHarmony,
    ]

    // MARK: - Template 1: Techno Starter
    // Classic 4/4 techno: kick + bass + hats + pad
    // Pre-configured with E(4,16) kick, sub bass, offbeat hats, evolving pad

    static let technoStarter = MultiLaneTemplate(
        name: "Techno Starter",
        description: "Classic 4/4 techno foundation. Lane 1: punchy kick (Euclidean). Lane 2: rolling sub bass. Lane 3: offbeat hi-hats. Lane 4: evolving pad texture. Turn on DSP and you'll hear a complete track immediately.",
        bpm: 130,
        lanes: [
            LaneTemplateConfig(
                name: "KICK",
                role: .rhythm,
                recipe: .euclideanPercussion,
                presetOverrides: .init(
                    volume: 0.9,
                    guidanceScale: 8.0,
                    feedbackAmount: 0.15,
                    prompt: "punchy 808 kick, sub transient, tight decay, no reverb"
                ),
                steps: [
                    StepPreset(index: 0, trigType: .note, hasLock: false),
                    StepPreset(index: 4, trigType: .note, hasLock: false),
                    StepPreset(index: 8, trigType: .note, hasLock: false),
                    StepPreset(index: 12, trigType: .note, hasLock: false),
                ]
            ),
            LaneTemplateConfig(
                name: "BASS",
                role: .bass,
                recipe: .bassProbe,
                presetOverrides: .init(
                    volume: 0.7,
                    guidanceScale: 6.0,
                    feedbackAmount: 0.35,
                    prompt: "rolling sub bass, warm low end, sine-like, techno"
                ),
                steps: nil
            ),
            LaneTemplateConfig(
                name: "HATS",
                role: .rhythm,
                recipe: .euclideanPercussion,
                presetOverrides: .init(
                    volume: 0.5,
                    guidanceScale: 7.0,
                    feedbackAmount: 0.1,
                    prompt: "closed hi-hat, metallic tick, short decay, offbeat"
                ),
                steps: [
                    StepPreset(index: 2, trigType: .note, hasLock: false),
                    StepPreset(index: 6, trigType: .note, hasLock: false),
                    StepPreset(index: 10, trigType: .note, hasLock: false),
                    StepPreset(index: 14, trigType: .note, hasLock: false),
                ]
            ),
            LaneTemplateConfig(
                name: "PAD",
                role: .harmony,
                recipe: .neuralDrone,
                presetOverrides: .init(
                    volume: 0.4,
                    guidanceScale: 4.0,
                    feedbackAmount: 0.75,
                    prompt: "evolving pad, warm texture, techno atmosphere, spacious"
                ),
                steps: nil
            ),
        ],
        stepGridPresets: nil
    )

    // MARK: - Template 2: Ambient Drone
    // Slow-evolving atmospheric composition: 3 layers of neural drones

    static let ambientDrone = MultiLaneTemplate(
        name: "Ambient Drone",
        description: "Slow-evolving atmospheric space. Three layers of neural drones at different spectral registers. Low CFG allows maximum drift. High feedback creates endless, self-evolving textures. No rhythmic elements — pure texture.",
        bpm: 60,
        lanes: [
            LaneTemplateConfig(
                name: "LOW DRONE",
                role: .texture,
                recipe: .neuralDrone,
                presetOverrides: .init(
                    volume: 0.6,
                    guidanceScale: 2.5,
                    feedbackAmount: 0.9,
                    prompt: "infrasonic drone, sub bass rumble, evolving, cinematic"
                ),
                steps: nil
            ),
            LaneTemplateConfig(
                name: "MID TEXTURE",
                role: .texture,
                recipe: .gestureTexture,
                presetOverrides: .init(
                    volume: 0.5,
                    guidanceScale: 3.0,
                    feedbackAmount: 0.8,
                    prompt: "granular texture, organic movement, acoustic space"
                ),
                steps: nil
            ),
            LaneTemplateConfig(
                name: "HIGH AIR",
                role: .texture,
                recipe: .noiseSculpture,
                presetOverrides: .init(
                    volume: 0.4,
                    guidanceScale: 2.0,
                    feedbackAmount: 0.7,
                    prompt: "high frequency hiss, air, breath, spectral shimmer"
                ),
                steps: nil
            ),
        ],
        stepGridPresets: nil
    )

    // MARK: - Template 3: Rhythm + Bass Groove
    // Minimal but complete: kick pattern + bassline interaction

    static let rhythmBassGroove = MultiLaneTemplate(
        name: "Rhythm + Bass",
        description: "Minimal but complete: just kick and bass, but they interact. The bass uses cross-feedback from the kick lane, creating sidechain-like pumping without compression. Perfect for testing the neural feedback loop architecture.",
        bpm: 125,
        lanes: [
            LaneTemplateConfig(
                name: "KICK",
                role: .rhythm,
                recipe: .euclideanPercussion,
                presetOverrides: .init(
                    volume: 0.95,
                    guidanceScale: 9.0,
                    feedbackAmount: 0.1,
                    prompt: "hard 808 kick, punchy transient, minimal decay"
                ),
                steps: [
                    StepPreset(index: 0, trigType: .note, hasLock: false),
                    StepPreset(index: 3, trigType: .note, hasLock: false),
                    StepPreset(index: 8, trigType: .note, hasLock: false),
                    StepPreset(index: 11, trigType: .note, hasLock: false),
                ]
            ),
            LaneTemplateConfig(
                name: "BASS",
                role: .bass,
                recipe: .bassProbe,
                presetOverrides: .init(
                    volume: 0.75,
                    guidanceScale: 5.0,
                    feedbackAmount: 0.45,
                    prompt: "acid bass, resonant, squelchy, interacting with kick"
                ),
                steps: nil
            ),
        ],
        stepGridPresets: nil
    )

    // MARK: - Template 4: Noise Sculpture
    // Pure granular exploration: noise sources only

    static let noiseSculpture = MultiLaneTemplate(
        name: "Noise Sculpture",
        description: "Pure granular exploration. Two lanes of noise-shaped gestures, one raw noise input. Everything feeds back into everything. The result is an evolving, self-modulating noise sculpture that never repeats.",
        bpm: 90,
        lanes: [
            LaneTemplateConfig(
                name: "NOISE A",
                role: .texture,
                recipe: .noiseSculpture,
                presetOverrides: .init(
                    volume: 0.6,
                    guidanceScale: 2.5,
                    feedbackAmount: 0.85,
                    prompt: "white noise, granular clouds, wind texture"
                ),
                steps: nil
            ),
            LaneTemplateConfig(
                name: "NOISE B",
                role: .texture,
                recipe: .gestureTexture,
                presetOverrides: .init(
                    volume: 0.5,
                    guidanceScale: 3.5,
                    feedbackAmount: 0.75,
                    prompt: "shaped noise, envelope trajectory, organic burst"
                ),
                steps: nil
            ),
            LaneTemplateConfig(
                name: "HALLUCINATION",
                role: .texture,
                recipe: .hallucination,
                presetOverrides: .init(
                    volume: 0.4,
                    guidanceScale: 4.0,
                    feedbackAmount: 0.8,
                    prompt: "pure neural hallucination, no input, latent prior"
                ),
                steps: nil
            ),
        ],
        stepGridPresets: nil
    )

    // MARK: - Template 5: Neural Harmony
    // Chordal exploration with different guidance levels

    static let neuralHarmony = MultiLaneTemplate(
        name: "Neural Harmony",
        description: "Chordal exploration. Three lanes with identical prompts but different CFG levels — low CFG drifts freely, high CFG locks to the harmonic content. The result is a cloud of related but distinct tones that create beating and interaction patterns.",
        bpm: 80,
        lanes: [
            LaneTemplateConfig(
                name: "ROOT",
                role: .harmony,
                recipe: .neuralDrone,
                presetOverrides: .init(
                    volume: 0.6,
                    guidanceScale: 3.0,
                    feedbackAmount: 0.6,
                    prompt: "warm chord, major harmony, sustained tone, electronic"
                ),
                steps: nil
            ),
            LaneTemplateConfig(
                name: "FIFTH",
                role: .harmony,
                recipe: .neuralDrone,
                presetOverrides: .init(
                    volume: 0.5,
                    guidanceScale: 5.0,
                    feedbackAmount: 0.55,
                    prompt: "perfect fifth, harmonic series, sustained electronic tone"
                ),
                steps: nil
            ),
            LaneTemplateConfig(
                name: "EXTENSION",
                role: .harmony,
                recipe: .neuralDrone,
                presetOverrides: .init(
                    volume: 0.4,
                    guidanceScale: 7.0,
                    feedbackAmount: 0.5,
                    prompt: "ninth chord extension, airy harmonic, shimmer"
                ),
                steps: nil
            ),
        ],
        stepGridPresets: nil
    )
}

// MARK: - Template Application

extension NeuralEngine {

    /// Apply a complete multi-lane template, replacing current composition
    func applyTemplate(_ template: MultiLaneTemplate) {
        // Stop current processing
        stopProcessing()

        // Clear existing lanes (keep 1, remove others)
        while lanes.count > 1 {
            if let last = lanes.last {
                removeLane(last)
            }
        }

        // Configure first lane or create new ones
        for (index, laneConfig) in template.lanes.enumerated() {
            let lane: ResonatorLane
            if index < lanes.count {
                lane = lanes[index]
            } else {
                lane = createNewLane()
            }

            // Apply recipe configuration
            lane.name = laneConfig.name
            lane.role = laneConfig.role

            // Apply recipe
            laneConfig.recipe.apply(lane)

            // Apply overrides
            if let overrides = laneConfig.presetOverrides {
                if let volume = overrides.volume { lane.volume = volume }
                if let cfg = overrides.guidanceScale { lane.guidanceScale = cfg }
                if let fbk = overrides.feedbackAmount { lane.feedbackAmount = fbk }
                if let prompt = overrides.prompt { lane.promptText = prompt }
            }

            // Configure step grid if provided
            if let steps = laneConfig.steps {
                // Reset all steps first
                for i in 0..<LRConstants.performanceStepCount {
                    let defaultStep = PerformanceStep(trigType: .skip)
                    lane.stepGrid.setStep(defaultStep, at: i)
                }
                // Apply preset steps
                for step in steps {
                    let ps = PerformanceStep(
                        trigType: step.trigType,
                        cfg: step.hasLock ? lane.guidanceScale : nil
                    )
                    lane.stepGrid.setStep(ps, at: step.index)
                }
            }
        }

        // Set BPM
        bpm = template.bpm

        // Reset and prepare
        resetAllLanes()
        updateLaneMixerState()

        print("Applied template: \(template.name)")
    }

    /// Create a new lane with default settings
    @discardableResult
    private func createNewLane() -> ResonatorLane {
        let lane = ResonatorLane(
            name: "Lane \(lanes.count + 1)",
            preset: LanePreset.arpLead
        )
        lanes.append(lane)
        return lane
    }
}

// MARK: - Template Store

enum TemplateStore {

    /// Load all available templates (factory + user)
    static func loadAllTemplates() -> [MultiLaneTemplate] {
        var templates = MultiLaneTemplate.factoryTemplates

        // Add user templates from disk
        templates.append(contentsOf: loadUserTemplates())

        return templates
    }

    /// Load user-created templates
    private static func loadUserTemplates() -> [MultiLaneTemplate] {
        // TODO: Implement when user template creation is added
        return []
    }

    /// Save a user template
    static func saveTemplate(_ template: MultiLaneTemplate) throws {
        // TODO: Implement persistence
    }
}

// MARK: - Lane Role Extension for ResonatorLane

extension ResonatorLane {
    private struct AssociatedKeys {
        static var roleKey: UInt8 = 0
    }

    /// Semantic role for this lane (rhythm, bass, harmony, etc.)
    var role: LaneRole {
        get {
            return objc_getAssociatedObject(self, &AssociatedKeys.roleKey) as? LaneRole ?? .lead
        }
        set {
            objc_setAssociatedObject(self, &AssociatedKeys.roleKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }
}
