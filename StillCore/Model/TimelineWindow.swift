import Foundation

/// What the two timeline strips show.
public enum TimelineWindow {
    /// Sources up to this long fit the detail strip, which then shows alone.
    public static let singleStripThreshold = 8.0
    /// Source seconds of context the detail strip shows on each side of the selection.
    public static let detailPadding = 2.0
    /// Frame ticks appear once frames are at least this many points apart.
    public static let minimumTickSpacing = 6.0

    public static func showsOverview(sourceDuration: Double) -> Bool {
        sourceDuration > singleStripThreshold
    }

    /// The detail strip’s range: the selection with padding, or the playhead’s neighborhood while the user
    /// scrubs outside it. Clamped to the source, keeping its width where possible.
    public static func detailRange(
        selection: ClosedRange<Double>,
        playhead: Double,
        sourceDuration: Double
    ) -> ClosedRange<Double> {
        guard showsOverview(sourceDuration: sourceDuration) else { return 0...sourceDuration }
        var lower = selection.lowerBound - detailPadding
        var upper = selection.upperBound + detailPadding
        let width = upper - lower
        if playhead < lower || playhead > upper {
            lower = playhead - width / 2
            upper = playhead + width / 2
        }
        if lower < 0 {
            upper -= lower
            lower = 0
        }
        if upper > sourceDuration {
            lower = max(0, lower - (upper - sourceDuration))
            upper = sourceDuration
        }
        return lower...upper
    }
}
