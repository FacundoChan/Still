import CoreGraphics
import Foundation

/// Maps between source seconds and points across a strip.
public struct TimeScale {
    public let range: ClosedRange<Double>
    public let width: CGFloat

    public init(range: ClosedRange<Double>, width: CGFloat) {
        self.range = range
        self.width = width
    }

    public var span: Double { max(range.upperBound - range.lowerBound, 0.0001) }
    public var pointsPerSecond: Double { Double(width) / span }

    public func x(_ time: Double) -> CGFloat {
        CGFloat((time - range.lowerBound) / span) * width
    }

    public func time(_ x: CGFloat) -> Double {
        range.lowerBound + Double(x / max(width, 1)) * span
    }
}

public enum TimeFormat {
    /// mm:ss.cc with monospaced digits in mind.
    public static func clock(_ seconds: Double) -> String {
        let clamped = max(0, seconds)
        let minutes = Int(clamped) / 60
        let rest = clamped - Double(minutes * 60)
        return String(format: "%02d:%05.2f", minutes, rest)
    }

    public static func seconds(_ value: Double) -> String {
        String(format: "%.2f s", value)
    }

    /// “1 s”, “4.2 s”: slider end labels.
    public static func shortSeconds(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded() ? "\(Int(rounded)) s" : String(format: "%.1f s", rounded)
    }

    public static func fieldSeconds(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    public static func speed(_ value: Double) -> String {
        let text = value.rounded() == value ? String(Int(value)) : String(value)
        return "\(text)×"
    }
}
