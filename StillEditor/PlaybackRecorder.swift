#if DEBUG
import AVFoundation
import Foundation
import QuartzCore

/// Debug builds only: notices when a playing video stops delivering pictures while its time and sound carry on, and
/// writes what the player reports to `StillPlayback.log` in the app's Documents folder.
///
/// Every play ends with a one-line summary of the frames that arrived, so a frozen picture shows whether the video
/// stopped decoding (few frames) or the screen stopped showing it (frames kept arriving). A stall of a second gets a
/// full report, and `PlaybackController` then tries to restart the picture, which is logged too.
final class PlaybackRecorder {
    enum Check {
        case fine
        /// No new frame for `stallLimit` while playing: try a seek in place.
        case stalled
        /// Still none `reloadLimit` after that: try a fresh item.
        case stillStalled
    }

    static let stallLimit: CFTimeInterval = 1.0
    static let reloadLimit: CFTimeInterval = 2.0

    /// The video being edited, for the log.
    var sourceName = ""

    private var outputs: [ObjectIdentifier: AVPlayerItemVideoOutput] = [:]
    private var lastFrameHost: CFTimeInterval?
    private var stalledSince: CFTimeInterval?
    private var triedReload = false
    private var session: Session?
    private var observers: [NSObjectProtocol] = []

    private struct Session {
        let name: String
        let from: Double
        let host: CFTimeInterval
        var frames = 0
        var stalls = 0
        let expectedRate: Double
    }

    init() {
        let center = NotificationCenter.default
        // Each notice becomes text where it arrives, so only the text crosses to the main actor.
        observers.append(center.addObserver(forName: AVPlayerItem.playbackStalledNotification, object: nil, queue: .main) { [weak self] note in
            let line = "notice: playback stalled \(Self.describe(note.object as? AVPlayerItem))"
            MainActor.assumeIsolated { self?.write(line) }
        })
        observers.append(center.addObserver(forName: AVPlayerItem.newErrorLogEntryNotification, object: nil, queue: .main) { [weak self] note in
            let item = note.object as? AVPlayerItem
            let last = item?.errorLog()?.events.last.map(Self.describe) ?? "no event"
            let line = "notice: error log entry \(Self.describe(item)): \(last)"
            MainActor.assumeIsolated { self?.write(line) }
        })
        observers.append(center.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] note in
            let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError
            let line = "notice: failed to play to end \(Self.describe(note.object as? AVPlayerItem)): \(Self.describe(error))"
            MainActor.assumeIsolated { self?.write(line) }
        })
    }

    isolated deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    // MARK: - Watching

    /// Taps `item`'s pictures, so the recorder can see whether they keep coming.
    func attach(to item: AVPlayerItem) {
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
        item.add(output)
        outputs[ObjectIdentifier(item)] = output
        // Players keep at most a few items; forget ones long replaced.
        if outputs.count > 8 { outputs.removeValue(forKey: outputs.keys.first!) }
    }

    func begin(_ name: String, player: AVPlayer, from time: Double) {
        end(at: time)
        let rate = Double(player.currentItem?.videoComposition.map { 1 / max($0.frameDuration.seconds, 0.001) } ?? 30)
        session = Session(name: name, from: time, host: CACurrentMediaTime(), expectedRate: rate)
        lastFrameHost = CACurrentMediaTime()
        stalledSince = nil
        triedReload = false
    }

    /// Writes the summary of the play that just ended.
    func end(at time: Double) {
        guard let session else { return }
        self.session = nil
        let seconds = CACurrentMediaTime() - session.host
        let expected = Int(seconds * session.expectedRate)
        let verdict = session.frames < expected / 2 ? "  ← FEW FRAMES" : ""
        write(String(format: "played %@ %@ → %@ (%.1f s): %d new frames of about %d, %d stall(s)%@",
                     session.name, Self.clock(session.from), Self.clock(time), seconds, session.frames, expected,
                     session.stalls, verdict))
    }

    /// Called on every playback tick for the player on screen.
    func check(_ player: AVPlayer, name: String, context: @autoclosure () -> String) -> Check {
        guard let item = player.currentItem, let output = outputs[ObjectIdentifier(item)] else { return .fine }
        let now = CACurrentMediaTime()
        let itemTime = output.itemTime(forHostTime: now)
        if output.hasNewPixelBuffer(forItemTime: itemTime),
           output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil) != nil {
            session?.frames += 1
            if let stalledSince {
                write(String(format: "RESUMED %@: pictures came back after %.1f s", name, now - stalledSince))
                self.stalledSince = nil
                triedReload = false
            }
            lastFrameHost = now
            return .fine
        }
        // Only time spent playing counts; a seek or a wait for data isn't a stall.
        guard player.timeControlStatus == .playing, player.rate != 0 else {
            lastFrameHost = now
            return .fine
        }
        let since = lastFrameHost ?? now
        if lastFrameHost == nil { lastFrameHost = now }
        if let stalledSince {
            guard !triedReload, now - stalledSince >= Self.reloadLimit else { return .fine }
            triedReload = true
            write("still no pictures from \(name); reloading its item")
            return .stillStalled
        }
        guard now - since >= Self.stallLimit else { return .fine }
        stalledSince = now
        session?.stalls += 1
        write(report(name: name, player: player, item: item, context: context()))
        write("trying: seek in place")
        return .stalled
    }

    func note(_ line: String) {
        write(line)
    }

    // MARK: - Report

    private func report(name: String, player: AVPlayer, item: AVPlayerItem, context: String) -> String {
        var lines = [String(format: "STALL %@ in “%@”: no new picture for %.1f s while playing at %@",
                            name, sourceName, Self.stallLimit, Self.clock(player.currentTime().seconds))]
        lines.append("  player: rate \(player.rate), status \(Self.describe(player.timeControlStatus)), "
            + "waiting \(player.reasonForWaitingToPlay?.rawValue ?? "none"), error \(Self.describe(player.error as NSError?))")
        lines.append("  item: \(Self.describe(item)), status \(item.status.rawValue), error \(Self.describe(item.error as NSError?)), "
            + "keeps up \(item.isPlaybackLikelyToKeepUp), buffer empty \(item.isPlaybackBufferEmpty), "
            + "size \(Int(item.presentationSize.width))×\(Int(item.presentationSize.height))")
        if let composition = item.videoComposition {
            lines.append(String(format: "  composition: %d×%d at %.2f fps, %d instruction(s)",
                                Int(composition.renderSize.width), Int(composition.renderSize.height),
                                1 / max(composition.frameDuration.seconds, 0.001), composition.instructions.count))
        }
        lines.append("  tracks: " + item.tracks.map { track in
            "\(track.assetTrack?.mediaType.rawValue ?? "?")\(track.isEnabled ? "" : " (off)")"
        }.joined(separator: ", "))
        if let event = item.accessLog()?.events.last {
            lines.append("  access log: dropped frames \(event.numberOfDroppedVideoFrames), stalls \(event.numberOfStalls), "
                + "playback type \(event.playbackType ?? "?")")
        }
        for event in item.errorLog()?.events.suffix(5) ?? [] {
            lines.append("  error log: \(Self.describe(event))")
        }
        lines.append("  system: thermal \(Self.describe(ProcessInfo.processInfo.thermalState))\(Self.memory)")
        lines.append("  editor: \(context)")
        return lines.joined(separator: "\n")
    }

    private static var memory: String {
        #if os(iOS)
        let available = Double(os_proc_available_memory()) / 1_048_576
        return String(format: ", %.0f MB available", available)
        #else
        return ""
        #endif
    }

    nonisolated private static func describe(_ item: AVPlayerItem?) -> String {
        guard let item else { return "item ?" }
        return String(format: "item %08x", UInt(bitPattern: ObjectIdentifier(item).hashValue) & 0xFFFF_FFFF)
    }

    nonisolated private static func describe(_ error: NSError?) -> String {
        guard let error else { return "none" }
        let underlying = (error.userInfo[NSUnderlyingErrorKey] as? NSError).map { " ← \($0.domain) \($0.code)" } ?? ""
        return "\(error.domain) \(error.code) “\(error.localizedDescription)”\(underlying)"
    }

    nonisolated private static func describe(_ event: AVPlayerItemErrorLogEvent) -> String {
        "\(event.errorDomain) \(event.errorStatusCode) “\(event.errorComment ?? "")”"
    }

    private static func describe(_ status: AVPlayer.TimeControlStatus) -> String {
        switch status {
        case .paused: "paused"
        case .waitingToPlayAtSpecifiedRate: "waiting"
        case .playing: "playing"
        @unknown default: "unknown"
        }
    }

    private static func describe(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    private static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "?" }
        return String(format: "%d:%05.2f", Int(seconds) / 60, seconds.truncatingRemainder(dividingBy: 60))
    }

    // MARK: - File

    private static let url = URL.documentsDirectory.appending(path: "StillPlayback.log")
    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    private func write(_ text: String) {
        let line = "\(Self.stamp.string(from: .now)) \(text)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: Self.url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: Self.url)
        }
    }
}
#endif
