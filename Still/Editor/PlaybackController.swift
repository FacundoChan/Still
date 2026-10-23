import AVFoundation
import Observation

/// Two players behind the stage:
/// - the source player shows the whole video at 1× for scrubbing, and plays it outside the selection;
/// - the selection player plays the selection as it will export: speed applied, looping.
///
/// Both render through the export pipeline, so crop and color always match the export.
@Observable
final class PlaybackController {
    let sourcePlayer = AVPlayer()
    let selectionPlayer = AVPlayer()

    private(set) var isPlaying = false
    private(set) var showsSelectionPlayer = false

    /// Called with the source time being shown while playing.
    @ObservationIgnored var onPlaybackTime: ((Double) -> Void)?

    @ObservationIgnored private var selectionStart = 0.0
    @ObservationIgnored private var selectionSpeed = 1.0
    @ObservationIgnored private var hasSelectionItem = false
    @ObservationIgnored private var timeObservers: [(AVPlayer, Any)] = []
    @ObservationIgnored private var endObservers: [NSObjectProtocol] = []

    init() {
        sourcePlayer.actionAtItemEnd = .pause
        selectionPlayer.actionAtItemEnd = .none
        let interval = CMTime(value: 1, timescale: 60)
        for player in [sourcePlayer, selectionPlayer] {
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

    func setSourceItem(_ item: AVPlayerItem, showing time: Double) {
        sourcePlayer.replaceCurrentItem(with: item)
        seekSource(to: time)
    }

    func setSelectionItem(_ item: AVPlayerItem, start: Double, speed: Double) {
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
    func show(sourceTime time: Double) {
        pause()
        seekSource(to: time)
    }

    func playSource(from time: Double) {
        pause()
        seekSource(to: time)
        showsSelectionPlayer = false
        isPlaying = true
        sourcePlayer.play()
    }

    /// Plays the selection as exported, from the output time that matches `sourceTime`.
    func playSelection(fromSourceTime sourceTime: Double) {
        guard hasSelectionItem else { return playSource(from: sourceTime) }
        pause()
        let outputTime = max(0, (sourceTime - selectionStart) / selectionSpeed)
        selectionPlayer.seek(to: CMTime(seconds: outputTime, preferredTimescale: 60_000), toleranceBefore: .zero, toleranceAfter: .zero)
        showsSelectionPlayer = true
        isPlaying = true
        selectionPlayer.play()
    }

    /// Stops playback and returns to the source player.
    func pause() {
        sourcePlayer.pause()
        selectionPlayer.pause()
        isPlaying = false
        showsSelectionPlayer = false
    }

    /// Releases both items and observers once the window closes.
    func tearDown() {
        pause()
        for (player, token) in timeObservers { player.removeTimeObserver(token) }
        timeObservers.removeAll()
        endObservers.forEach(NotificationCenter.default.removeObserver)
        endObservers.removeAll()
        sourcePlayer.replaceCurrentItem(with: nil)
        selectionPlayer.replaceCurrentItem(with: nil)
        hasSelectionItem = false
    }

    /// Steps the source player by whole source frames, which also handles variable frame rates.
    func stepSource(by count: Int) {
        pause()
        sourcePlayer.currentItem?.step(byCount: count)
    }

    var sourceTime: Double {
        sourcePlayer.currentTime().seconds
    }

    // MARK: - Observation

    private func seekSource(to time: Double) {
        sourcePlayer.seek(to: CMTime(seconds: time, preferredTimescale: 60_000), toleranceBefore: .zero, toleranceAfter: .zero)
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
