import Foundation
import SwiftUI

// MARK: - Lane Role (Whitepaper v2 — Composition Layer §5.2)
//
// LaneRole provides semantic categorization for lanes, enabling:
// 1. Role pills in the Lane Module header (visual organization)
// 2. Default parameter ranges tuned per role (rhythm = short feedback, harmony = long)
// 3. Scene crossfader morph weights (preserve rhythm continuity during transitions)
// 4. Preset browser filtering by role
// 5. Pattern Chain crossfader intelligence (avoid cutting rhythm during bass/harmony transitions)
//
// LaneRole is NOT behavioral — it's a hint that drives UX and sensible defaults.
// The audio engine treats all lanes identically regardless of role.

enum LaneRole: String, Codable, CaseIterable, Identifiable {
    case rhythm   = "rhythm"    // Percussive, time-keeping, Euclidean patterns
    case bass     = "bass"      // Sub-bass, low-frequency foundation
    case harmony  = "harmony"   // Chords, pads, harmonic content
    case texture  = "texture"   // Noise, drones, atmospheric layers
    case gesture  = "gesture"   // Dynatext-driven, gestural movement
    case lead     = "lead"      // Melodic, midrange, prominent
    case fx       = "fx"        // Effects send, auxiliary processing

    var id: String { rawValue }

    /// Display label for UI (uppercase for the lab aesthetic).
    var label: String {
        switch self {
        case .rhythm:  return "RHYTHM"
        case .bass:    return "BASS"
        case .harmony: return "HARMONY"
        case .texture: return "TEXTURE"
        case .gesture: return "GESTURE"
        case .lead:    return "LEAD"
        case .fx:      return "FX"
        }
    }

    /// Short 1-letter code for compact displays.
    var code: String {
        switch self {
        case .rhythm:  return "R"
        case .bass:    return "B"
        case .harmony: return "H"
        case .texture: return "T"
        case .gesture: return "G"
        case .lead:    return "L"
        case .fx:      return "X"
        }
    }

    /// Accent color for this role (consistent across the UI).
    var color: Color {
        switch self {
        case .rhythm:  return Color.red
        case .bass:    return Color.blue
        case .harmony: return Color.purple
        case .texture: return Color.orange
        case .gesture: return Color.cyan
        case .lead:    return Color.green
        case .fx:      return Color.yellow
        }
    }

    /// Default feedback amount for this role (shorter for rhythm, longer for texture).
    var defaultFeedback: Float {
        switch self {
        case .rhythm:  return 0.15  // Short, punchy
        case .bass:    return 0.30  // Moderate sustain
        case .harmony: return 0.55  // Lush, evolving
        case .texture: return 0.70  // Drone-like
        case .gesture: return 0.45  // Balanced
        case .lead:    return 0.35  // Articulate
        case .fx:      return 0.60  // Washy, ambient
        }
    }

    /// Default delay time for this role (seconds).
    var defaultDelayTime: Float {
        switch self {
        case .rhythm:  return 0.08   // Tight, slapback
        case .bass:    return 0.25   // Room size
        case .harmony: return 0.50   // Spacious
        case .texture: return 0.75   // Atmospheric
        case .gesture: return 0.30   // Moderate
        case .lead:    return 0.20   // Subtle depth
        case .fx:      return 1.00   // Extreme space
        }
    }

    /// Default excitation mode for this role.
    var defaultExcitation: ExcitationMode {
        switch self {
        case .rhythm:  return .koenigSeed      // Euclidean patterns
        case .bass:    return .sawOsc         // Rich harmonics
        case .harmony: return .triangleOsc    // Soft, blendable
        case .texture: return .whiteNoise     // Broadband
        case .gesture: return .dynatextGesture // Envion gestures
        case .lead:    return .squareOsc      // Cutting, vocal
        case .fx:      return .silence        // Process external
        }
    }

    /// Whether this role should maintain continuity during scene crossfades.
    /// Rhythm and bass should NOT be crossfaded abruptly — they anchor the groove.
    var preserveDuringCrossfade: Bool {
        switch self {
        case .rhythm, .bass: return true
        default: return false
        }
    }

    /// Crossfade weight during Pattern Chain transitions.
    /// Roles with higher weight retain their parameters longer during morphs.
    var crossfadeWeight: Float {
        switch self {
        case .rhythm:  return 1.5  // Anchor — hold longest
        case .bass:    return 1.3  // Foundation — hold long
        case .harmony: return 1.0  // Standard
        case .lead:    return 0.9  // Can shift faster
        case .texture: return 0.8  // Atmospheric — shift easily
        case .gesture: return 0.9  // Can follow gesture changes
        case .fx:      return 0.7  // Most flexible
        }
    }

    /// Default prompt template for this role.
    var defaultPrompt: String {
        switch self {
        case .rhythm:
            return "electronic percussion, punchy 808, short decay, NO reverb tail"
        case .bass:
            return "sub bass, deep low end, sine-like fundamental, warm"
        case .harmony:
            return "lush pad, evolving chords, spectral shimmer, no transients"
        case .texture:
            return "granular noise, wind texture, acoustic space, formless"
        case .gesture:
            return "gestural movement, amplitude envelope, organic contour"
        case .lead:
            return "cutting lead, vocal character, PWM, resonant mids"
        case .fx:
            return "stereo effects, wide space, diffused, transformed"
        }
    }

    /// Suggested default recipe for quick setup.
    var suggestedRecipe: PatchRecipe? {
        switch self {
        case .rhythm:  return .euclideanPercussion
        case .bass:    return .bassProbe
        case .harmony: return .neuralDrone
        case .texture: return .noiseSculpture
        case .gesture: return .gestureTexture
        case .lead:    return nil  // Lead is too varied
        case .fx:      return .fieldRecording
        }
    }

    /// Whether this role is suitable for drum P-Locks.
    var supportsDrumLocks: Bool {
        self == .rhythm
    }
}

// MARK: - LaneRole Badge View

struct LaneRoleBadge: View {
    let role: LaneRole
    var isActive: Bool = true

    var body: some View {
        Text(role.label)
            .font(LRConstants.DS.font(LRConstants.DS.fontCaption2, weight: .bold))
            .foregroundColor(isActive ? role.color : LRConstants.DS.textTertiary)
            .padding(.horizontal, LRConstants.DS.spacingSM)
            .padding(.vertical, 2)
            .background(
                isActive
                    ? role.color.opacity(0.12)
                    : LRConstants.DS.panelHollow
            )
            .overlay(
                RoundedRectangle(cornerRadius: LRConstants.DS.radiusSM)
                    .stroke(
                        isActive ? role.color.opacity(0.4) : LRConstants.DS.border,
                        lineWidth: 1
                    )
            )
            .cornerRadius(LRConstants.DS.radiusSM)
    }
}

// MARK: - Lane Role Selector

struct LaneRoleSelector: View {
    @Binding var selectedRole: LaneRole
    var onChange: ((LaneRole) -> Void)? = nil

    var body: some View {
        HStack(spacing: LRConstants.DS.spacingXS) {
            ForEach(LaneRole.allCases) { role in
                Button(action: {
                    selectedRole = role
                    onChange?(role)
                }) {
                    Text(role.code)
                        .font(LRConstants.DS.font(LRConstants.DS.fontCaption, weight: .bold))
                        .foregroundColor(selectedRole == role ? .white : role.color.opacity(0.6))
                        .frame(width: 28, height: 28)
                        .background(
                            selectedRole == role
                                ? role.color
                                : LRConstants.DS.panelHollow
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: LRConstants.DS.radiusSM)
                                .stroke(
                                    selectedRole == role
                                        ? role.color
                                        : role.color.opacity(0.2),
                                    lineWidth: 1
                                )
                        )
                        .cornerRadius(LRConstants.DS.radiusSM)
                }
                .buttonStyle(.plain)
                .help("Set lane role: \(role.label)")
            }
        }
    }
}
