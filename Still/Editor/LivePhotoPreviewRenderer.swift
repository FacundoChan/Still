import AppKit
import Observation
import Photos
import StillCore

/// Renders the Live Photo in the background once edits settle, for the LIVE preview and the inspector's Key
/// Photo. It uses the export pipeline, so the Key Photo shown is the one that will be saved. It renders at the
/// size the stage shows it, so the LIVE preview is sharp on screen.
@Observable
final class LivePhotoPreviewRenderer {
    private(set) var isRendering = false
    private(set) var livePhoto: PHLivePhoto?
    private(set) var keyPhoto: NSImage?
    /// The edit the current preview was rendered from.
    private(set) var renderedPlan: EditPlan?
    /// How the latest preview actually encoded, for the size estimate. It's kept while a new preview renders:
    /// the same video at a slightly different edit encodes much the same.
    private(set) var sizeCalibration: SizeCalibration?
    /// Whether the LIVE overlay is playing.
    var isPlaying = false

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var playWhenReady = false
    @ObservationIgnored private var directory: URL?

    func isCurrent(for plan: EditPlan) -> Bool {
        renderedPlan == plan
    }

    /// Renders `plan` after `delay` with its longer edge at most `longEdge` pixels, replacing any render still
    /// waiting or running.
    func schedule(_ plan: EditPlan, source: SourceMedia, longEdge: Int, delay: Duration = .milliseconds(600)) {
        task?.cancel()
        guard plan.issue(sourceDuration: source.duration) == nil else {
            isRendering = false
            return
        }
        isRendering = true
        task = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.render(plan, source: source, longEdge: longEdge)
        }
    }

    /// Plays the preview now, or as soon as the render in progress finishes.
    func play() {
        if livePhoto != nil && !isRendering {
            isPlaying = true
        } else if isRendering {
            playWhenReady = true
        }
    }

    func stop() {
        playWhenReady = false
        isPlaying = false
    }

    func reset() {
        task?.cancel()
        stop()
        isRendering = false
        livePhoto = nil
        keyPhoto = nil
        renderedPlan = nil
        sizeCalibration = nil
        removeDirectory()
    }

    private func render(_ plan: EditPlan, source: SourceMedia, longEdge: Int) async {
        var reduced = plan
        reduced.output.maxLongEdge = min(plan.output.maxLongEdge, longEdge)
        let directory = TemporaryFiles.previews.appending(path: UUID().uuidString)
        do {
            let pair = try await LivePhotoExporter().export(reduced, source: source, to: directory, baseName: "Preview")
            let photo = try await LivePhotoInspector.loadLivePhoto(imageURL: pair.imageURL, videoURL: pair.videoURL)
            let calibration = try? await SizeCalibration.measure(pair, plan: reduced)
            guard !Task.isCancelled else {
                try? FileManager.default.removeItem(at: directory)
                return
            }
            removeDirectory()
            self.directory = directory
            livePhoto = photo
            keyPhoto = Self.image(at: pair.imageURL)
            if let calibration { sizeCalibration = calibration }
            renderedPlan = plan
            isRendering = false
            if playWhenReady {
                playWhenReady = false
                isPlaying = true
            }
        } catch {
            try? FileManager.default.removeItem(at: directory)
            if !Task.isCancelled { isRendering = false }
        }
    }

    private func removeDirectory() {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }

    /// Decoded with its gain map applied, so the inspector can show an HDR Key Photo as HDR.
    private static func image(at url: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [
                  kCGImageSourceDecodeRequest: kCGImageSourceDecodeToHDR,
              ] as CFDictionary)
        else { return NSImage(contentsOf: url) }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}
