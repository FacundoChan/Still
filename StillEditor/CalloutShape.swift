import SwiftUI

/// A capsule with a tail under it pointing at `tailX`, drawn as one outline so the tail joins the capsule without a
/// seam. The tail's base stays on the capsule's flat bottom edge, and its tip leans toward `tailX` by at most a
/// tail's width, so it never stretches into a sliver.
public nonisolated struct CalloutShape: Shape {
    public var tailX: CGFloat
    public var tailWidth: CGFloat
    public var tailHeight: CGFloat

    public init(tailX: CGFloat, tailWidth: CGFloat = 10, tailHeight: CGFloat = 5) {
        self.tailX = tailX
        self.tailWidth = tailWidth
        self.tailHeight = tailHeight
    }

    public func path(in rect: CGRect) -> Path {
        let radius = rect.height / 2
        let half = tailWidth / 2
        let base = min(max(tailX, rect.minX + radius + half), rect.maxX - radius - half)
        let tip = CGPoint(x: min(max(tailX, base - tailWidth), base + tailWidth), y: rect.maxY + tailHeight)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + radius, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        path.addArc(center: CGPoint(x: rect.maxX - radius, y: rect.midY), radius: radius,
                    startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false)
        path.addLine(to: CGPoint(x: base + half, y: rect.maxY))
        // A slightly rounded tip, as on the system's callouts.
        path.addLine(to: CGPoint(x: tip.x + 1.5, y: tip.y - 1.5))
        path.addQuadCurve(to: CGPoint(x: tip.x - 1.5, y: tip.y - 1.5), control: tip)
        path.addLine(to: CGPoint(x: base - half, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addArc(center: CGPoint(x: rect.minX + radius, y: rect.midY), radius: radius,
                    startAngle: .degrees(90), endAngle: .degrees(270), clockwise: false)
        path.closeSubpath()
        return path
    }
}
