import AppKit
import AVFoundation
import Observation
import StillCore

/// Filmstrip images for the two timeline strips, generated progressively from the source.
///
/// These are only for orientation on the timeline. The Key Photo thumbnail comes from the preview render
/// instead, because the image generator tone-maps Dolby Vision differently from the export.
@Observable
final class ThumbnailProvider {
    struct Thumbnail: Identifiable {
        let id: Int
        let time: Double
        let image: NSImage
    }

    struct Strip {
        var range: ClosedRange<Double> = 0...0
        var count = 0
        var thumbnails: [Thumbnail] = []
    }

    private(set) var overview = Strip()
    private(set) var detail = Strip()

    @ObservationIgnored private var overviewTask: Task<Void, Never>?
    @ObservationIgnored private var detailTask: Task<Void, Never>?

    func loadOverview(source: SourceMedia, count: Int) {
        let range = 0...source.duration.seconds
        guard count > 0, overview.range != range || overview.count != count else { return }
        overviewTask?.cancel()
        overview = Strip(range: range, count: count)
        overviewTask = load(source: source, range: range, count: count) { [weak self] thumbnail in
            self?.overview.thumbnails.append(thumbnail)
        }
    }

    func loadDetail(source: SourceMedia, range: ClosedRange<Double>, count: Int) {
        guard count > 0, detail.range != range || detail.count != count else { return }
        detailTask?.cancel()
        // Keep showing the previous images, placed by their own times, until the new ones arrive.
        let previous = detail.thumbnails
        detail = Strip(range: range, count: count, thumbnails: previous)
        var replaced = false
        detailTask = load(source: source, range: range, count: count) { [weak self] thumbnail in
            guard let self else { return }
            if !replaced {
                detail.thumbnails = []
                replaced = true
            }
            detail.thumbnails.append(thumbnail)
        }
    }

    func reset() {
        overviewTask?.cancel()
        detailTask?.cancel()
        overview = Strip()
        detail = Strip()
    }

    private func load(
        source: SourceMedia,
        range: ClosedRange<Double>,
        count: Int,
        deliver: @escaping (Thumbnail) -> Void
    ) -> Task<Void, Never> {
        let span = range.upperBound - range.lowerBound
        let times = (0..<count).map { range.lowerBound + (Double($0) + 0.5) / Double(count) * span }
        let generator = AVAssetImageGenerator(asset: source.asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 240, height: 240)
        let tolerance = CMTime(seconds: span / Double(count) / 2, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        let requested = times.map { CMTime(seconds: $0, preferredTimescale: 600) }

        return Task {
            for await result in generator.images(for: requested) {
                guard !Task.isCancelled else { return }
                guard let image = try? result.image else { continue }
                let time = result.requestedTime.seconds
                let index = times.firstIndex { abs($0 - time) < 0.002 } ?? 0
                deliver(Thumbnail(id: index, time: times[index],
                                  image: NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height))))
            }
        }
    }
}
