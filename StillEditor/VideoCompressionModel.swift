import AVFoundation
import Observation
import OSLog
import StillCore

/// One video being compressed: the choices, the size they would give, and the copy, saved to Photos or shared.
///
/// The copy renders into the app's export folder and stays there while the choices stay the same, so saving it and
/// sharing it render once. Choices made here are remembered for the next video, apart from the Live Photo editor's.
@Observable
public final class VideoCompressionModel {
    public enum Phase: Equatable {
        case loading
        case ready
        case failed(String)
    }

    public enum Destination: Equatable {
        case photos
        case sharing
    }

    public enum Stage: Equatable {
        case preparing
        case compressing(Double)
        case finishing
        /// Handing the copy to Photos. This can no longer be cancelled.
        case saving
    }

    public private(set) var phase = Phase.loading
    public private(set) var source: SourceMedia?
    public private(set) var sourceName = ""
    public private(set) var compression: VideoCompression?
    /// How this video encodes with the current choices, once a few pieces of it have been rendered.
    public private(set) var calibration: SizeCalibration?
    public private(set) var isEstimating = false
    /// The copy made with the current choices, once there is one.
    public private(set) var compressed: CompressedVideo?
    public private(set) var destination: Destination?
    public private(set) var stage: Stage?
    /// Cancel was requested; the current stage is winding down.
    public private(set) var isCancelling = false
    public private(set) var hasSavedToPhotos = false
    public private(set) var notice: String?
    /// The last failure, until the user dismisses it.
    public var failure: VideoCompressionFailure?

    @ObservationIgnored private var compressedChoices: VideoCompression?
    @ObservationIgnored private var calibrations: [(key: CalibrationKey, calibration: SizeCalibration)] = []
    @ObservationIgnored private var estimateTask: Task<Void, Never>?
    @ObservationIgnored private var exportTask: Task<Bool, Never>?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var accessedURL: URL?
    private static let log = Logger(subsystem: "com.chen.Still", category: "compression")

    public init() {}

    // MARK: - Derived

    public var isRunning: Bool { stage != nil }

    public var canCancel: Bool {
        guard let stage else { return false }
        return stage != .saving && !isCancelling
    }

    public var canExport: Bool { phase == .ready && compression != nil && !isRunning }

    /// The copy's size: what it came to once made, or else the estimate.
    public var fileSize: Int64? {
        if let compressed { return compressed.byteCount }
        return compression?.estimatedFileSize(calibration: calibration)
    }

    /// Whether `fileSize` is what the copy came to rather than an estimate.
    public var isFileSizeExact: Bool { compressed != nil }

    /// Overall progress, weighted by how long each stage usually takes.
    public var progress: Double {
        switch stage {
        case nil, .preparing: 0.02
        case let .compressing(fraction): 0.02 + 0.93 * fraction
        case .finishing: 0.96
        case .saving: 0.98
        }
    }

    public var stageTitle: String {
        switch stage {
        case nil: ""
        case _ where isCancelling: String(localized: "Cancelling…", bundle: #bundle)
        case .preparing: String(localized: "Preparing…", bundle: #bundle)
        case .compressing: String(localized: "Compressing…", bundle: #bundle)
        case .finishing: String(localized: "Finishing…", bundle: #bundle)
        case .saving: String(localized: "Saving to Photos…", bundle: #bundle)
        }
    }

    // MARK: - Opening

    public func load(_ url: URL) async {
        phase = .loading
        accessedURL = url.startAccessingSecurityScopedResource() ? url : nil
        do {
            let media = try await SourceMedia.load(url)
            var compression = VideoCompression(source: try await media.compressionSource())
            Self.applyRememberedChoices(to: &compression)
            source = media
            sourceName = url.lastPathComponent
            self.compression = compression
            phase = .ready
            scheduleEstimate()
        } catch {
            TemporaryFiles.removeImportedCopy(url)
            phase = .failed(error.localizedDescription)
        }
    }

    /// Opening failed before there was a video to load, as when Photos couldn't hand it over.
    public func reportLoadFailure(_ message: String) {
        phase = .failed(message)
    }

    // MARK: - Choices

    public func setResolution(_ resolution: OutputResolution) {
        change { $0.setResolution(resolution) }
        UserDefaults.standard.set(resolution.rawValue, forKey: Self.resolutionKey)
    }

    public func setBitRate(_ bitRate: VideoBitRate) {
        change { $0.setBitRate(bitRate) }
        UserDefaults.standard.set(bitRate.rawValue, forKey: Self.bitRateKey)
    }

    /// Nil keeps the original's frame rate.
    public func setFrameRate(_ rate: Int32?) {
        change { $0.setFrameRate(rate) }
        UserDefaults.standard.set(Int(rate ?? 0), forKey: Self.frameRateKey)
    }

    public func setCodec(_ codec: OutputSettings.VideoCodec) {
        change { $0.setCodec(codec) }
        UserDefaults.standard.set(codec == .h264 ? "h264" : "hevc", forKey: Self.codecKey)
    }

    public func setKeepsHDR(_ on: Bool) {
        change { $0.setKeepsHDR(on) }
        UserDefaults.standard.set(on, forKey: Self.hdrKey)
    }

    /// Sound is a choice for this video only: the next one keeps its sound.
    public func setIncludesAudio(_ include: Bool) {
        change { $0.setIncludesAudio(include) }
    }

    public func setIncludesLocation(_ include: Bool) {
        change { $0.setIncludesLocation(include) }
        UserDefaults.standard.set(include, forKey: Self.locationKey)
    }

    private func change(_ edit: (inout VideoCompression) -> Void) {
        guard var next = compression, !isRunning else { return }
        edit(&next)
        guard next != compression else { return }
        compression = next
        if next != compressedChoices { discardCopy() }
        scheduleEstimate()
    }

    /// New videos start with the choices made last.
    private static func applyRememberedChoices(to compression: inout VideoCompression) {
        let defaults = UserDefaults.standard
        if let resolution = defaults.string(forKey: resolutionKey).flatMap(OutputResolution.init(rawValue:)) {
            compression.setResolution(resolution)
        }
        if let bitRate = defaults.string(forKey: bitRateKey).flatMap(VideoBitRate.init(rawValue:)) {
            compression.setBitRate(bitRate)
        }
        let rate = defaults.integer(forKey: frameRateKey)
        if rate > 0 { compression.limitFrameRate(to: Int32(rate)) }
        if defaults.string(forKey: codecKey) == "h264" { compression.setCodec(.h264) }
        if defaults.object(forKey: hdrKey) != nil { compression.setKeepsHDR(defaults.bool(forKey: hdrKey)) }
        compression.setIncludesLocation(defaults.bool(forKey: locationKey))
    }

    private static let resolutionKey = "CompressionResolution"
    private static let bitRateKey = "CompressionBitRate"
    /// The highest frame rate chosen, or 0 for the original's.
    private static let frameRateKey = "CompressionFrameRate"
    private static let codecKey = "CompressionCodec"
    private static let hdrKey = "CompressionHDR"
    private static let locationKey = "CompressionIncludesLocation"

    // MARK: - Estimate

    /// What a measurement depends on: the sound and location don't change how the picture encodes.
    private struct CalibrationKey: Equatable {
        let output: OutputSettings
        let keepsFrameTiming: Bool

        init(_ compression: VideoCompression) {
            output = compression.output
            keepsFrameTiming = compression.keepsOriginalFrameRate
        }
    }

    /// Measures how the video encodes with the current choices once they've settled, unless it's known already.
    private func scheduleEstimate() {
        estimateTask?.cancel()
        guard let compression, let source else { return }
        let key = CalibrationKey(compression)
        if let known = calibrations.first(where: { $0.key == key }) {
            calibration = known.calibration
            isEstimating = false
            return
        }
        // Until then, the estimate is the bit rate asked for.
        calibration = nil
        isEstimating = true
        estimateTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            do {
                let measured = try await VideoExporter().measure(compression, source: source, in: TemporaryFiles.previews)
                guard !Task.isCancelled, let self else { return }
                calibrations.append((key, measured))
                calibration = measured
            } catch {
                guard !Task.isCancelled else { return }
                Self.log.error("Size estimate failed: \(String(describing: error), privacy: .public)")
            }
            self?.isEstimating = false
        }
    }

    // MARK: - Saving and sharing

    /// Starts saving the copy to Photos, making it first if needed; the task returns whether it saved.
    @discardableResult
    public func saveToPhotos() -> Task<Bool, Never>? {
        start(.photos) { [self] in
            // Asking before rendering means a refusal costs the user nothing.
            try await PhotosLibrarySaver.ensureAddAccess()
            let video = try await makeCopy()
            stage = .saving
            try await PhotosLibrarySaver.saveVideo(at: video.url, originalFilename: photosFilename, creationDate: video.captureDate,
                                                   location: video.location)
            hasSavedToPhotos = true
            show(String(localized: "Saved to Photos", bundle: #bundle))
        }
    }

    /// The copy for the share sheet, made first if needed; nil when making it failed or was cancelled.
    public func copyForSharing() async -> URL? {
        guard let task = start(.sharing, { [self] in _ = try await makeCopy() }), await task.value else { return nil }
        return compressed?.url
    }

    /// Runs a failed save to Photos again; a failed share is run again by whoever shows the share sheet.
    @discardableResult
    public func retry(_ failure: VideoCompressionFailure) -> Task<Bool, Never>? {
        self.failure = nil
        return failure.destination == .photos ? saveToPhotos() : nil
    }

    /// Stops making the copy, unless Photos is already saving it.
    public func cancel() {
        guard canCancel else { return }
        isCancelling = true
        exportTask?.cancel()
    }

    /// Waits for the save or share in progress, if any, to end.
    public func waitUntilFinished() async {
        _ = await exportTask?.value
    }

    private func start(_ destination: Destination, _ work: @escaping () async throws -> Void) -> Task<Bool, Never>? {
        guard canExport else { return nil }
        estimateTask?.cancel()
        isEstimating = false
        self.destination = destination
        stage = .preparing
        failure = nil
        let task = Task { [self] in
            defer {
                exportTask = nil
                self.destination = nil
                stage = nil
                isCancelling = false
                // A measurement stopped for the render starts again.
                if calibration == nil, compressed == nil { scheduleEstimate() }
            }
            do {
                try await work()
                return true
            } catch is CancellationError {
                return false
            } catch {
                Self.log.error("Compression failed: \(String(describing: error), privacy: .public)")
                failure = VideoCompressionFailure(error, destination: destination, source: source)
                return false
            }
        }
        exportTask = task
        return task
    }

    /// The copy with the current choices: the one made already, or a new one.
    private func makeCopy() async throws -> CompressedVideo {
        guard let compression, let source else { throw VideoExportError.renderFailed }
        if let compressed, compressedChoices == compression { return compressed }
        let folder = try TemporaryFiles.makeItemFolder(in: TemporaryFiles.exports)
        do {
            let video = try await VideoExporter().export(compression, source: source, to: folder.appending(path: "\(baseName).MOV"),
                                                         progress: progressHandler())
            try Task.checkCancellation()
            discardCopy()
            compressed = video
            compressedChoices = compression
            return video
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    private func discardCopy() {
        if let compressed { try? FileManager.default.removeItem(at: compressed.url.deletingLastPathComponent()) }
        compressed = nil
        compressedChoices = nil
    }

    private func progressHandler() -> @Sendable (VideoExportStage) -> Void {
        { [weak self] stage in
            Task { @MainActor in
                guard let self, let current = self.stage else { return }
                let next: Stage = switch stage {
                case .preparing: .preparing
                case let .compressing(fraction): .compressing(fraction)
                case .finishing: .finishing
                }
                // Updates hop to the main actor one by one; never let a late one move the bar backwards.
                if Self.order(of: next) >= Self.order(of: current) { self.stage = next }
            }
        }
    }

    private static func order(of stage: Stage) -> Double {
        switch stage {
        case .preparing: 0
        case let .compressing(fraction): 1 + fraction
        case .finishing: 3
        case .saving: 4
        }
    }

    /// What the copy is called when shared: the video's own name.
    private var baseName: String {
        let base = (sourceName as NSString).deletingPathExtension
        return base.isEmpty ? String(localized: "Video", bundle: #bundle) : base
    }

    /// Development builds name Photos resources so test assets are easy to find, as the Live Photo export does.
    private var photosFilename: String {
        #if DEBUG
        let stamp = Date.now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: "")
        return "StillTest-\(stamp)"
        #else
        return baseName
        #endif
    }

    // MARK: - Notices and closing

    public func show(_ message: String) {
        notice = message
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    /// Lets go of the video and the copy once the screen has closed.
    public func close() {
        exportTask?.cancel()
        estimateTask?.cancel()
        noticeTask?.cancel()
        discardCopy()
        if let source { TemporaryFiles.removeImportedCopy(source.url) }
        accessedURL?.stopAccessingSecurityScopedResource()
        accessedURL = nil
    }
}

/// A save or share that failed, described for the user with what they can do next.
public struct VideoCompressionFailure: Identifiable {
    public enum Recovery: Hashable, Identifiable {
        case tryAgain
        case share
        case openPhotosSettings

        public var id: Self { self }

        public var title: String {
            switch self {
            case .tryAgain: String(localized: "Try Again", bundle: #bundle)
            case .share: String(localized: "Share Video…", bundle: #bundle)
            case .openPhotosSettings: ExportFailure.openSettingsTitle
            }
        }
    }

    public let id = UUID()
    public let destination: VideoCompressionModel.Destination
    public let title: String
    public let message: String
    /// The first is the default action. Every alert also offers Cancel, and the choices are always kept.
    public let recoveries: [Recovery]

    init(_ error: Error, destination: VideoCompressionModel.Destination, source: SourceMedia?) {
        self.destination = destination
        let toPhotos = destination == .photos
        let alternative: [Recovery] = toPhotos ? [.share] : []
        if case PhotosSaveError.accessDenied = error {
            title = String(localized: "Still can’t add to your Photos library", bundle: #bundle)
            message = String(localized: "\(ExportFailure.photosPermissionHint) You can also share the video instead.", bundle: #bundle)
            recoveries = [.openPhotosSettings, .share]
        } else if Self.isOutOfSpace(error) {
            title = String(localized: "There isn’t enough disk space", bundle: #bundle)
            message = String(localized: "Free up some space, then try again.", bundle: #bundle)
            recoveries = [.tryAgain] + alternative
        } else if let source, !FileManager.default.fileExists(atPath: source.url.path) {
            title = String(localized: "“\(source.url.lastPathComponent)” is no longer available", bundle: #bundle)
            message = String(localized: "The video may have been moved or deleted, or its disk disconnected. Put it back, or reconnect the disk, and try again.", bundle: #bundle)
            recoveries = [.tryAgain]
        } else if toPhotos, error is PhotosSaveError {
            title = String(localized: "Photos couldn’t save the video", bundle: #bundle)
            message = Self.detail(of: error, fallback: String(localized: "Try again, or share the video instead.", bundle: #bundle))
            recoveries = [.tryAgain, .share]
        } else {
            title = String(localized: "The video couldn’t be compressed", bundle: #bundle)
            message = Self.detail(of: error, fallback: String(localized: "Try again. Your choices are unchanged.", bundle: #bundle))
            recoveries = [.tryAgain] + alternative
        }
    }

    private static func detail(of error: Error, fallback: String) -> String {
        if case let PhotosSaveError.saveFailed(underlying?) = error {
            return "\(underlying.localizedDescription) \(fallback)"
        }
        if error is PhotosSaveError || error is VideoExportError { return fallback }
        let description = (error as? LocalizedError)?.errorDescription ?? (error as NSError).localizedDescription
        return description.isEmpty ? fallback : "\(description) \(fallback)"
    }

    /// Looks through underlying errors too: AVFoundation and Photos wrap the file system's answer.
    private static func isOutOfSpace(_ error: Error) -> Bool {
        if (error as? PhotosSaveError)?.photosErrorCode == .notEnoughSpace { return true }
        var next: NSError? = error as NSError
        for _ in 0..<8 {
            guard let current = next else { break }
            if (current.domain == NSCocoaErrorDomain && current.code == NSFileWriteOutOfSpaceError)
                || (current.domain == AVFoundationErrorDomain && current.code == AVError.diskFull.rawValue)
                || (current.domain == NSPOSIXErrorDomain && current.code == Int(ENOSPC)) {
                return true
            }
            next = current.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }
}
