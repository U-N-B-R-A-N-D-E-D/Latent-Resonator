import SwiftUI

// MARK: - Patch Canvas Types
//
// Shared layout / state primitives used by the native node canvas.
//
// The canvas is a single SwiftUI surface where every node renders its
// own card, and cables are drawn between port positions reported up via
// a `PreferenceKey`. There is no separate "Perform" view — the patch IS
// the performance surface (Max/Envion model).

// MARK: - Port location reporting

/// One entry in the port-position preference dictionary.
///
/// Each `NodeCardChrome` reports the screen-coordinate position of every
/// port chip it draws via `.anchorPreference(...)`. The canvas collects
/// all entries and uses them to draw cables in the cable layer.
struct PatchPortLocation: Equatable {
    let nodeId: UUID
    let portId: String
    let direction: PortDirection
    let signalType: SignalType
    let anchor: Anchor<CGPoint>

    static func == (lhs: PatchPortLocation, rhs: PatchPortLocation) -> Bool {
        lhs.nodeId == rhs.nodeId
            && lhs.portId == rhs.portId
            && lhs.direction == rhs.direction
            && lhs.signalType == rhs.signalType
        // `Anchor<CGPoint>` is not Equatable — but two anchors with the
        // same identity tuple are interchangeable for our purposes (the
        // canvas resolves them through `geometry[anchor]` at render time).
    }
}

struct PatchPortLocationsKey: PreferenceKey {
    static var defaultValue: [PatchPortLocation] = []

    static func reduce(value: inout [PatchPortLocation], nextValue: () -> [PatchPortLocation]) {
        value.append(contentsOf: nextValue())
    }
}

// MARK: - Lock state

/// Max/Envion-style lock toggle on a single canvas.
///
/// - `.unlocked`: cables and port handles fully visible; nodes draggable.
///                Edit affordances ON. This is Max's "unlocked" patcher.
/// - `.locked`:   cables dimmed, edit chrome hidden, knobs full-size on
///                top. Same canvas, just leans on the live controls so
///                you can play without bumping the patch.
enum PatchLockMode: String, CaseIterable {
    case unlocked
    case locked

    var iconName: String {
        switch self {
        case .unlocked: return "lock.open"
        case .locked:   return "lock.fill"
        }
    }

    var label: String {
        switch self {
        case .unlocked: return "UNLOCK"
        case .locked:   return "LOCK"
        }
    }
}

// MARK: - Card metrics

/// One source of truth for the visual rhythm of every node card. Tuning
/// these here propagates to all cards consistently — no per-card magic
/// numbers.
enum NodeCardMetrics {
    static let cornerRadius: CGFloat   = 8
    static let headerHeight: CGFloat   = 22
    static let portChipSize: CGFloat   = 11
    static let portColumnWidth: CGFloat = 16
    static let bodyPaddingH: CGFloat   = 10
    static let bodyPaddingV: CGFloat   = 8
    static let knobSize: CGFloat       = 44
    static let minWidth: CGFloat       = 180
    static let footerHeight: CGFloat   = 14
}
