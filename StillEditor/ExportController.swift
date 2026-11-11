import AVFoundation
import Observation
import OSLog
import Photos
import StillCore

/// Runs one export at a time for an editor window, with stages, cancellation, and recovery.
///
/// Every export renders into a private staging folder first. Only a finished, verified pair, or a finished movie, is
/// handed to Photos or moved into the user’s folder, so a cancelled or failed export never leaves a partial result
/// where the user would find it.
@Observable
public final class ExportController {
    public enum Destination: Equatable {
        case photos
        /// A new folder the user named; it must not exist yet.
        case folder(URL)
    }

    public enum Stage: Equatable {
        case preparing
        case rendering(Double)
        case creatingLivePhoto
        /// Handing the pair to Photos, or moving it into the folder. This can no longer be cancelled.
        case saving
    }

    public enum Outcome: Equatable {
        case saved(Destination)
        case cancelled
        case failed
    }

    /// What an export makes.
    public enum Kind: Equatable {
        case livePhoto
        /// A plain movie; `keepsFrameTiming` and `audio` as `VideoExporter` takes them.
        case video(keepsFrameTiming: Bool, audio: CompressionSource.Audio?)
    }

    public private(set) var destination: Destination?
    public private(set) var stage: Stage?
    /// Cancel was requested; the current stage is winding down.
    public private(set) var isCancelling = false
    /// The last failure, until the user dismisses it.
    public var failure: ExportFailure?

    @ObservationIgnored private var task: Task<Outcome, Never>?
    private static let log = Logger(subsystem: "com.chen.Still", category: "export")

    public init() {}

    public var isRunning: Bool { stage != nil }

    public var canCancel: Bool {
        guard let stage else { return false }
        return stage != .saving && !isCancelling
    }

    /// Overall progress, weighted by how long each stage usually takes.
    public var progress: Double {
        switch stage {
        case nil, .preparing: 0.02
        case let .rendering(fraction): 0.02 + 0.88 * fraction
        case .creatingLivePhoto: 0.92
        case .saving: 0.97
        }
    }

    public var stageTitle: String {
        switch stage {
        case nil: ""
        case _ where isCancelling: String(localized: "Cancelling…", bundle: #bundle)
        case .preparing: String(localized: "Preparing…", bundle: #bundle)
        case .rendering: String(localized: "Rendering…", bundle: #bundle)
        case .creatingLivePhoto: String(localized: "Creating Live Photo…", bundle: #bundle)
        case .saving:
            destination == .photos ? String(localized: "Saving to Photos…", bundle: #bundle) : String(localized: "Saving Files…", bundle: #bundle)
        }
    }

    /// Exports `plan` as a Live Photo or a video; returns once it is in Photos or the folder, or the export has ended
    /// otherwise.
    public func run(_ destination: Destination, plan: EditPlan, source: SourceMedia, name: String,
                    as kind: Kind = .livePhoto) async -> Outcome {
        guard task == nil else { return .failed }
        self.destination = destination
        stage = .preparing
        failure = nil
        let task = Task { await perform(destination, plan: plan, source: source, name: name, kind: kind) }
        self.task = task
        let outcome = await task.value
        self.task = nil
        self.destination = nil
        stage = nil
        isCancelling = false
        return outcome
    }

    /// Stops the export unless it is already saving.
    public func cancel() {
        guard canCancel else { return }
        isCancelling = true
        task?.cancel()
    }

    /// Waits for the export in progress, if any, to end.
    public func waitUntilFinished() async {
        _ = await task?.value
    }

    // MARK: - Stages

    private func perform(_ destination: Destination, plan: EditPlan, source: SourceMedia, name: String, kind: Kind) async -> Outcome {
        let staging = TemporaryFiles.exports.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: staging) }
        do {
            if destination == .photos {
                // Asking before rendering means a refusal costs the user nothing.
                try DebugHooks.simulateFailure(at: .photosAccess)
                try await PhotosLibrarySaver.ensureAddAccess()
            }
            if case let .video(keepsFrameTiming, audio) = kind {
                try await performVideo(destination, plan: plan, source: source, name: name, keepsFrameTiming: keepsFrameTiming,
                                       audio: audio, in: staging)
                return .saved(destination)
            }
            let baseName = switch destination {
            case .photos: "LivePhoto"
            case let .folder(url): url.lastPathComponent
            }
            let pair = try await LivePhotoExporter().export(
                plan, source: source, to: staging, baseName: baseName, verifiesPairing: true,
                progress: progressHandler()
            )
            try DebugHooks.simulateFailure(at: .render)
            try Task.checkCancellation()

            stage = .saving
            switch destination {
            case .photos:
                try DebugHooks.simulateFailure(at: .photosSave)
                try await PhotosLibrarySaver.save(pair, originalFilename: Self.photosFilename(for: name))
            case let .folder(folder):
                _ = try LivePhotoExporter().deliver(pair, toNewFolder: folder)
            }
            return .saved(destination)
        } catch is CancellationError {
            return .cancelled
        } catch {
            Self.log.error("Export failed: \(String(describing: error), privacy: .public)")
            #if DEBUG
            // The alert shows only the description; the codes say which part of AVFoundation gave up.
            PlaybackRecorder.note("export failed: \(String(describing: error))")
            #endif
            failure = ExportFailure(error, destination: destination, source: source, isVideo: kind != .livePhoto)
            return .failed
        }
    }

    /// A plain movie, named after the video, into Photos or a new folder of its own.
    private func performVideo(_ destination: Destination, plan: EditPlan, source: SourceMedia, name: String,
                              keepsFrameTiming: Bool, audio: CompressionSource.Audio?, in staging: URL) async throws {
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let baseName = switch destination {
        case .photos: "Video"
        case let .folder(url): url.lastPathComponent
        }
        let video = try await VideoExporter().export(
            plan, keepsFrameTiming: keepsFrameTiming, audio: audio, source: source,
            to: staging.appending(path: "\(baseName).MOV"), progress: videoProgressHandler()
        )
        try DebugHooks.simulateFailure(at: .render)
        try Task.checkCancellation()

        stage = .saving
        switch destination {
        case .photos:
            try DebugHooks.simulateFailure(at: .photosSave)
            try await PhotosLibrarySaver.saveVideo(at: video.url, originalFilename: Self.photosFilename(for: name, isVideo: true),
                                                   creationDate: video.captureDate, location: video.location)
        case let .folder(folder):
            // As for a Live Photo's pair: never into a folder that's there already.
            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: folder.path) { throw LivePhotoExportError.destinationExists(folder) }
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: false)
            try fileManager.moveItem(at: video.url, to: folder.appending(path: video.url.lastPathComponent))
        }
    }

    private func videoProgressHandler() -> @Sendable (VideoExportStage) -> Void {
        let frameDelay = DebugHooks.frameDelay
        return { [weak self] stage in
            if let frameDelay { Thread.sleep(forTimeInterval: frameDelay) }
            Task { @MainActor in
                guard let self, let current = self.stage else { return }
                let next: Stage = switch stage {
                case .preparing: .preparing
                case let .compressing(fraction): .rendering(fraction)
                case .finishing: .rendering(1)
                }
                if Self.order(of: next) >= Self.order(of: current) { self.stage = next }
            }
        }
    }

    private func progressHandler() -> @Sendable (LivePhotoExportStage) -> Void {
        let frameDelay = DebugHooks.frameDelay
        return { [weak self] stage in
            if let frameDelay { Thread.sleep(forTimeInterval: frameDelay) }
            Task { @MainActor in
                guard let self, let current = self.stage else { return }
                let next: Stage = switch stage {
                case .preparing: .preparing
                case let .rendering(fraction): .rendering(fraction)
                case .creatingLivePhoto: .creatingLivePhoto
                }
                // Updates hop to the main actor one by one; never let a late one move the bar backwards.
                if Self.order(of: next) >= Self.order(of: current) { self.stage = next }
            }
        }
    }

    private static func order(of stage: Stage) -> Double {
        switch stage {
        case .preparing: 0
        case let .rendering(fraction): 1 + fraction
        case .creatingLivePhoto: 3
        case .saving: 4
        }
    }

    // MARK: - Naming

    /// Development builds name Photos resources so test assets are easy to find; release
    /// builds keep the video’s own name, as iPhone does for a Live Photo’s two resources.
    private static func photosFilename(for sourceName: String, isVideo: Bool = false) -> String {
        #if DEBUG
        let stamp = Date.now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: "")
        return "StillTest-\(stamp)"
        #else
        let base = (sourceName as NSString).deletingPathExtension
        guard base.isEmpty else { return base }
        return isVideo ? String(localized: "Video", bundle: #bundle) : String(localized: "Live Photo", bundle: #bundle)
        #endif
    }
}

/// An export that failed, described for the user with what they can do next.
public struct ExportFailure: Identifiable {
    public enum Recovery: Hashable, Identifiable {
        case tryAgain
        case exportFiles
        case openPhotosSettings
        case chooseAnotherName

        public var id: Self { self }

        public var title: String {
            switch self {
            case .tryAgain: String(localized: "Try Again", bundle: #bundle)
            case .exportFiles: ExportFailure.exportFilesTitle
            case .openPhotosSettings: ExportFailure.openSettingsTitle
            case .chooseAnotherName: String(localized: "Choose Another Name…", bundle: #bundle)
            }
        }
    }

    public let id = UUID()
    public let destination: ExportController.Destination
    public let title: String
    public let message: String
    /// The first is the default action. Every alert also offers Cancel, and the edit is always kept.
    public let recoveries: [Recovery]

    public init(destination: ExportController.Destination, title: String, message: String, recoveries: [Recovery]) {
        self.destination = destination
        self.title = title
        self.message = message
        self.recoveries = recoveries
    }

    public init(_ error: Error, destination: ExportController.Destination, source: SourceMedia, isVideo: Bool = false) {
        let toPhotos = destination == .photos
        let alternative: [Recovery] = toPhotos ? [.exportFiles] : []

        if case PhotosSaveError.accessDenied = error {
            self.init(
                destination: destination,
                title: String(localized: "Still can’t add to your Photos library", bundle: #bundle),
                message: String(localized: "\(Self.photosPermissionHint) You can also export the files and import them into Photos yourself.", bundle: #bundle),
                recoveries: [.openPhotosSettings, .exportFiles]
            )
        } else if Self.isOutOfSpace(error) {
            self.init(
                destination: destination,
                title: String(localized: "There isn’t enough disk space", bundle: #bundle),
                message: String(localized: "Free up some space, then try again.", bundle: #bundle),
                recoveries: [.tryAgain] + alternative
            )
        } else if !FileManager.default.fileExists(atPath: source.url.path) {
            self.init(
                destination: destination,
                title: String(localized: "“\(source.url.lastPathComponent)” is no longer available", bundle: #bundle),
                message: String(localized: "The video may have been moved or deleted, or its disk disconnected. Put it back, or reconnect the disk, and try again.", bundle: #bundle),
                recoveries: [.tryAgain]
            )
        } else if case let LivePhotoExportError.destinationExists(url) = error {
            self.init(
                destination: destination,
                title: String(localized: "“\(url.lastPathComponent)” already exists", bundle: #bundle),
                message: String(localized: "Still never replaces existing files. Choose another name or location.", bundle: #bundle),
                recoveries: [.chooseAnotherName]
            )
        } else if !toPhotos, Self.isPermissionProblem(error) {
            self.init(
                destination: destination,
                title: String(localized: "Still can’t save files there", bundle: #bundle),
                message: String(localized: "You may not have permission to write to that location, or the disk is read-only. Choose another location.", bundle: #bundle),
                recoveries: [.chooseAnotherName]
            )
        } else if toPhotos, error is PhotosSaveError {
            self.init(
                destination: destination,
                title: isVideo
                    ? String(localized: "Photos couldn’t save the video", bundle: #bundle)
                    : String(localized: "Photos couldn’t save the Live Photo", bundle: #bundle),
                message: Self.detail(of: error, fallback: String(localized: "Try again, or export the files and import them into Photos yourself.", bundle: #bundle)),
                recoveries: [.tryAgain, .exportFiles]
            )
        } else {
            self.init(
                destination: destination,
                title: isVideo
                    ? String(localized: "The video couldn’t be created", bundle: #bundle)
                    : String(localized: "The Live Photo couldn’t be created", bundle: #bundle),
                message: Self.detail(of: error, fallback: String(localized: "Try again. Your edits are unchanged.", bundle: #bundle)),
                recoveries: [.tryAgain] + alternative
            )
        }
    }

    // Where each platform keeps the Photos permission, and what its export of the pair is called.
    #if os(macOS)
    static let openSettingsTitle = String(localized: "Open System Settings", bundle: #bundle)
    static let exportFilesTitle = String(localized: "Export Files…", bundle: #bundle)
    static let photosPermissionHint = String(localized: "Allow Still in System Settings › Privacy & Security › Photos.", bundle: #bundle)
    #else
    static let openSettingsTitle = String(localized: "Open Settings", bundle: #bundle)
    static let exportFilesTitle = String(localized: "Share Files…", bundle: #bundle)
    static let photosPermissionHint = String(localized: "Allow Still to add photos in Settings › Apps › Still › Photos.", bundle: #bundle)
    #endif

    private static func detail(of error: Error, fallback: String) -> String {
        let description = (error as? LocalizedError)?.errorDescription ?? (error as NSError).localizedDescription
        if case let PhotosSaveError.saveFailed(underlying?) = error {
            return "\(underlying.localizedDescription) \(fallback)"
        }
        return description.isEmpty ? fallback : "\(description) \(fallback)"
    }

    /// Looks through underlying errors too: AVFoundation and Photos wrap the file system’s answer.
    private static func underlyingErrors(_ error: Error) -> [NSError] {
        var chain: [NSError] = []
        var next: NSError? = error as NSError
        while let current = next, chain.count < 8 {
            chain.append(current)
            next = current.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return chain
    }

    private static func isOutOfSpace(_ error: Error) -> Bool {
        if (error as? PhotosSaveError)?.photosErrorCode == .notEnoughSpace { return true }
        return underlyingErrors(error).contains { error in
            (error.domain == NSCocoaErrorDomain && error.code == NSFileWriteOutOfSpaceError)
                || (error.domain == AVFoundationErrorDomain && error.code == AVError.diskFull.rawValue)
                || (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOSPC))
        }
    }

    private static func isPermissionProblem(_ error: Error) -> Bool {
        underlyingErrors(error).contains { error in
            (error.domain == NSCocoaErrorDomain && [NSFileWriteNoPermissionError, NSFileWriteVolumeReadOnlyError].contains(error.code))
                || (error.domain == NSPOSIXErrorDomain && [Int(EACCES), Int(EPERM), Int(EROFS)].contains(error.code))
        }
    }
}
