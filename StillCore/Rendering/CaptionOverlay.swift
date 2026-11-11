import AVFoundation
import CoreImage
import CoreText

/// The captions of one render, laid out at its size. Each cue is a few words of a phrase, at most two lines, drawn once
/// in the caption style and placed low in the frame and centered, inside the crop, where a player shows subtitles.
struct CaptionOverlay {
    struct Cue {
        let text: String
        /// Output seconds.
        let start: Double
        let end: Double
        /// Placed in the frame, in Core Image's coordinates (origin at the bottom left).
        let image: CIImage
        /// Where it draws: whole, even pixels, so it never splits a 4:2:0 chroma sample.
        let extent: CGRect
    }

    let cues: [Cue]

    /// Words show this long after they're said, unless the next cue comes first.
    static let linger = 0.6
    /// A gap shorter than this between cues is closed, so the captions don't blink.
    static let shortestGap = 0.25
    static let maxLines = 2

    init(_ captions: BurnedCaptions, plan: EditPlan, renderSize: CGSize) {
        let layout = Layout(style: captions.style, renderSize: renderSize)
        let selectionStart = plan.selection.start.seconds
        let duration = plan.renderedDuration.seconds
        func outputTime(_ source: Double) -> Double { (source - selectionStart) / plan.speed }

        let groups = captions.phrases
            .flatMap { layout.split($0) }
            .sorted { $0[0].start < $1.first!.start }
        var cues: [Cue] = []
        for (index, words) in groups.enumerated() {
            let start = outputTime(words[0].start)
            var end = outputTime(words.last!.end) + Self.linger
            if index + 1 < groups.count {
                let next = outputTime(groups[index + 1][0].start)
                end = next - end < Self.shortestGap ? next : end
            }
            let shownFrom = max(start, 0), shownUntil = min(end, duration)
            guard shownUntil - shownFrom > 1e-3 else { continue }
            let text = Layout.text(of: words)
            guard let (image, extent) = layout.draw(text) else { continue }
            cues.append(Cue(text: text, start: shownFrom, end: shownUntil, image: image, extent: extent))
        }
        self.cues = cues
    }

    /// The cue showing at `time`, in output seconds.
    func cue(at time: Double) -> Cue? {
        cues.first { time >= $0.start && time < $0.end }
    }
}

// MARK: - Layout

extension CaptionOverlay {
    /// Sizes, splits and draws captions for one frame size.
    struct Layout {
        let style: CaptionStyle
        let renderSize: CGSize
        let fontSize: CGFloat
        let font: CTFont
        /// The widest a line of text may be.
        let maxTextWidth: CGFloat
        /// Room around the text for the window, and around that for an outline or shadow.
        let padding: CGSize
        let margin: CGFloat

        init(style: CaptionStyle, renderSize: CGSize) {
            self.style = style
            self.renderSize = renderSize
            fontSize = Self.fontSize(for: renderSize, relativeSize: style.relativeSize)
            font = CTFontCreateWithFontDescriptor(style.font, fontSize, nil)
            padding = CGSize(width: (fontSize * 0.45).rounded(.up), height: (fontSize * 0.2).rounded(.up))
            margin = (fontSize * 0.15).rounded(.up)
            // Lines about as long as a player's, and never wider than the frame.
            let room = renderSize.width * 0.88 - 2 * (padding.width + margin)
            maxTextWidth = max(min(room, fontSize * 22), fontSize * 4)
        }

        /// The system's caption size, about 3% of the frame's shorter side: 33 pixels at 1080p, as AVFoundation sizes
        /// a style's caption preview for a video. Large Text is half as large again.
        static func fontSize(for size: CGSize, relativeSize: Double) -> CGFloat {
            (min(size.width, size.height) * 11 / 360).rounded(.up) * relativeSize
        }

        static func text(of words: [SpokenWord]) -> String {
            words.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        }

        /// Splits a phrase into cues of at most two lines, as even as the words allow, keeping words whole and in
        /// order.
        func split(_ words: [SpokenWord]) -> [[SpokenWord]] {
            guard !words.isEmpty else { return [] }
            var greedy: [[SpokenWord]] = []
            var current: [SpokenWord] = []
            for word in words {
                if !current.isEmpty, !fits(current + [word]) {
                    greedy.append(current)
                    current = []
                }
                current.append(word)
            }
            greedy.append(current)
            guard greedy.count > 1 else { return greedy }
            // The same number of cues, each near an even share of the characters, reads better than full cues and a
            // last one of a word or two.
            let lengths = words.map { $0.text.count }
            let total = Double(lengths.reduce(0, +))
            var balanced: [[SpokenWord]] = []
            var start = 0
            var counted = 0
            for cue in 1..<greedy.count {
                let target = total * Double(cue) / Double(greedy.count)
                var end = start + 1
                while end < words.count - (greedy.count - cue), Double(counted + lengths[start..<end].reduce(0, +)) < target {
                    end += 1
                }
                balanced.append(Array(words[start..<end]))
                counted += lengths[start..<end].reduce(0, +)
                start = end
            }
            balanced.append(Array(words[start...]))
            return balanced.allSatisfy(fits) ? balanced : greedy
        }

        private func fits(_ words: [SpokenWord]) -> Bool {
            lineCount(Self.text(of: words)) <= CaptionOverlay.maxLines
        }

        func lineCount(_ text: String) -> Int {
            let framesetter = CTFramesetterCreateWithAttributedString(attributed(text))
            let path = CGPath(rect: CGRect(x: 0, y: 0, width: maxTextWidth, height: .greatestFiniteMagnitude / 4), transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
            return CFArrayGetCount(CTFrameGetLines(frame))
        }

        private func attributed(_ text: String, outline: Bool = false) -> CFAttributedString {
            var alignment = CTTextAlignment.center
            let paragraph = withUnsafeBytes(of: &alignment) { bytes in
                var setting = CTParagraphStyleSetting(spec: .alignment, valueSize: bytes.count, value: bytes.baseAddress!)
                return CTParagraphStyleCreate(&setting, 1)
            }
            var attributes: [CFString: Any] = [
                kCTFontAttributeName: font,
                kCTForegroundColorAttributeName: style.text.cgColor,
                kCTParagraphStyleAttributeName: paragraph,
            ]
            if outline {
                // A positive width strokes without filling; the stroke straddles the outline, so half shows.
                attributes[kCTStrokeWidthAttributeName] = 16
                attributes[kCTStrokeColorAttributeName] = CaptionStyle.Color.black.cgColor
            }
            return CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary)
        }

        /// Draws `text` as the style shows it, and places it centered near the bottom of the frame.
        func draw(_ text: String) -> (CIImage, CGRect)? {
            let framesetter = CTFramesetterCreateWithAttributedString(attributed(text))
            let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
                framesetter, CFRange(location: 0, length: 0), nil,
                CGSize(width: maxTextWidth, height: .greatestFiniteMagnitude), nil
            )
            // A little wider than suggested, so rounding never wraps a line the measurement kept whole.
            let textSize = CGSize(width: suggested.width.rounded(.up) + 2, height: suggested.height.rounded(.up))
            let width = Self.even(textSize.width + 2 * (padding.width + margin))
            let height = Self.even(textSize.height + 2 * (padding.height + margin))
            guard width > 0, height > 0, let context = CGContext(
                data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }

            let textRect = CGRect(
                x: (width - textSize.width) / 2, y: (height - textSize.height) / 2,
                width: textSize.width, height: textSize.height
            )
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), CGPath(rect: textRect, transform: nil), nil)

            if style.window.isVisible {
                // The style's radius is in points at a typical caption size, about 20 points.
                let radius = min(style.windowCornerRadius * fontSize / 20, (height - 2 * margin) / 2)
                let box = CGRect(x: margin, y: margin, width: width - 2 * margin, height: height - 2 * margin)
                context.addPath(CGPath(roundedRect: box, cornerWidth: radius, cornerHeight: radius, transform: nil))
                context.setFillColor(style.window.cgColor)
                context.fillPath()
            }
            if style.background.isVisible {
                context.setFillColor(style.background.cgColor)
                for line in lineRects(of: frame, in: textRect) { context.fill(line) }
            }

            switch style.edge {
            case .none:
                break
            case .outline:
                context.setLineJoin(.round)
                let outline = CTFramesetterCreateFrame(
                    CTFramesetterCreateWithAttributedString(attributed(text, outline: true)),
                    CFRange(location: 0, length: 0), CGPath(rect: textRect, transform: nil), nil
                )
                CTFrameDraw(outline, context)
            case .dropShadow:
                context.setShadow(offset: CGSize(width: fontSize * 0.06, height: -fontSize * 0.06), blur: fontSize * 0.08,
                                  color: CGColor(gray: 0, alpha: 0.9))
            case .raised:
                context.setShadow(offset: CGSize(width: fontSize * 0.04, height: -fontSize * 0.04), blur: 0,
                                  color: CGColor(gray: 0, alpha: 0.9))
            case .depressed:
                context.setShadow(offset: CGSize(width: -fontSize * 0.04, height: fontSize * 0.04), blur: 0,
                                  color: CGColor(gray: 0, alpha: 0.9))
            }
            CTFrameDraw(frame, context)

            guard let image = context.makeImage() else { return nil }
            let x = Self.even((renderSize.width - width) / 2, rounding: .down)
            // Above the bottom edge by a twentieth of the frame, as players keep subtitles inside the title-safe area.
            let y = Self.even(max(renderSize.height * 0.05, fontSize * 0.5), rounding: .down)
            let extent = CGRect(x: x, y: y, width: width, height: height)
                .intersection(CGRect(origin: .zero, size: renderSize))
            guard !extent.isEmpty else { return nil }
            return (CIImage(cgImage: image).transformed(by: CGAffineTransform(translationX: x, y: y)), extent)
        }

        /// Each line's glyphs, padded a little, for a style with a background behind the text.
        private func lineRects(of frame: CTFrame, in textRect: CGRect) -> [CGRect] {
            let lines = CTFrameGetLines(frame) as! [CTLine]
            var origins = [CGPoint](repeating: .zero, count: lines.count)
            CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
            let pad = (fontSize * 0.2).rounded(.up)
            return zip(lines, origins).map { line, origin in
                var ascent: CGFloat = 0
                var descent: CGFloat = 0
                let width = CTLineGetTypographicBounds(line, &ascent, &descent, nil) - CTLineGetTrailingWhitespaceWidth(line)
                return CGRect(x: textRect.minX + origin.x - pad, y: textRect.minY + origin.y - descent,
                              width: width + 2 * pad, height: ascent + descent).integral
            }
        }

        private static func even(_ value: CGFloat, rounding: FloatingPointRoundingRule = .up) -> CGFloat {
            (value / 2).rounded(rounding) * 2
        }
    }
}

// MARK: - Drawing into frames

/// Draws cues onto frames. Each captioned frame is a copy: the frame itself may repeat in later output slots. Only the
/// cue's pixels are rendered again, in the frame's own color, so the rest of the picture stays exactly as it was.
final class CaptionCompositor {
    private let dynamicRange: DynamicRange
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var pool: CVPixelBufferPool?

    init(dynamicRange: DynamicRange) {
        self.dynamicRange = dynamicRange
    }

    func draw(_ cue: CaptionOverlay.Cue, over frame: CMSampleBuffer) throws -> CMSampleBuffer {
        // Core Image leaves what it drew with autoreleased, holding the frame. On iPhone a movie's writer loop runs for
        // minutes without returning, and every captioned frame stayed until it did: gigabytes, until iOS ended the
        // export or Still.
        try autoreleasepool { try compose(cue, over: frame) }
    }

    private func compose(_ cue: CaptionOverlay.Cue, over frame: CMSampleBuffer) throws -> CMSampleBuffer {
        guard let source = CMSampleBufferGetImageBuffer(frame) else { throw LivePhotoExportError.renderFailed }
        dynamicRange.tag(source)
        let output = try makeBuffer(like: source)
        CVBufferPropagateAttachments(source, output)
        try Self.copyPixels(from: source, to: output)

        // Written back in the color Core Image read the frame in, so the round trip changes nothing but the cue.
        let attachments = CVBufferCopyAttachments(output, .shouldPropagate)
        let colorSpace = attachments.flatMap { CVImageBufferCreateColorSpaceFromAttachments($0)?.takeRetainedValue() }
        let picture = cue.image.composited(over: CIImage(cvPixelBuffer: source))
        context.render(picture, to: output, bounds: cue.extent, colorSpace: colorSpace)

        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: output, formatDescriptionOut: &format)
        var timing = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(frame),
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(frame),
            decodeTimeStamp: .invalid
        )
        var captioned: CMSampleBuffer?
        guard let format, CMSampleBufferCreateReadyWithImageBuffer(
            allocator: nil, imageBuffer: output, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &captioned
        ) == noErr, let captioned else { throw LivePhotoExportError.renderFailed }
        return captioned
    }

    private func makeBuffer(like source: CVPixelBuffer) throws -> CVPixelBuffer {
        if pool == nil {
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: CVPixelBufferGetPixelFormatType(source),
                kCVPixelBufferWidthKey: CVPixelBufferGetWidth(source),
                kCVPixelBufferHeightKey: CVPixelBufferGetHeight(source),
                kCVPixelBufferIOSurfacePropertiesKey: [String: Any](),
            ]
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
        }
        var buffer: CVPixelBuffer?
        guard let pool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else {
            throw LivePhotoExportError.renderFailed
        }
        return buffer
    }

    private static func copyPixels(from source: CVPixelBuffer, to destination: CVPixelBuffer) throws {
        guard CVPixelBufferGetPlaneCount(source) == CVPixelBufferGetPlaneCount(destination),
              CVPixelBufferLockBaseAddress(source, .readOnly) == kCVReturnSuccess else { throw LivePhotoExportError.renderFailed }
        defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }
        guard CVPixelBufferLockBaseAddress(destination, []) == kCVReturnSuccess else { throw LivePhotoExportError.renderFailed }
        defer { CVPixelBufferUnlockBaseAddress(destination, []) }
        for plane in 0..<CVPixelBufferGetPlaneCount(source) {
            guard let from = CVPixelBufferGetBaseAddressOfPlane(source, plane),
                  let to = CVPixelBufferGetBaseAddressOfPlane(destination, plane) else { throw LivePhotoExportError.renderFailed }
            let fromRow = CVPixelBufferGetBytesPerRowOfPlane(source, plane)
            let toRow = CVPixelBufferGetBytesPerRowOfPlane(destination, plane)
            let rows = CVPixelBufferGetHeightOfPlane(source, plane)
            if fromRow == toRow {
                to.copyMemory(from: from, byteCount: rows * fromRow)
            } else {
                for row in 0..<rows {
                    (to + row * toRow).copyMemory(from: from + row * fromRow, byteCount: min(fromRow, toRow))
                }
            }
        }
    }
}
