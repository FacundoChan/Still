import CoreGraphics
import CoreText
import Foundation
import MediaAccessibility

/// A word the video's speech says, at the source seconds it's said. The text keeps the transcriber's spacing and
/// punctuation, so a phrase's words join into its text.
public struct SpokenWord: Sendable, Equatable {
    public var text: String
    public var start: Double
    public var end: Double

    public init(text: String, start: Double, end: Double) {
        self.text = text
        self.start = start
        self.end = end
    }
}

/// What a video says, word by word, from speech recognition on the device. Each phrase is a stretch the transcriber
/// finished as one, usually a sentence.
public struct Transcript: Sendable, Equatable {
    /// The language it was transcribed in, as a BCP 47 tag.
    public var language: String
    public var phrases: [[SpokenWord]]

    public init(language: String, phrases: [[SpokenWord]]) {
        self.language = language
        self.phrases = phrases
    }

    /// The phrases with a word inside `range`, in source seconds: what captions over that range can show.
    public func phrases(overlapping range: ClosedRange<Double>) -> [[SpokenWord]] {
        phrases.filter { phrase in phrase.contains { $0.end > range.lowerBound && $0.start < range.upperBound } }
    }
}

/// Captions drawn into the Live Photo's video: the phrases spoken during the selection, in a caption style.
public struct BurnedCaptions: Sendable, Equatable {
    public var phrases: [[SpokenWord]]
    public var style: CaptionStyle

    public init(phrases: [[SpokenWord]], style: CaptionStyle) {
        self.phrases = phrases
        self.style = style
    }
}

/// How captions look: one of the caption styles in Settings › Accessibility › Subtitles & Captioning, which Photos
/// and every video player follow. The style is the system's, so choosing one changes it everywhere, as in Photos.
public struct CaptionStyle: @unchecked Sendable, Equatable {
    /// One of the system's caption styles.
    public struct Profile: Sendable, Identifiable, Equatable {
        public let id: String
        /// As Settings names it, such as “Transparent Background”.
        public let name: String
    }

    struct Color: Sendable, Equatable {
        var red, green, blue, alpha: Double

        static let black = Color(red: 0, green: 0, blue: 0, alpha: 1)

        var isVisible: Bool { alpha > 0.001 }
        var cgColor: CGColor {
            CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [red, green, blue, alpha])!
        }
    }

    enum Edge: Sendable, Equatable {
        case none
        case raised
        case depressed
        /// Outline Text's.
        case outline
        case dropShadow
    }

    public let profileID: String
    public let name: String
    /// Immutable, so sharing it between threads is safe.
    let font: CTFontDescriptor
    /// Relative to the system's caption size: 1, or 1.5 for Large Text.
    let relativeSize: Double
    let text: Color
    /// Behind each line's glyphs, as in Classic.
    let background: Color
    /// A box behind all the lines, as in Transparent Background.
    let window: Color
    /// In points at the system's caption size.
    let windowCornerRadius: Double
    let edge: Edge

    /// Reads a system style: the caption appearance it gives, as MediaAccessibility describes it.
    public init(profileID: String) {
        self.profileID = profileID
        name = MACaptionAppearanceCopyProfileName(profileID as CFString) as String
        var font: CTFontDescriptor?
        var relativeSize = 1.0
        var text = Color(red: 1, green: 1, blue: 1, alpha: 1)
        var background = Color.black
        var window = Color.black
        var radius = 0.0
        var edge = Edge.none
        MACaptionAppearanceExecuteBlockForProfileID(profileID as CFString) {
            let domain = MACaptionAppearanceDomain.user
            font = MACaptionAppearanceCopyFontDescriptorForStyle(domain, nil, .default).takeRetainedValue()
            relativeSize = Double(MACaptionAppearanceGetRelativeCharacterSize(domain, nil))
            text = Color(MACaptionAppearanceCopyForegroundColor(domain, nil).takeRetainedValue(),
                         opacity: MACaptionAppearanceGetForegroundOpacity(domain, nil))
            background = Color(MACaptionAppearanceCopyBackgroundColor(domain, nil).takeRetainedValue(),
                               opacity: MACaptionAppearanceGetBackgroundOpacity(domain, nil))
            window = Color(MACaptionAppearanceCopyWindowColor(domain, nil).takeRetainedValue(),
                           opacity: MACaptionAppearanceGetWindowOpacity(domain, nil))
            radius = Double(MACaptionAppearanceGetWindowRoundedCornerRadius(domain, nil))
            edge = Edge(MACaptionAppearanceGetTextEdgeStyle(domain, nil))
        }
        self.font = font ?? CTFontDescriptorCreateWithAttributes([:] as CFDictionary)
        self.relativeSize = relativeSize > 0 ? relativeSize : 1
        self.text = text
        self.background = background
        self.window = window
        windowCornerRadius = radius
        self.edge = edge
    }

    /// The style captions show in now.
    public static var current: CaptionStyle { CaptionStyle(profileID: activeProfileID) }

    /// The system's styles, in Settings' order, with any the user made.
    public static var profiles: [Profile] {
        (MACaptionAppearanceCopyProfileIDs() as? [String] ?? []).map { id in
            Profile(id: id, name: MACaptionAppearanceCopyProfileName(id as CFString) as String)
        }
    }

    public static var activeProfileID: String {
        MACaptionAppearanceCopyActiveProfileID() as String
    }

    /// Makes `profileID` the style for captions everywhere, as choosing a style in Photos does.
    public static func activate(_ profileID: String) {
        MACaptionAppearanceSetActiveProfileID(profileID as CFString)
    }

    /// Posted when a caption style changes, here or in Settings.
    public static let didChangeNotification = Notification.Name(kMACaptionAppearanceSettingsChangedNotification as String)

    public static func == (a: CaptionStyle, b: CaptionStyle) -> Bool {
        a.profileID == b.profileID && a.name == b.name && CFEqual(a.font, b.font) && a.relativeSize == b.relativeSize
            && a.text == b.text && a.background == b.background && a.window == b.window
            && a.windowCornerRadius == b.windowCornerRadius && a.edge == b.edge
    }
}

private extension CaptionStyle.Color {
    init(_ color: CGColor, opacity: CGFloat) {
        let srgb = color.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil) ?? color
        let components = srgb.components ?? [1, 1, 1, 1]
        let rgb = components.count >= 3 ? Array(components.prefix(3)) : Array(repeating: components.first ?? 1, count: 3)
        self.init(red: Double(rgb[0]), green: Double(rgb[1]), blue: Double(rgb[2]),
                  alpha: Double(srgb.alpha * opacity))
    }
}

private extension CaptionStyle.Edge {
    init(_ style: MACaptionAppearanceTextEdgeStyle) {
        switch style {
        case .raised: self = .raised
        case .depressed: self = .depressed
        case .uniform: self = .outline
        case .dropShadow: self = .dropShadow
        default: self = .none
        }
    }
}
