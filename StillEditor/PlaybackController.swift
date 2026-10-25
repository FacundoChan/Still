import AVFoundation
import Observation

/// Two players behind the stage:
/// - the source player shows the whole video at 1× for scrubbing, and plays it outside the selection;
/// - the selection player plays the selection as it will export: speed applied, looping.
///
/// Both render through the export pipeline, so crop and color always match the export.
///
/// The source player is a pair that takes turns: a new item, such as the full frame for Crop mode, loads in the
/// one behind and comes forward once it shows the playhead's frame. Replacing the item of the player on screen
/// blanked it until the new item had decoded a frame.
@Observable
public final class PlaybackController {
    public let sourcePlayers = [AVPlayer(), AVPlayer()]
    public private(set) var activeSource = 0
    public let selectionPlayer = AVPlayer()

    public var sourcePlayer: AVPlayer { sourcePlayers[activeSource] }

    public private(set) var isPlaying = false
    public private(set) var showsSelectionPlayer = false

    /// Called with the source time being shown while playing.
    @ObservationIgnored public var onPlaybackTime: ((Double) -> Void)?

    @ObservationIgnored private var selectionStart = 0.0
    @ObservationIgnored private var selectionSpeed = 1.0
    @ObservationIgnored private var hasSelectionItem = false
    @ObservationIgnored private var timeObservers: [(AVPlayer, Any)] = []
    @ObservationIgnored private var endObservers: [NSObjectProtocol] = []
    /// Counts source seeks, so only the latest one's completion acts.
    @ObservationIgnored private var seekGeneration = 0
    /// Set after pausing the selection: show the source player once it has reached the paused frame.
    @ObservationIgnored private var revealsSourceAfterSeek = false
    /// Counts source items, so only the latest one comes forward.
    @ObservationIgnored private var itemGeneration = 0
    /// The source time most recently asked for, which a source item coming forward must show.
    @ObservationIgnored private var requestedSourceTime = 0.0

    public init() {
        for player in sourcePlayers { player.actionAtItemEnd = .pause }
        selectionPlayer.actionAtItemEnd = .none
        let interval = CMTime(value: 1, timescale: 60)
        for player in sourcePlayers + [selectionPlayer] {
            let token = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
                MainActor.assumeIsolated { self?.playerTimeChanged(player, time: time) }
            }
            timeObservers.append((player, token))
        }
        endObservers.append(NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let item = notification.object as? AVPlayerItem
            MainActor.assumeIsolated { self?.itemDidEnd(item) }
        })
    }

    // MARK: - Items

    /// Loads `item` behind the source player on screen, and brings it forward once it shows `time`.
    public func setSourceItem(_ item: AVPlayerItem, showing time: Double) {
        itemGeneration += 1
        let generation = itemGeneration
        let standby = sourcePlayers[1 - activeSource]
        standby.pause()
        standby.replaceCurrentItem(with: item)
        requestedSourceTime = time
        standby.seek(to: Self.time(time), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            guard finished else { return }
            Task { @MainActor [weak self] in self?.bringSourceForward(generation, showing: time) }
        }
    }

    private func bringSourceForward(_ generation: Int, showing time: Double) {
        guard generation == itemGeneration else { return }
        let previous = sourcePlayer
        let playingSource = isPlaying && !showsSelectionPlayer
        activeSource = 1 - activeSource
        // The old player keeps its item, out of sight, until the next swap reuses it.
        previous.pause()
        if playingSource {
            sourcePlayer.seek(to: previous.currentTime(), toleranceBefore: .zero, toleranceAfter: .zero)
            sourcePlayer.play()
        } else if abs(requestedSourceTime - time) > 1e-6 {
            // The playhead moved while the item loaded.
            seekSource(to: requestedSourceTime)
        }
    }

    public func setSelectionItem(_ item: AVPlayerItem, start: Double, speed: Double) {
        let wasPlayingSelection = isPlaying && showsSelectionPlayer
        selectionPlayer.replaceCurrentItem(with: item)
        selectionStart = start
        selectionSpeed = speed
        hasSelectionItem = true
        if wasPlayingSelection {
            selectionPlayer.seek(to: .zero)
            selectionPlayer.play()
        }
    }

    // MARK: - Transport

    /// Shows the source frame at `time`, paused.
    public func show(sourceTime time: Double) {
        pause()
        revealsSourceAfterSeek = false
        seekSource(to: time)
        showsSelectionPlayer = false
    }

    public func playSource(from time: Double) {
        pause()
        revealsSourceAfterSeek = false
        seekSource(to: time)
        showsSelectionPlayer = false
        isPlaying = true
        sourcePlayer.play()
    }

    /// Plays the selection as exported, from the output time that matches `sourceTime`.
    public func playSelection(fromSourceTime sourceTime: Double) {
        guard hasSelectionItem else { return playSource(from: sourceTime) }
        pause()
        revealsSourceAfterSeek = false
        let outputTime = max(0, (sourceTime - selectionStart) / selectionSpeed)
        selectionPlayer.seek(to: CMTime(seconds: outputTime, preferredTimescale: 60_000), toleranceBefore: .zero, toleranceAfter: .zero)
        showsSelectionPlayer = true
        isPlaying = true
        selectionPlayer.play()
    }

    /// Stops playback where it is and reports that exact moment through `onPlaybackTime`.
    ///
    /// Paused in the selection, the frame on screen stays: the selection player keeps showing it until the
    /// source player, which scrubbing uses, has sought to the same frame. Switching at once showed the
    /// source player's older frame for a moment.
    public func pause() {
        guard isPlaying else { return }
        for player in sourcePlayers { player.pause() }
        selectionPlayer.pause()
        isPlaying = false
        guard showsSelectionPlayer else {
            onPlaybackTime?(sourcePlayer.currentTime().seconds)
            return
        }
        let time = shownSelectionSourceTime()
        onPlaybackTime?(time)
        revealsSourceAfterSeek = true
        seekSource(to: time)
    }

    /// The source time of the selection frame on screen. The composition renders on a fixed output grid, and
    /// the frame shown is the last one at or before the current time.
    private func shownSelectionSourceTime() -> Double {
        let output = selectionPlayer.currentTime().seconds
        let frame = selectionPlayer.currentItem?.videoComposition?.frameDuration.seconds ?? 0
        let snapped = frame > 0 ? (output / frame + 1e-6).rounded(.down) * frame : output
        return selectionStart + max(snapped, 0) * selectionSpeed
    }

    /// Releases both items and observers once the window closes.
    public func tearDown() {
        pause()
        for (player, token) in timeObservers { player.removeTimeObserver(token) }
        timeObservers.removeAll()
        endObservers.forEach(NotificationCenter.default.removeObserver)
        endObservers.removeAll()
        for player in sourcePlayers { player.replaceCurrentItem(with: nil) }
        selectionPlayer.replaceCurrentItem(with: nil)
        hasSelectionItem = false
    }

    /// Steps the source player by whole source frames, which also handles variable frame rates.
    public func stepSource(by count: Int) {
        pause()
        showsSelectionPlayer = false
        sourcePlayer.currentItem?.step(byCount: count)
    }

    public var sourceTime: Double {
        sourcePlayer.currentTime().seconds
    }

    // MARK: - Observation

    private static func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 60_000)
    }

    private func seekSource(to time: Double) {
        seekGeneration += 1
        let generation = seekGeneration
        requestedSourceTime = time
        sourcePlayer.seek(to: Self.time(time), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            guard finished else { return }
            Task { @MainActor [weak self] in self?.sourceSeekFinished(generation) }
        }
    }

    private func sourceSeekFinished(_ generation: Int) {
        guard generation == seekGeneration, revealsSourceAfterSeek, !isPlaying else { return }
        revealsSourceAfterSeek = false
        showsSelectionPlayer = false
    }

    private func playerTimeChanged(_ player: AVPlayer, time: CMTime) {
        guard isPlaying, time.isNumeric else { return }
        if player === selectionPlayer, showsSelectionPlayer {
            onPlaybackTime?(selectionStart + time.seconds * selectionSpeed)
        } else if player === sourcePlayer, !showsSelectionPlayer {
            onPlaybackTime?(time.seconds)
        }
    }

    private func itemDidEnd(_ item: AVPlayerItem?) {
        if item === selectionPlayer.currentItem, isPlaying, showsSelectionPlayer {
            selectionPlayer.seek(to: .zero)
            selectionPlayer.play()
        } else if item === sourcePlayer.currentItem {
            isPlaying = false
        }
    }
}
