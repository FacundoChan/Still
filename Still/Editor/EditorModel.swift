import AppKit
import AVFoundation
import Observation
import PhotosUI
import StillCore
import SwiftUI

/// One editor window’s state: the source, the authoritative `EditState`, undo, playback, and export.
@Observable
final class EditorModel {
    enum Phase: Equatable {
        case empty
        case loading
        case ready
        case failed(String)
    }

    private(set) var phase = Phase.empty
    private(set) var source: SourceMedia?
    private(set) var sourceName = ""
    private(set) var state: EditState?
    /// Source seconds.
    private(set) var playhead = 0.0
    private(set) var notice: String?
    /// The edit as it was when the video opened or was last saved or exported.
    private(set) var savedState: EditState?

    var isCropMode = false {
        didSet {
            guard isCropMode != oldValue else { return }
            refreshSourcePreview()
        }
    }

    var isImporterPresented = false
    var isPhotosPickerPresented = false
    var photosSelection: PhotosPickerItem? {
        didSet {
            guard let item = photosSelection else { return }
            photosSelection = nil
            Task { await importFromPhotos(item) }
        }
    }

    /// The detail strip’s range while a drag holds it still, so the strip doesn’t slide under the pointer.
    var frozenDetailRange: ClosedRange<Double>?

    let playback = PlaybackController()
    let livePreview = LivePhotoPreviewRenderer()
    let thumbnails = ThumbnailProvider()
    let export = ExportController()

    @ObservationIgnored weak var undoManager: UndoManager?
    @ObservationIgnored weak var coordinator: WindowCoordinator?
    /// The window showing this editor, for sheets.
    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored private var interactionStart: EditState?
    @ObservationIgnored private var interactionNotice: EditNotice?
    @ObservationIgnored private var accessedURL: URL?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var selectionPreviewTask: Task<Void, Never>?
    @ObservationIgnored private var previewAudioURL: URL?

    init() {
        playback.onPlaybackTime = { [weak self] time in
            self?.playhead = time
        }
    }

    // MARK: - Derived

    var isEmpty: Bool {
        switch phase {
        case .empty, .failed: true
        case .loading, .ready: false
        }
    }

    var title: String { sourceName.isEmpty ? "Still" : sourceName }

    var subtitle: String {
        guard let source else { return "" }
        let seconds = Int(source.duration.seconds.rounded())
        let fps = Double(source.nominalFrameRate)
        let rate = fps.rounded() == fps ? String(Int(fps)) : String(format: "%.2f", fps)
        return String(format: "%d:%02d · %@ fps", seconds / 60, seconds % 60, rate)
    }

    var canExport: Bool {
        phase == .ready && state?.exportIssue == nil && !export.isRunning
    }

    /// Edits made since the video opened or was last saved or exported; undoing back to that point clears it.
    var hasUnsavedChanges: Bool {
        state != nil && state != savedState
    }

    /// What the stage shows: the full frame while cropping, otherwise the exported framing.
    var stageContentSize: CGSize {
        guard let state else { return CGSize(width: 16, height: 9) }
        return isCropMode ? state.source.orientedSize : state.outputGeometry.renderSize
    }

    var detailRange: ClosedRange<Double> {
        if let frozenDetailRange { return frozenDetailRange }
        guard let state else { return 0...1 }
        return TimelineWindow.detailRange(
            selection: state.selectionStart...state.selectionEnd,
            playhead: playhead,
            sourceDuration: state.source.duration
        )
    }

    // MARK: - Opening

    func load(_ url: URL) async {
        phase = .loading
        accessedURL?.stopAccessingSecurityScopedResource()
        accessedURL = url.startAccessingSecurityScopedResource() ? url : nil
        do {
            let media = try await SourceMedia.load(url)
            var initial = try EditState(source: media.info)
            Self.applyRememberedOutput(to: &initial)
            if let previous = source, previous.url != url { TemporaryFiles.removeImportedCopy(previous.url) }
            source = media
            sourceName = url.lastPathComponent
            state = initial
            savedState = initial
            playhead = 0
            isCropMode = false
            undoManager?.removeAllActions()
            livePreview.reset()
            thumbnails.reset()
            phase = .ready
            refreshSourcePreview()
            scheduleRenders()
        } catch {
            source = nil
            state = nil
            savedState = nil
            TemporaryFiles.removeImportedCopy(url)
            phase = .failed(error.localizedDescription)
        }
    }

    func requestOpen(_ url: URL) {
        if let coordinator {
            coordinator.open(url, preferring: self)
        } else {
            Task { await load(url) }
        }
    }

    private func importFromPhotos(_ item: PhotosPickerItem) async {
        do {
            guard let movie = try await item.loadTransferable(type: PickedMovie.self) else { return }
            requestOpen(movie.url)
        } catch {
            reportImportFailure("The video couldn’t be imported from Photos. \(error.localizedDescription)")
        }
    }

    /// An empty window explains in place; a window with a video keeps it and shows a notice.
    func reportImportFailure(_ message: String) {
        if isEmpty { phase = .failed(message) } else { show(message) }
    }

    // MARK: - Editing

    /// Applies one undoable edit. Rejected edits leave the state alone and explain why.
    func edit(_ actionName: String, _ change: (inout EditState) throws -> Void) {
        guard let current = state else { return }
        var next = current
        do {
            try change(&next)
        } catch {
            show(error.localizedDescription)
            return
        }
        guard next != current else { return }
        state = next
        registerUndo(restoring: current, actionName: actionName)
        didCommit(from: current)
    }

    /// Starts a continuous gesture; everything until `endInteraction` is one undo step.
    func beginInteraction() {
        if interactionStart == nil { interactionStart = state }
    }

    func interact(_ change: (inout EditState) -> EditNotice?) {
        guard var next = state else { return }
        if let notice = change(&next) { interactionNotice = notice }
        if next != state { state = next }
    }

    func endInteraction(_ actionName: String) {
        defer {
            interactionStart = nil
            interactionNotice = nil
            frozenDetailRange = nil
        }
        guard let start = interactionStart, let state, state != start else { return }
        registerUndo(restoring: start, actionName: actionName)
        if let interactionNotice { show(interactionNotice.message) }
        didCommit(from: start)
    }

    private func registerUndo(restoring snapshot: EditState, actionName: String) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.restore(snapshot, actionName: actionName) }
        }
        undoManager.setActionName(actionName)
    }

    private func restore(_ snapshot: EditState, actionName: String) {
        guard let current = state else { return }
        state = snapshot
        registerUndo(restoring: current, actionName: actionName)
        didCommit(from: current)
    }

    private func didCommit(from previous: EditState) {
        guard let state else { return }
        if previous.cropRect != state.cropRect && !isCropMode {
            refreshSourcePreview()
        }
        // The stage previews at a fixed size, so a new resolution or bit rate changes only the Live Photo
        // preview, and playback carries on.
        var unchanged = previous.plan
        unchanged.output = state.output
        scheduleRenders(includingSelection: unchanged != state.plan)
    }

    // MARK: - Commands

    /// Make Key Photo: the playhead’s frame becomes the Key Photo, and the selection comes to it
    /// if it is outside.
    func makeKeyPhoto() {
        edit("Make Key Photo") { $0.makeKeyPhoto(at: playhead) }
    }

    /// Shows the Key Photo on the stage, at full resolution and with the exported framing.
    func showKeyPhoto() {
        guard let state else { return }
        playback.pause()
        scrub(to: state.keyPhotoTime)
    }

    /// Whether the stage is showing the Key Photo frame, so it can say so.
    var isShowingKeyPhoto: Bool {
        guard let state, phase == .ready, !playback.isPlaying, !livePreview.isPlaying, !isCropMode,
              state.isInsideSelection(playhead) else { return false }
        return !offersMakeKeyPhoto
    }

    /// The Make Key Photo bubble shows while paused on any frame but the Key Photo, as in Photos on iPhone.
    var offersMakeKeyPhoto: Bool {
        guard let state, phase == .ready, !playback.isPlaying, !livePreview.isPlaying else { return false }
        // Offered only when it would change something: the Key Photo resolves to the nearest rendered frame.
        var made = state
        made.makeKeyPhoto(at: playhead)
        return made.plan.keyPhotoFrameIndex != state.plan.keyPhotoFrameIndex || made.selectionStart != state.selectionStart
    }

    func setStartAtPlayhead() {
        var notice: EditNotice?
        edit("Set Start") { notice = $0.setSelectionStart(playhead) }
        if let notice { show(notice.message) }
    }

    func setEndAtPlayhead() {
        var notice: EditNotice?
        edit("Set End") { notice = $0.setSelectionEnd(playhead) }
        if let notice { show(notice.message) }
    }

    func setSelectionStart(_ time: Double) {
        var notice: EditNotice?
        edit("Set Start") { notice = $0.setSelectionStart(time) }
        if let notice { show(notice.message) }
    }

    func setSelectionEnd(_ time: Double) {
        var notice: EditNotice?
        edit("Set End") { notice = $0.setSelectionEnd(time) }
        if let notice { show(notice.message) }
    }

    func setSpeed(_ speed: Double) {
        var notice: EditNotice?
        edit("Change Speed") { notice = try $0.setSpeed(speed) }
        if let notice { show(notice.message) }
    }

    func setOutputDuration(_ target: Double) {
        edit("Change Duration") { try $0.setOutputDuration(target) }
    }

    func setIncludesAudio(_ include: Bool) {
        edit(include ? "Turn Sound On" : "Turn Sound Off") { $0.setIncludesAudio(include) }
    }

    func setResolution(_ resolution: OutputResolution) {
        edit("Change Resolution") { $0.setResolution(resolution) }
        UserDefaults.standard.set(resolution.rawValue, forKey: Self.resolutionKey)
    }

    func setBitRate(_ bitRate: VideoBitRate) {
        edit("Change Bit Rate") { $0.setBitRate(bitRate) }
        UserDefaults.standard.set(bitRate.rawValue, forKey: Self.bitRateKey)
    }

    /// New videos start with the resolution and bit rate chosen last.
    private static func applyRememberedOutput(to state: inout EditState) {
        let defaults = UserDefaults.standard
        if let resolution = defaults.string(forKey: resolutionKey).flatMap(OutputResolution.init(rawValue:)) {
            state.setResolution(resolution)
        }
        if let bitRate = defaults.string(forKey: bitRateKey).flatMap(VideoBitRate.init(rawValue:)) {
            state.setBitRate(bitRate)
        }
    }

    private static let resolutionKey = "OutputResolution"
    private static let bitRateKey = "VideoBitRate"

    /// Choosing a ratio enters Crop mode.
    func setCropAspect(_ aspect: CropAspect) {
        edit("Change Crop Ratio") { try $0.setCropAspect(aspect) }
        isCropMode = true
    }

    func setCropRect(_ rect: CGRect) {
        edit("Adjust Crop") { $0.setCropRect(rect) }
    }

    func resetCrop() {
        edit("Reset Crop") { $0.resetCrop() }
    }

    /// Arrow keys in Crop mode: one source pixel, or ten with Shift.
    func nudgeCrop(dx: Double, dy: Double) {
        guard let state else { return }
        let size = state.source.orientedSize
        edit("Nudge Crop") {
            $0.setCropRect(state.cropRect.offsetBy(dx: dx / size.width, dy: dy / size.height))
        }
    }

    // MARK: - Playback and playhead

    /// Moves the playhead and shows that source frame, paused.
    func scrub(to time: Double) {
        guard let state else { return }
        playhead = min(max(time, 0), state.source.duration)
        playback.show(sourceTime: playhead)
    }

    /// Shows a frame during a drag without moving the playhead, such as the edge being trimmed.
    func preview(sourceTime time: Double) {
        playback.show(sourceTime: time)
    }

    func togglePlayback() {
        guard let state else { return }
        if playback.isPlaying {
            playback.pause()
            playback.show(sourceTime: playhead)
        } else if state.isInsideSelection(playhead) {
            // From the end of the selection, start over.
            let start = playhead >= state.keyPhotoRange.upperBound ? state.selectionStart : playhead
            playback.playSelection(fromSourceTime: start)
        } else {
            playback.playSource(from: playhead)
        }
    }

    /// Left and Right: rendered output frames inside the selection, source frames outside it.
    func step(_ frames: Int) {
        guard let state else { return }
        playback.pause()
        if state.isInsideSelection(playhead) {
            let index = state.outputFrame(atSourceTime: playhead) + Int64(frames)
            let last = state.plan.outputFrameCount - 1
            if index >= 0 && index <= last {
                scrub(to: state.sourceTime(ofOutputFrame: index))
                return
            }
        }
        let frameDuration = 1 / max(state.source.frameRate, 1)
        scrub(to: playhead + Double(frames) * frameDuration)
    }

    func previewLivePhoto() {
        guard state?.exportIssue == nil else {
            if let issue = state?.exportIssue?.errorDescription { show(issue) }
            return
        }
        playback.pause()
        livePreview.play()
    }

    // MARK: - Keyboard

    /// Single-key shortcuts arrive here only when no text field has focus, so they never fire while typing.
    func handleKey(_ press: KeyPress) -> Bool {
        guard phase == .ready else { return false }
        // Arrow keys also carry the numeric-pad and function flags, so only ⌘, ⌥, and ⌃ disqualify a press;
        // those belong to menu shortcuts.
        guard press.modifiers.isDisjoint(with: [.command, .option, .control]) else { return false }
        let large = press.modifiers.contains(.shift)
        switch press.key {
        case .space:
            togglePlayback()
        case .return:
            if isCropMode { isCropMode = false } else { makeKeyPhoto() }
        case .escape:
            if livePreview.isPlaying { livePreview.stop() } else if isCropMode { isCropMode = false } else { return false }
        case .leftArrow:
            isCropMode ? nudgeCrop(dx: large ? -10 : -1, dy: 0) : step(large ? -10 : -1)
        case .rightArrow:
            isCropMode ? nudgeCrop(dx: large ? 10 : 1, dy: 0) : step(large ? 10 : 1)
        case .upArrow:
            guard isCropMode else { return false }
            nudgeCrop(dx: 0, dy: large ? -10 : -1)
        case .downArrow:
            guard isCropMode else { return false }
            nudgeCrop(dx: 0, dy: large ? 10 : 1)
        default:
            guard !large else { return false }
            switch press.characters.lowercased() {
            case "c": isCropMode.toggle()
            case "k": makeKeyPhoto()
            case "i": setStartAtPlayhead()
            case "o": setEndAtPlayhead()
            case "l": previewLivePhoto()
            default: return false
            }
        }
        return true
    }

    // MARK: - Notices

    func show(_ message: String) {
        notice = message
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    // MARK: - Previews

    /// The stage players render at most 1080p, whatever the output resolution. The framing is the same, and
    /// 4K compositions would play less smoothly for no visible gain in the window.
    private static let stageLongEdge = OutputResolution.fullHD.maxLongEdge

    /// The source player shows the whole clip at 1×: full frame in Crop mode, otherwise the exported crop.
    private func refreshSourcePreview() {
        guard let source, let state else { return }
        var output = state.output
        output.maxLongEdge = min(output.maxLongEdge, Self.stageLongEdge)
        output.frameRate = Int32(min(120, max(30, state.source.frameRate.rounded())))
        output.durationRange = 0...Double.greatestFiniteMagnitude
        let plan = EditPlan(
            selection: CMTimeRange(start: .zero, duration: source.duration),
            keyPhotoSourceTime: .zero,
            includesAudio: state.includesAudio,
            crop: isCropMode ? CropGeometry.fullFrame : state.cropRect,
            output: output
        )
        guard let graph = try? RenderPipeline.build(source: source, plan: plan) else { return }
        playback.setSourceItem(graph.makePlayerItem(), showing: playhead)
    }

    /// Rebuilds the selection player and the Live Photo preview once edits settle.
    private func scheduleRenders(includingSelection: Bool = true) {
        guard let source, let state else { return }
        livePreview.schedule(state.plan, source: source)
        guard includingSelection else { return }
        selectionPreviewTask?.cancel()
        var plan = state.plan
        plan.output.maxLongEdge = min(plan.output.maxLongEdge, Self.stageLongEdge)
        selectionPreviewTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await self?.buildSelectionPreview(plan, source: source)
        }
    }

    private func buildSelectionPreview(_ plan: EditPlan, source: SourceMedia) async {
        guard let graph = try? RenderPipeline.build(source: source, plan: plan) else { return }
        let audioURL = TemporaryFiles.previews.appending(path: "audio-\(UUID().uuidString).caf")
        try? FileManager.default.createDirectory(at: audioURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let wroteAudio = await Task.detached(priority: .userInitiated) {
            (try? graph.writeRetimedAudio(to: audioURL)) ?? false
        }.value
        guard !Task.isCancelled else {
            try? FileManager.default.removeItem(at: audioURL)
            return
        }
        // If the retimed sound can't be used, AVFoundation's own time-pitch is a better fallback than silence.
        let preview = (try? await RenderPipeline.buildPreview(source: source, plan: plan, retimedAudio: wroteAudio ? audioURL : nil)) ?? graph
        playback.setSelectionItem(preview.makePlayerItem(), start: plan.selection.start.seconds, speed: plan.speed)
        if let previewAudioURL { try? FileManager.default.removeItem(at: previewAudioURL) }
        previewAudioURL = wroteAudio ? audioURL : nil
    }

    // MARK: - Export

    func saveToPhotos() {
        guard canExport, let state else { return }
        startExport(.photos, of: state)
    }

    /// Asks for a new folder’s name and location, then exports the pair into it.
    func exportFiles() async {
        guard canExport, let state, let folder = await chooseExportFolder() else { return }
        startExport(.folder(folder), of: state)
    }

    func cancelExport() {
        export.cancel()
    }

    func recover(_ recovery: ExportFailure.Recovery, from failure: ExportFailure) {
        export.failure = nil
        switch recovery {
        case .tryAgain:
            guard canExport, let state else { return }
            startExport(failure.destination, of: state)
        case .exportFiles, .chooseAnotherName:
            Task { await exportFiles() }
        case .openPhotosSettings:
            NSWorkspace.shared.open(Self.photosPrivacySettings)
        }
    }

    /// Exports `snapshot`, so edits made while it runs don’t change what is saved. Returns whether it saved.
    @discardableResult
    private func startExport(_ destination: ExportController.Destination, of snapshot: EditState) -> Task<Bool, Never> {
        playback.pause()
        livePreview.stop()
        return Task {
            guard let source else { return false }
            let outcome = await export.run(destination, plan: snapshot.plan, source: source, name: sourceName)
            guard case let .saved(destination) = outcome else { return false }
            savedState = snapshot
            switch destination {
            case .photos: show("Saved to Photos")
            case let .folder(folder): show("Exported “\(folder.lastPathComponent)”")
            }
            return true
        }
    }

    private func chooseExportFolder() async -> URL? {
        let panel = NSSavePanel()
        panel.title = "Export Live Photo Files"
        panel.message = "Creates a folder with a matched JPEG and MOV. Import both into Photos together to get a Live Photo; this isn’t a single-file format."
        panel.prompt = "Export"
        panel.nameFieldLabel = "Folder Name:"
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = Self.availableFolderName(
            (sourceName as NSString).deletingPathExtension + " Live Photo", in: panel.directoryURL
        )
        let validator = ExportFolderValidator()
        panel.delegate = validator
        let response = if let window { await panel.beginSheetModal(for: window) } else { await panel.begin() }
        withExtendedLifetime(validator) {}
        guard response == .OK, let folder = panel.url else { return nil }
        // Still never replaces files, even when the panel offered to.
        if FileManager.default.fileExists(atPath: folder.path) {
            export.failure = ExportFailure(
                destination: .folder(folder),
                title: "“\(folder.lastPathComponent)” already exists",
                message: "Still never replaces existing files. Choose another name or location.",
                recoveries: [.chooseAnotherName]
            )
            return nil
        }
        return folder
    }

    /// Suggests “Name 2”, “Name 3”, … when the panel’s folder already has “Name”, so exporting the same
    /// video again doesn’t start with a name that would be refused.
    private static func availableFolderName(_ base: String, in directory: URL?) -> String {
        guard let directory else { return base }
        var candidate = base
        var number = 2
        while FileManager.default.fileExists(atPath: directory.appending(path: candidate).path) && number < 100 {
            candidate = "\(base) \(number)"
            number += 1
        }
        return candidate
    }

    private static let photosPrivacySettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos")!

    // MARK: - Closing

    /// Closing needs the user’s say while edits are unsaved or an export is running.
    var needsCloseConfirmation: Bool {
        hasUnsavedChanges || export.isRunning
    }

    /// Asks before the window closes, or the app quits, while edits are unsaved or an export is running.
    /// Returns whether closing may go ahead.
    func confirmClose(quitting: Bool) async -> Bool {
        guard let window, needsCloseConfirmation else { return true }
        if export.isRunning {
            guard export.canCancel else {
                // A Photos commit can’t be called back; let it finish, then ask about anything still unsaved.
                await export.waitUntilFinished()
                return await confirmClose(quitting: quitting)
            }
            let alert = NSAlert()
            alert.messageText = "Stop saving this Live Photo?"
            alert.informativeText = quitting
                ? "It hasn’t finished saving. If you quit now, it won’t be saved."
                : "It hasn’t finished saving. If you close the window now, it won’t be saved."
            alert.addButton(withTitle: "Keep Saving")
            alert.addButton(withTitle: quitting ? "Stop and Quit" : "Stop and Close")
            guard await alert.beginSheetModal(for: window) == .alertSecondButtonReturn else { return false }
            export.cancel()
            await export.waitUntilFinished()
            return true
        }

        let alert = NSAlert()
        alert.messageText = "Do you want to save a Live Photo from “\(sourceName)”?"
        alert.informativeText = "Your edits will be lost if you don’t save them."
        let canSave = canExport
        if canSave { alert.addButton(withTitle: "Save to Photos") }
        alert.addButton(withTitle: "Cancel")
        let discard = alert.addButton(withTitle: "Don’t Save")
        discard.keyEquivalent = "d"
        discard.keyEquivalentModifierMask = .command
        let response = await alert.beginSheetModal(for: window)
        switch (canSave, response) {
        case (true, .alertFirstButtonReturn):
            guard let state else { return true }
            return await startExport(.photos, of: state).value
        case (true, .alertThirdButtonReturn), (false, .alertSecondButtonReturn):
            return true
        default:
            return false
        }
    }

    /// Releases what the window holds once it has closed: players, renders, and the app’s own copies of files.
    func close() {
        export.cancel()
        selectionPreviewTask?.cancel()
        noticeTask?.cancel()
        playback.tearDown()
        livePreview.reset()
        if let previewAudioURL { try? FileManager.default.removeItem(at: previewAudioURL) }
        previewAudioURL = nil
        if let source { TemporaryFiles.removeImportedCopy(source.url) }
        accessedURL?.stopAccessingSecurityScopedResource()
        accessedURL = nil
        undoManager?.removeAllActions(withTarget: self)
    }
}

/// Keeps the export panel open when the name is taken, instead of offering to replace it.
private final class ExportFolderValidator: NSObject, NSOpenSavePanelDelegate {
    func panel(_ sender: Any, validate url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteFileExistsError, userInfo: [
            NSLocalizedDescriptionKey: "“\(url.lastPathComponent)” already exists.",
            NSLocalizedRecoverySuggestionErrorKey: "Still never replaces existing files. Choose another name.",
        ])
    }
}

/// A video chosen with the system Photos picker, copied into the app’s temporary folder.
struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            let directory = try TemporaryFiles.makeItemFolder(in: TemporaryFiles.imports)
            let destination = directory.appending(path: received.file.lastPathComponent)
            try FileManager.default.copyItem(at: received.file, to: destination)
            return PickedMovie(url: destination)
        }
    }
}

extension FocusedValues {
    @Entry var editor: EditorModel?
}
