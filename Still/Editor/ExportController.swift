import AppKit
import AVFoundation
import Observation
import OSLog
import Photos
import StillCore

/// Runs one export at a time for an editor window, with stages, cancellation, and recovery.
///
/// Every export renders into a private staging folder first. Only a finished, verified pair is handed to
/// Photos or moved into the user’s folder, so a cancelled or failed export never leaves a partial result
/// where the user would find it.
@Observable
final class ExportController {
    enum Destination: Equatable {
        case photos
        /// A new folder the user named; it must not exist yet.
        case folder(URL)
    }

    enum Stage: Equatable {
        case preparing
        case rendering(Double)
        case creatingLivePhoto
        /// Handing the pair to Photos, or moving it into the folder. This can no longer be cancelled.
        case saving
    }

    enum Outcome: Equatable {
        case saved(Destination)
        case cancelled
        case failed
    }

    private(set) var destination: Destination?
    private(set) var stage: Stage?
    /// Cancel was requested; the current stage is winding down.
    private(set) var isCancelling = false
    /// The last failure, until the user dismisses it.
    var failure: ExportFailure?

    @ObservationIgnored private var task: Task<Outcome, Never>?
    private static let log = Logger(subsystem: "com.chen.Still", category: "export")

    var isRunning: Bool { stage != nil }

    var canCancel: Bool {
        guard let stage else { return false }
        return stage != .saving && !isCancelling
    }

    /// Overall progress, weighted by how long each stage usually takes.
    var progress: Double {
        switch stage {
        case nil, .preparing: 0.02
        case let .rendering(fraction): 0.02 + 0.88 * fraction
        case .creatingLivePhoto: 0.92
        case .saving: 0.97
        }
    }

    var stageTitle: String {
        switch stage {
        case nil: ""
        case _ where isCancelling: "Cancelling…"
        case .preparing: "Preparing…"
        case .rendering: "Rendering…"
        case .creatingLivePhoto: "Creating Live Photo…"
        case .saving: destination == .photos ? "Saving to Photos…" : "Saving Files…"
        }
    }

    /// Exports `plan`; returns once the pair is in Photos or the folder, or the export has ended otherwise.
    func run(_ destination: Destination, plan: EditPlan, source: SourceMedia, name: String) async -> Outcome {
        guard task == nil else { return .failed }
        self.destination = destination
        stage = .preparing
        failure = nil
        let task = Task { await perform(destination, plan: plan, source: source, name: name) }
        self.task = task
        let outcome = await task.value
        self.task = nil
        self.destination = nil
        stage = nil
        isCancelling = false
        return outcome
    }

    /// Stops the export unless it is already saving.
    func cancel() {
        guard canCancel else { return }
        isCancelling = true
        task?.cancel()
    }

    /// Waits for the export in progress, if any, to end.
    func waitUntilFinished() async {
        _ = await task?.value
    }

    // MARK: - Stages

    private func perform(_ destination: Destination, plan: EditPlan, source: SourceMedia, name: String) async -> Outcome {
        let staging = TemporaryFiles.exports.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: staging) }
        do {
            if destination == .photos {
                // Asking before rendering means a refusal costs the user nothing.
                try DebugHooks.simulateFailure(at: .photosAccess)
                try await PhotosLibrarySaver.ensureAddAccess()
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
            failure = ExportFailure(error, destination: destination, source: source)
            return .failed
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
    private static func photosFilename(for sourceName: String) -> String {
        #if DEBUG
        let stamp = Date.now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: "")
        return "StillTest-\(stamp)"
        #else
        let base = (sourceName as NSString).deletingPathExtension
        return base.isEmpty ? "Live Photo" : base
        #endif
    }
}

/// An export that failed, described for the user with what they can do next.
struct ExportFailure: Identifiable {
    enum Recovery: Hashable, Identifiable {
        case tryAgain
        case exportFiles
        case openPhotosSettings
        case chooseAnotherName

        var id: Self { self }

        var title: String {
            switch self {
            case .tryAgain: "Try Again"
            case .exportFiles: "Export Files…"
            case .openPhotosSettings: "Open System Settings"
            case .chooseAnotherName: "Choose Another Name…"
            }
        }
    }

    let id = UUID()
    let destination: ExportController.Destination
    let title: String
    let message: String
    /// The first is the default action. Every alert also offers Cancel, and the edit is always kept.
    let recoveries: [Recovery]

    init(destination: ExportController.Destination, title: String, message: String, recoveries: [Recovery]) {
        self.destination = destination
        self.title = title
        self.message = message
        self.recoveries = recoveries
    }

    init(_ error: Error, destination: ExportController.Destination, source: SourceMedia) {
        let toPhotos = destination == .photos
        let alternative: [Recovery] = toPhotos ? [.exportFiles] : []

        if case PhotosSaveError.accessDenied = error {
            self.init(
                destination: destination,
                title: "Still can’t add to your Photos library",
                message: "Allow Still in System Settings › Privacy & Security › Photos. You can also export the files and import them into Photos yourself.",
                recoveries: [.openPhotosSettings, .exportFiles]
            )
        } else if Self.isOutOfSpace(error) {
            self.init(
                destination: destination,
                title: "There isn’t enough disk space",
                message: "Free up some space, then try again.",
                recoveries: [.tryAgain] + alternative
            )
        } else if !FileManager.default.fileExists(atPath: source.url.path) {
            self.init(
                destination: destination,
                title: "“\(source.url.lastPathComponent)” is no longer available",
                message: "The video may have been moved or deleted, or its disk disconnected. Put it back, or reconnect the disk, and try again.",
                recoveries: [.tryAgain]
            )
        } else if case let LivePhotoExportError.destinationExists(url) = error {
            self.init(
                destination: destination,
                title: "“\(url.lastPathComponent)” already exists",
                message: "Still never replaces existing files. Choose another name or location.",
                recoveries: [.chooseAnotherName]
            )
        } else if !toPhotos, Self.isPermissionProblem(error) {
            self.init(
                destination: destination,
                title: "Still can’t save files there",
                message: "You may not have permission to write to that location, or the disk is read-only. Choose another location.",
                recoveries: [.chooseAnotherName]
            )
        } else if toPhotos, error is PhotosSaveError {
            self.init(
                destination: destination,
                title: "Photos couldn’t save the Live Photo",
                message: Self.detail(of: error, fallback: "Try again, or export the files and import them into Photos yourself."),
                recoveries: [.tryAgain, .exportFiles]
            )
        } else {
            self.init(
                destination: destination,
                title: "The Live Photo couldn’t be created",
                message: Self.detail(of: error, fallback: "Try again. Your edits are unchanged."),
                recoveries: [.tryAgain] + alternative
            )
        }
    }

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
