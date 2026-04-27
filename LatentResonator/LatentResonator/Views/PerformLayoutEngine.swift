import SwiftUI

// MARK: - Perform Layout Engine (Phase 3)
//
// Auto-generates performance control surface layout from ExposedControl array.
// Implements adaptive layout strategy inspired by auto-generation systems:
// - 1-4 controls: single row, large knobs (96pt)
// - 5-8 controls: two rows, medium knobs (74pt)
// - 9-16 controls: grid 4 columns, small knobs (56pt)
// - XY pad: automatically detected when 2 controls share spatial relationship
//
// No manual layout - the system "reads" what's exposed and generates interface.

struct PerformLayout {
    let rows: [LayoutRow]
    let knobSize: CGFloat
}

struct LayoutRow: Identifiable {
    let id = UUID()
    let items: [LayoutItem]
}

struct LayoutItem: Identifiable {
    let id = UUID()
    let control: ExposedControl
    let controlType: ControlWidget
    
    // For XY pads (paired controls)
    let xControl: ExposedControl?
    let yControl: ExposedControl?
    
    init(control: ExposedControl, controlType: ControlWidget, xControl: ExposedControl? = nil, yControl: ExposedControl? = nil) {
        self.control = control
        self.controlType = controlType
        self.xControl = xControl
        self.yControl = yControl
    }
}

struct PerformLayoutEngine {
    
    /// Compute adaptive layout from exposed controls.
    /// Returns layout specification with rows and sizing.
    static func compute(for controls: [ExposedControl]) -> PerformLayout {
        let count = controls.count
        
        // Determine layout strategy based on control count
        if count == 0 {
            return PerformLayout(rows: [], knobSize: 0)
        } else if count <= 4 {
            // Single row, large knobs
            return layoutSingleRow(controls, knobSize: 96)
        } else if count <= 8 {
            // Two rows, medium knobs
            return layoutTwoRows(controls, knobSize: 74)
        } else if count <= 16 {
            // Grid layout, 4 columns, small knobs
            return layoutGrid(controls, columns: 4, knobSize: 56)
        } else {
            // Scrollable grid with section headers (grouped by source node)
            return layoutScrollableGrid(controls, columns: 4, knobSize: 56)
        }
    }
    
    // MARK: - Layout Strategies
    
    private static func layoutSingleRow(_ controls: [ExposedControl], knobSize: CGFloat) -> PerformLayout {
        let items = controls.map { control in
            LayoutItem(
                control: control,
                controlType: mapControlType(control),
                xControl: nil,
                yControl: nil
            )
        }
        return PerformLayout(
            rows: [LayoutRow(items: items)],
            knobSize: knobSize
        )
    }
    
    private static func layoutTwoRows(_ controls: [ExposedControl], knobSize: CGFloat) -> PerformLayout {
        let midpoint = (controls.count + 1) / 2
        let row1 = Array(controls[..<midpoint])
        let row2 = Array(controls[midpoint...])
        
        let rows = [row1, row2].map { rowControls in
            LayoutRow(items: rowControls.map { control in
                LayoutItem(
                    control: control,
                    controlType: mapControlType(control),
                    xControl: Optional<ExposedControl>.none,
                    yControl: Optional<ExposedControl>.none
                )
            })
        }
        
        return PerformLayout(rows: rows, knobSize: knobSize)
    }
    
    private static func layoutGrid(_ controls: [ExposedControl], columns: Int, knobSize: CGFloat) -> PerformLayout {
        // Detect XY pairs first
        var items: [LayoutItem] = []
        var usedIndices = Set<Int>()
        
        // Scan for consecutive controls that form XY pairs
        for i in 0..<(controls.count - 1) {
            guard !usedIndices.contains(i) else { continue }
            
            let control1 = controls[i]
            let control2 = controls[i + 1]
            
            if isXYPair(control1, control2) {
                // Create XY pad item
                items.append(LayoutItem(
                    control: control1,
                    controlType: .xyPad,
                    xControl: control1,
                    yControl: control2
                ))
                usedIndices.insert(i)
                usedIndices.insert(i + 1)
            }
        }
        
        // Add remaining controls as individual items
        for (index, control) in controls.enumerated() {
            guard !usedIndices.contains(index) else { continue }
            items.append(LayoutItem(
                control: control,
                controlType: mapControlType(control),
                xControl: Optional<ExposedControl>.none,
                yControl: Optional<ExposedControl>.none
            ))
        }
        
        // Group into rows
        let rows = stride(from: 0, to: items.count, by: columns).map { startIndex in
            let endIndex = min(startIndex + columns, items.count)
            return LayoutRow(items: Array(items[startIndex..<endIndex]))
        }
        
        return PerformLayout(rows: rows, knobSize: knobSize)
    }
    
    private static func layoutScrollableGrid(_ controls: [ExposedControl], columns: Int, knobSize: CGFloat) -> PerformLayout {
        // Group by source node for section headers
        let grouped = Dictionary(grouping: controls) { $0.nodeId }
        
        var items: [LayoutItem] = []
        for (_, nodeControls) in grouped {
            for control in nodeControls {
                items.append(LayoutItem(
                    control: control,
                    controlType: mapControlType(control),
                    xControl: Optional<ExposedControl>.none,
                    yControl: Optional<ExposedControl>.none
                ))
            }
        }
        
        // Same grid layout as above
        let rows = stride(from: 0, to: items.count, by: columns).map { startIndex in
            let endIndex = min(startIndex + columns, items.count)
            return LayoutRow(items: Array(items[startIndex..<endIndex]))
        }
        
        return PerformLayout(rows: rows, knobSize: knobSize)
    }
    
    // MARK: - Helper Functions
    
    /// Determine if two consecutive controls form an XY pair.
    /// Heuristic: labels contain "X" and "Y", or range/type similarity suggests 2D control.
    private static func isXYPair(_ control1: ExposedControl, _ control2: ExposedControl) -> Bool {
        let label1 = control1.label.lowercased()
        let label2 = control2.label.lowercased()
        
        // Check for explicit X/Y labels
        if (label1.contains("x") && label2.contains("y")) ||
           (label1.contains("horizontal") && label2.contains("vertical")) {
            return true
        }
        
        // Check if ranges match (suggesting 2D control)
        if control1.range == control2.range &&
           control1.controlType == control2.controlType {
            return true
        }
        
        return false
    }
    
    /// Map ExposedControl to widget type.
    private static func mapControlType(_ control: ExposedControl) -> ControlWidget {
        switch control.controlType {
        case .knob:
            return .knob
        case .fader:
            return .fader
        case .xyPad:
            return .xyPad
        case .toggle:
            return .toggle
        case .dropdown:
            return .dropdown
        }
    }
}
