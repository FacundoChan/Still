import Foundation

/// What the camera recorded about a video, carried over to its Live Photos: when, on which camera, and where.
public struct CaptureMetadata: Sendable, Equatable {
    /// When recording started.
    public var date: Date?
    /// The camera's offset from UTC when it recorded, in seconds; nil when the video doesn't say.
    public var timeZoneOffset: Int?
    public var make: String?
    public var model: String?
    public var software: String?
    public var location: CaptureLocation?

    public init(date: Date? = nil, timeZoneOffset: Int? = nil, make: String? = nil, model: String? = nil,
                software: String? = nil, location: CaptureLocation? = nil) {
        self.date = date
        self.timeZoneOffset = timeZoneOffset
        self.make = make
        self.model = model
        self.software = software
        self.location = location
    }

    /// Reads a QuickTime creation date such as `2024-05-21T15:36:27+0800`, as iPhone writes it.
    static func parseCreationDate(_ text: String) -> (date: Date, offset: Int?)? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd'T'HH:mm:ss.SSSZ", "yyyy-MM-dd'T'HH:mm:ssXXXXX"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) {
                return (date, timeZoneOffset(in: text))
            }
        }
        return nil
    }

    /// The trailing `+0800`, `+08:00` or `Z` of an ISO 8601 date, in seconds.
    private static func timeZoneOffset(in text: String) -> Int? {
        if text.hasSuffix("Z") { return 0 }
        let pattern = /([+-])(\d{2}):?(\d{2})$/
        guard let match = text.firstMatch(of: pattern), let hours = Int(match.2), let minutes = Int(match.3) else { return nil }
        return (match.1 == "-" ? -1 : 1) * (hours * 3600 + minutes * 60)
    }
}

/// A recorded position.
public struct CaptureLocation: Sendable, Equatable {
    public var latitude: Double
    public var longitude: Double
    /// Meters above sea level.
    public var altitude: Double?
    /// Meters.
    public var horizontalAccuracy: Double?

    public init(latitude: Double, longitude: Double, altitude: Double? = nil, horizontalAccuracy: Double? = nil) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.horizontalAccuracy = horizontalAccuracy
    }

    /// Reads an ISO 6709 position such as `+48.8584+002.2945+035.000/`, as QuickTime stores it.
    public init?(iso6709 text: String) {
        let pattern = /^([+-]\d+(?:\.\d+)?)([+-]\d+(?:\.\d+)?)([+-]\d+(?:\.\d+)?)?(?:CRS[^\/]*)?\/?$/
        guard let match = text.firstMatch(of: pattern),
              let latitude = Double(match.1), let longitude = Double(match.2),
              abs(latitude) <= 90, abs(longitude) <= 180 else { return nil }
        self.init(latitude: latitude, longitude: longitude, altitude: match.3.flatMap { Double($0) })
    }

    /// ISO 6709, for QuickTime metadata.
    var iso6709: String {
        var text = String(format: "%+08.4f%+09.4f", latitude, longitude)
        if let altitude { text += String(format: "%+08.3f", altitude) }
        return text + "/"
    }
}
