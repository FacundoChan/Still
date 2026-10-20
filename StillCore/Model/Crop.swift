import CoreGraphics

/// An aspect-ratio choice for the crop (goal.md §8).
public enum CropAspect: Hashable, Sendable {
    /// The source’s own ratio; selecting it resets to the full frame.
    case original
    /// Any rectangle.
    case freeform
    case ratio(width: Double, height: Double)
    /// A user-entered ratio; behaves like `ratio`, but the UI shows it as Custom.
    case custom(width: Double, height: Double)

    public static let presets: [CropAspect] = [
        .original, .freeform,
        .ratio(width: 1, height: 1),
        .ratio(width: 4, height: 3), .ratio(width: 3, height: 4),
        .ratio(width: 3, height: 2), .ratio(width: 2, height: 3),
        .ratio(width: 16, height: 9), .ratio(width: 9, height: 16),
    ]

    public var title: String {
        switch self {
        case .original: "Original"
        case .freeform: "Freeform"
        case let .ratio(width, height): "\(Self.format(width)):\(Self.format(height))"
        case let .custom(width, height): "Custom \(Self.format(width)):\(Self.format(height))"
        }
    }

    /// Width ÷ height in pixels, or nil when the ratio is unconstrained.
    public func pixelRatio(for sourceSize: CGSize) -> Double? {
        switch self {
        case .original: Double(sourceSize.width / sourceSize.height)
        case .freeform: nil
        case let .ratio(width, height), let .custom(width, height): width / height
        }
    }

    var isValid: Bool {
        switch self {
        case .original, .freeform: true
        case let .ratio(width, height), let .custom(width, height):
            width.isFinite && height.isFinite && width > 0 && height > 0
        }
    }

    private static func format(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(value)
    }
}

/// Crop rectangles are normalized to the oriented source: (0, 0) is the top-left corner of the frame
/// as displayed, (1, 1) the bottom-right.
public enum CropGeometry {
    public static let fullFrame = CGRect(x: 0, y: 0, width: 1, height: 1)
    /// Smallest crop edge, in source pixels.
    public static let minimumEdgePixels: CGFloat = 32

    /// The largest rectangle of `pixelRatio` that fits the source, centered on `center` and shifted
    /// inward if it would leave the frame.
    public static func largestRect(pixelRatio: Double, centeredOn center: CGPoint, sourceSize: CGSize) -> CGRect {
        let sourceRatio = Double(sourceSize.width / sourceSize.height)
        let size = pixelRatio >= sourceRatio
            ? CGSize(width: 1, height: sourceRatio / pixelRatio)
            : CGSize(width: pixelRatio / sourceRatio, height: 1)
        return clamped(CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                              width: size.width, height: size.height), sourceSize: sourceSize)
    }

    /// Applies `pixelRatio` to a proposed rectangle, keeping its center and width where possible.
    public static func constrain(_ proposed: CGRect, pixelRatio: Double?, sourceSize: CGSize) -> CGRect {
        guard let pixelRatio else { return clamped(proposed, sourceSize: sourceSize) }
        let sourceRatio = Double(sourceSize.width / sourceSize.height)
        var width = Double(proposed.width)
        var height = width * sourceRatio / pixelRatio
        if height > 1 {
            width /= height
            height = 1
        }
        if width > 1 {
            height /= width
            width = 1
        }
        let minimum = minimumSize(sourceSize: sourceSize)
        let grow = max(1, Double(minimum.width) / width, Double(minimum.height) / height)
        width *= grow
        height *= grow
        let center = CGPoint(x: proposed.midX, y: proposed.midY)
        return clamped(CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height),
                       sourceSize: sourceSize)
    }

    /// Keeps the rectangle inside the frame and at least the minimum size, moving before shrinking.
    public static func clamped(_ rect: CGRect, sourceSize: CGSize) -> CGRect {
        let minimum = minimumSize(sourceSize: sourceSize)
        let width = min(max(rect.width, minimum.width), 1)
        let height = min(max(rect.height, minimum.height), 1)
        let x = min(max(rect.minX, 0), 1 - width)
        let y = min(max(rect.minY, 0), 1 - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    static func minimumSize(sourceSize: CGSize) -> CGSize {
        CGSize(width: min(1, minimumEdgePixels / sourceSize.width),
               height: min(1, minimumEdgePixels / sourceSize.height))
    }
}

/// Output pixel size and the crop in oriented source pixels.
public struct OutputGeometry: Sendable, Equatable {
    public let renderSize: CGSize
    /// The crop in oriented source pixels.
    public let cropPixelRect: CGRect

    public init(orientedSize: CGSize, crop: CGRect, maxLongEdge: Int) {
        let rect = CGRect(
            x: crop.minX * orientedSize.width,
            y: crop.minY * orientedSize.height,
            width: crop.width * orientedSize.width,
            height: crop.height * orientedSize.height
        )
        // Never upscale; cap the longer edge.
        let scale = min(1, CGFloat(maxLongEdge) / max(rect.width, rect.height))
        cropPixelRect = rect
        renderSize = CGSize(width: Self.evenPixels(rect.width * scale), height: Self.evenPixels(rect.height * scale))
    }

    /// Maps encoded source pixels to output pixels: orient, crop, then scale.
    func transform(naturalSize: CGSize, preferredTransform: CGAffineTransform) -> CGAffineTransform {
        let orientedRect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        return preferredTransform
            .concatenating(CGAffineTransform(translationX: -orientedRect.minX - cropPixelRect.minX,
                                             y: -orientedRect.minY - cropPixelRect.minY))
            .concatenating(CGAffineTransform(scaleX: renderSize.width / cropPixelRect.width,
                                             y: renderSize.height / cropPixelRect.height))
    }

    /// 4:2:0 video needs even dimensions; round down so the output never grows.
    static func evenPixels(_ value: CGFloat) -> Int {
        max(2, Int(value.rounded(.down)) & ~1)
    }
}
