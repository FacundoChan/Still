import AVFoundation
import Observation
import StillCore

/// Filmstrip images for the two timeline strips, generated progressively from the source.
///
/// Images sit on a fixed grid of source time and are kept once made, so when the selection changes and the
/// detail strip's range moves, the images already on screen stay and only the newly revealed ones load.
///
/// These are only for orientation on the timeline. The Key Photo thumbnail comes from the preview render
/// instead, because the image generator tone-maps Dolby Vision differently from the export.
@Observable
public final class ThumbnailProvider {
    public enum Strip { case detail, overview }

    /// One cell of the grid. Levels step the cell's length in quarter octaves, so a slightly longer or shorter
    /// range usually keeps the same cells.
    public struct Slot: Hashable {
        public let level: Int
        public let index: Int

        public var span: Double { ThumbnailProvider.span(ofLevel: level) }
        public var start: Double { Double(index) * span }
    }

    public struct Thumbnail: Identifiable {
        public let slot: Slot
        public let image: CGImage
        public var id: Slot { slot }
    }

    /// Enough for both strips' current images and a few previous zoom levels.
    private static let capacity = 120

    private var images: [Slot: CGImage] = [:]
    private var levels: [Strip: Int] = [:]

    @ObservationIgnored private var shown: [Strip: [Slot]] = [:]
    @ObservationIgnored private var lastUse: [Slot: Int] = [:]
    @ObservationIgnored private var useCount = 0
    @ObservationIgnored private var tasks: [Strip: Task<Void, Never>] = [:]

    public init() {}

    /// Loads what `strip` needs to show `range`, with each image covering about `thumbnailSpan` seconds.
    public func load(_ strip: Strip, source: SourceMedia, range: ClosedRange<Double>, thumbnailSpan: Double) {
        guard thumbnailSpan.isFinite, thumbnailSpan > 0 else { return }
        let level = Int((log2(thumbnailSpan) * 4).rounded())
        let slots = Self.slots(covering: range, level: level)
        guard shown[strip] != slots else { return }
        if levels[strip] != level { levels[strip] = level }
        shown[strip] = slots
        useCount += 1
        for slot in slots { lastUse[slot] = useCount }

        tasks[strip]?.cancel()
        let missing = slots.filter { images[$0] == nil }
        tasks[strip] = missing.isEmpty ? nil : generate(missing, source: source)
    }

    /// The images for `strip` across `range`. Until all of them have loaded, images from other zoom levels
    /// fill the gaps underneath, so the strip never goes blank.
    public func thumbnails(_ strip: Strip, in range: ClosedRange<Double>) -> [Thumbnail] {
        guard let level = levels[strip] else { return [] }
        let slots = Self.slots(covering: range, level: level)
        let current = slots.compactMap { slot in images[slot].map { Thumbnail(slot: slot, image: $0) } }
        let gaps = slots.filter { images[$0] == nil }
        guard !gaps.isEmpty else { return current }
        let standIns = images
            .filter { slot, _ in
                slot.level != level && gaps.contains { $0.start < slot.start + slot.span && slot.start < $0.start + $0.span }
            }
            // The nearest level draws last, on top.
            .sorted { abs($0.key.level - level) > abs($1.key.level - level) }
            .map { Thumbnail(slot: $0.key, image: $0.value) }
        return standIns + current
    }

    public func reset() {
        for task in tasks.values { task.cancel() }
        tasks = [:]
        images = [:]
        levels = [:]
        shown = [:]
        lastUse = [:]
    }

    private static func span(ofLevel level: Int) -> Double {
        pow(2, Double(level) / 4)
    }

    private static func slots(covering range: ClosedRange<Double>, level: Int) -> [Slot] {
        let span = span(ofLevel: level)
        let first = max(0, Int((range.lowerBound / span).rounded(.down)))
        let last = max(first, Int((range.upperBound / span).rounded(.up)) - 1)
        return (first...last).map { Slot(level: level, index: $0) }
    }

    private func generate(_ slots: [Slot], source: SourceMedia) -> Task<Void, Never> {
        let duration = source.duration.seconds
        let times = slots.map { min(max($0.start + $0.span / 2, 0), duration) }
        let generator = AVAssetImageGenerator(asset: source.asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 240, height: 240)
        let tolerance = CMTime(seconds: slots[0].span / 2, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        let requested = times.map { CMTime(seconds: $0, preferredTimescale: 600) }

        return Task {
            for await result in generator.images(for: requested) {
                guard !Task.isCancelled else { return }
                guard let image = try? result.image,
                      let index = requested.firstIndex(of: result.requestedTime) else { continue }
                store(image, for: slots[index])
            }
        }
    }

    private func store(_ image: CGImage, for slot: Slot) {
        images[slot] = image
        guard images.count > Self.capacity else { return }
        // Drop the images used longest ago, never ones a strip is showing.
        let showing = Set(shown.values.joined())
        let evictable = images.keys
            .filter { !showing.contains($0) }
            .sorted { (lastUse[$0] ?? 0) < (lastUse[$1] ?? 0) }
        for slot in evictable.prefix(images.count - Self.capacity) {
            images[slot] = nil
            lastUse[slot] = nil
        }
    }
}
