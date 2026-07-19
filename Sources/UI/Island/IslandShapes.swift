import SwiftUI

/// Opened-island surface: concave quad-curve top corners so the surface
/// visually grows out of the physical notch, rounded bottom corners.
/// Corner radii are animatable so the shape morphs with the spring.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set {
            topRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        // Top edge is full-width; the body is inset by topRadius on each
        // side, joined by outward (concave) quad curves at the top.
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(
            to: CGPoint(x: rect.minX + topRadius, y: rect.minY + topRadius),
            control: CGPoint(x: rect.minX + topRadius, y: rect.minY)
        )
        p.addLine(to: CGPoint(x: rect.minX + topRadius, y: rect.maxY - bottomRadius))
        p.addQuadCurve(
            to: CGPoint(x: rect.minX + topRadius + bottomRadius, y: rect.maxY),
            control: CGPoint(x: rect.minX + topRadius, y: rect.maxY)
        )
        p.addLine(to: CGPoint(x: rect.maxX - topRadius - bottomRadius, y: rect.maxY))
        p.addQuadCurve(
            to: CGPoint(x: rect.maxX - topRadius, y: rect.maxY - bottomRadius),
            control: CGPoint(x: rect.maxX - topRadius, y: rect.maxY)
        )
        p.addLine(to: CGPoint(x: rect.maxX - topRadius, y: rect.minY + topRadius))
        p.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - topRadius, y: rect.minY)
        )
        p.closeSubpath()
        return p
    }
}
