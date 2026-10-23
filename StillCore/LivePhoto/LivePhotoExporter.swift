import AVFoundation
import CoreMedia
import OSLog

public enum LivePhotoExportError: Error, LocalizedError {
    case invalidPlan(EditPlanIssue)
    case destinationExists(URL)
    case readerConfigurationFailed
    case writerConfigurationFailed
    case metadataUnavailable(OSStatus)
    case keyPhotoEncodingFailed
    case keyPhotoFrameMissing(Double)
    case renderFailed
    case notPaired(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidPlan(issue):
            issue.errorDescription
        case let .destinationExists(url):
            "“\(url.lastPathComponent)” already exists."
        case .readerConfigurationFailed, .writerConfigurationFailed, .renderFailed:
            "The Live Photo couldn’t be rendered."
        case let .metadataUnavailable(status):
            "The Live Photo metadata couldn’t be created (\(status))."
        case .keyPhotoEncodingFailed:
            "The Key Photo couldn’t be saved."
        case let .keyPhotoFrameMissing(seconds):
            String(format: "No frame was rendered at the Key Photo time (%.3f s).", seconds)
        case let .notPaired(reason):
            "Photos didn’t recognize the rendered files as a Live Photo. \(reason)"
        }
    }
}

/// Where an export is, for in-window progress.
public enum LivePhotoExportStage: Sendable, Equatable {
    /// Building the composition and retiming the sound.
    case preparing
    /// Encoding frames; the fraction of output frames done.
    case rendering(Double)
    /// Finishing the movie and checking that the pair is a Live Photo.
    case creatingLivePhoto
}

/// A JPEG and MOV that Photos recognizes as one Live Photo.
public struct LivePhotoPair: Sendable, Equatable {
    public let imageURL: URL
    public let videoURL: URL
    public let contentIdentifier: String
    /// Presentation time of the Key Photo frame in the movie.
    public let keyPhotoTime: CMTime
    public let duration: CMTime
    public let pixelSize: CGSize
    public let hasAudio: Bool
    /// The Key Photo's moment, from the video's recording date; nil when the video has none.
    public let captureDate: Date?
    /// Where the video was taken, when the edit includes it.
    public let location: CaptureLocation?

    func moved(to directory: URL) -> LivePhotoPair {
        LivePhotoPair(
            imageURL: directory.appending(path: imageURL.lastPathComponent),
            videoURL: directory.appending(path: videoURL.lastPathComponent),
            contentIdentifier: contentIdentifier,
            keyPhotoTime: keyPhotoTime,
            duration: duration,
            pixelSize: pixelSize,
            hasAudio: hasAudio,
            captureDate: captureDate,
            location: location
        )
    }
}

public struct LivePhotoExporter: Sendable {
    private static let log = Logger(subsystem: "com.chen.Still", category: "export")

    public init() {}

    /// Renders `plan` into `<baseName>.JPG` and `<baseName>.MOV` inside `directory`.
    ///
    /// Never overwrites existing files, and removes anything it wrote if rendering fails or is cancelled,
    /// including `directory` itself when the export created it.
    ///
    /// - Parameter verifiesPairing: also ask Photos to load the result as a Live Photo before returning,
    ///   so a pair that wouldn’t pair is never handed on.
    public func export(
        _ plan: EditPlan,
        source: SourceMedia,
        to directory: URL,
        baseName: String,
        verifiesPairing: Bool = false,
        progress: (@Sendable (LivePhotoExportStage) -> Void)? = nil
    ) async throws -> LivePhotoPair {
        if let issue = plan.issue(sourceDuration: source.duration) {
            throw LivePhotoExportError.invalidPlan(issue)
        }
        progress?(.preparing)

        let fileManager = FileManager.default
        let createsDirectory = !fileManager.fileExists(atPath: directory.path)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let imageURL = directory.appending(path: "\(baseName).JPG")
        let videoURL = directory.appending(path: "\(baseName).MOV")
        for url in [imageURL, videoURL] where fileManager.fileExists(atPath: url.path) {
            throw LivePhotoExportError.destinationExists(url)
        }

        let contentIdentifier = UUID().uuidString
        let capture = CaptureStamp(capture: source.capture, plan: plan)
        do {
            try Task.checkCancellation()
            let graph = try RenderPipeline.build(source: source, plan: plan)
            let session = try MovieRenderSession(
                graph: graph,
                plan: plan,
                movieURL: videoURL,
                keyPhotoURL: imageURL,
                contentIdentifier: contentIdentifier,
                capture: capture,
                progress: progress
            )
            // Retiming the sound happens while the session is set up, before any frame is read.
            try Task.checkCancellation()
            let result = try await session.run()
            try Task.checkCancellation()

            if verifiesPairing {
                switch await LivePhotoInspector.checkPairing(imageURL: imageURL, videoURL: videoURL) {
                case .paired:
                    break
                case let .failed(reason):
                    throw LivePhotoExportError.notPaired(reason)
                case .timedOut:
                    // A slow answer says nothing about the files; the identifiers and marker were written above.
                    Self.log.notice("Pairing check timed out; continuing with the export")
                }
                try Task.checkCancellation()
            }

            return LivePhotoPair(
                imageURL: imageURL,
                videoURL: videoURL,
                contentIdentifier: contentIdentifier,
                keyPhotoTime: result.keyPhotoPresentationTime,
                duration: graph.outputDuration,
                pixelSize: graph.renderSize,
                hasAudio: graph.hasAudio,
                captureDate: capture.photoDate,
                location: capture.location
            )
        } catch {
            // Both files are new (checked above), so removing them never touches the user's data.
            try? fileManager.removeItem(at: imageURL)
            try? fileManager.removeItem(at: videoURL)
            if createsDirectory { try? fileManager.removeItem(at: directory) }
            throw error
        }
    }

    /// Moves a rendered pair into a new folder, as one unit: the folder appears with both files or not at all.
    ///
    /// Fails without touching anything if `folder` already exists.
    public func deliver(_ pair: LivePhotoPair, toNewFolder folder: URL) throws -> LivePhotoPair {
        let fileManager = FileManager.default
        do {
            // Not creating intermediates makes this the existence check, with no gap before the folder is ours.
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: false)
        } catch CocoaError.fileWriteFileExists {
            throw LivePhotoExportError.destinationExists(folder)
        }
        let delivered = pair.moved(to: folder)
        do {
            try fileManager.moveItem(at: pair.imageURL, to: delivered.imageURL)
            try fileManager.moveItem(at: pair.videoURL, to: delivered.videoURL)
            return delivered
        } catch {
            // The folder is new, so everything in it came from this call.
            try? fileManager.removeItem(at: folder)
            throw error
        }
    }
}
