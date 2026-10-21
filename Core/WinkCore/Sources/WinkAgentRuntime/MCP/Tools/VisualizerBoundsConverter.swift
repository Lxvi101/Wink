//
//  VisualizerBoundsConverter.swift
//  WinkAgentRuntime
//

import CoreGraphics
import WinkAutomation
import WinkProtocols
import WinkVisualizer

enum VisualizerBoundsConverter {
    static func convertGlobalAccessibilityRect(_ rect: CGRect, primaryScreenFrame: CGRect?) -> CGRect {
        VisualizerScreenGeometry.appKitRect(
            fromGlobalDisplay: rect,
            primaryScreenFrame: primaryScreenFrame)
    }

    /// Convert automation-detected elements into the bounds format expected by the visualizer overlay.
    @MainActor
    static func makeVisualizerElements(
        from elements: [WinkAutomation.DetectedElement],
        primaryScreenFrame: CGRect?) -> [WinkProtocols.DetectedElement]
    {
        elements.map { element in
            let convertedBounds = VisualizerScreenGeometry.appKitRect(
                fromGlobalDisplay: element.bounds,
                primaryScreenFrame: primaryScreenFrame)
            return WinkProtocols.DetectedElement(
                id: element.id,
                type: element.type,
                bounds: convertedBounds,
                label: element.label,
                value: element.value,
                isEnabled: element.isEnabled)
        }
    }
}
