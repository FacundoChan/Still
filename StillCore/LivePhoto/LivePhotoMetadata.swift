import AVFoundation
import CoreMedia
import ImageIO

/// The keys that pair a still image and a movie into one Live Photo.
public enum LivePhotoMetadata {
    /// Top-level QuickTime metadata item holding the content identifier.
    public static let contentIdentifierKey = "com.apple.quicktime.content.identifier"
    /// Timed metadata marking the movie time that corresponds to the still image.
    public static let stillImageTimeKey = "com.apple.quicktime.still-image-time"
    /// Key inside the image's Apple MakerNote dictionary holding the content identifier.
    public static let makerAppleContentIdentifierKey = "17"

    public static let stillImageTimeIdentifier = AVMetadataIdentifier(rawValue: "mdta/\(stillImageTimeKey)")
    public static let contentIdentifierIdentifier = AVMetadataIdentifier(rawValue: "mdta/\(contentIdentifierKey)")

    static func contentIdentifierItem(_ identifier: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.keySpace = .quickTimeMetadata
        item.key = contentIdentifierKey as NSString
        item.value = identifier as NSString
        item.dataType = kCMMetadataBaseDataType_UTF8 as String
        return item
    }

    static func stillImageTimeFormatDescription() throws -> CMFormatDescription {
        let specification: [String: Any] = [
            kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String: stillImageTimeIdentifier.rawValue,
            kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String: kCMMetadataBaseDataType_SInt8 as String,
        ]
        var description: CMFormatDescription?
        let status = CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
            allocator: kCFAllocatorDefault,
            metadataType: kCMMetadataFormatType_Boxed,
            metadataSpecifications: [specification] as CFArray,
            formatDescriptionOut: &description
        )
        guard status == noErr, let description else {
            throw LivePhotoExportError.metadataUnavailable(status)
        }
        return description
    }

    static func stillImageTimeGroup(at time: CMTime, duration: CMTime) -> AVTimedMetadataGroup {
        let item = AVMutableMetadataItem()
        item.keySpace = .quickTimeMetadata
        item.key = stillImageTimeKey as NSString
        item.value = 0 as NSNumber
        item.dataType = kCMMetadataBaseDataType_SInt8 as String
        return AVTimedMetadataGroup(items: [item], timeRange: CMTimeRange(start: time, duration: duration))
    }

    static func imageProperties(contentIdentifier: String, quality: Double) -> [CFString: Any] {
        [
            kCGImagePropertyMakerAppleDictionary: [makerAppleContentIdentifierKey: contentIdentifier],
            kCGImageDestinationLossyCompressionQuality: quality,
        ]
    }
}

/// The capture facts written into one Live Photo: the Key Photo's moment, the camera, and the location the edit
/// includes, if any.
struct CaptureStamp: Sendable {
    /// The recording start plus the Key Photo's place in the video.
    let photoDate: Date?
    /// The movie's first frame.
    let movieDate: Date?
    let timeZoneOffset: Int?
    let make: String?
    let model: String?
    let software: String?
    let location: CaptureLocation?

    init(capture: CaptureMetadata, plan: EditPlan) {
        photoDate = capture.date?.addingTimeInterval(plan.keyPhotoSourceTime.seconds)
        movieDate = capture.date?.addingTimeInterval(plan.selection.start.seconds)
        timeZoneOffset = capture.timeZoneOffset
        make = capture.make
        model = capture.model
        software = capture.software
        location = plan.location
    }

    /// TIFF, Exif and GPS dictionaries for the Key Photo, which is where Photos reads the date, camera and place.
    var imageProperties: [CFString: Any] {
        var properties: [CFString: Any] = [:]
        var tiff: [CFString: Any] = [:]
        if let make { tiff[kCGImagePropertyTIFFMake] = make }
        if let model { tiff[kCGImagePropertyTIFFModel] = model }
        if let software { tiff[kCGImagePropertyTIFFSoftware] = software }
        if let photoDate {
            let local = exifDate(photoDate)
            tiff[kCGImagePropertyTIFFDateTime] = local
            var exif: [CFString: Any] = [
                kCGImagePropertyExifDateTimeOriginal: local,
                kCGImagePropertyExifDateTimeDigitized: local,
                kCGImagePropertyExifSubsecTimeOriginal: String(format: "%03d", Int(photoDate.timeIntervalSince1970.truncatingRemainder(dividingBy: 1) * 1000)),
            ]
            if let offset = offsetText(colon: true) {
                exif[kCGImagePropertyExifOffsetTimeOriginal] = offset
                exif[kCGImagePropertyExifOffsetTimeDigitized] = offset
                exif[kCGImagePropertyExifOffsetTime] = offset
            }
            properties[kCGImagePropertyExifDictionary] = exif
        }
        if !tiff.isEmpty { properties[kCGImagePropertyTIFFDictionary] = tiff }
        if let location {
            var gps: [CFString: Any] = [
                kCGImagePropertyGPSLatitude: abs(location.latitude),
                kCGImagePropertyGPSLatitudeRef: location.latitude >= 0 ? "N" : "S",
                kCGImagePropertyGPSLongitude: abs(location.longitude),
                kCGImagePropertyGPSLongitudeRef: location.longitude >= 0 ? "E" : "W",
            ]
            if let altitude = location.altitude {
                gps[kCGImagePropertyGPSAltitude] = abs(altitude)
                gps[kCGImagePropertyGPSAltitudeRef] = altitude >= 0 ? 0 : 1
            }
            if let accuracy = location.horizontalAccuracy { gps[kCGImagePropertyGPSHPositioningError] = accuracy }
            properties[kCGImagePropertyGPSDictionary] = gps
        }
        return properties
    }

    /// QuickTime metadata for the movie, under the keys iPhone uses.
    var movieItems: [AVMetadataItem] {
        var items: [AVMetadataItem] = []
        func add(_ key: String, _ value: String?) {
            guard let value else { return }
            let item = AVMutableMetadataItem()
            item.keySpace = .quickTimeMetadata
            item.key = key as NSString
            item.value = value as NSString
            item.dataType = kCMMetadataBaseDataType_UTF8 as String
            items.append(item)
        }
        add("com.apple.quicktime.make", make)
        add("com.apple.quicktime.model", model)
        add("com.apple.quicktime.software", software)
        add("com.apple.quicktime.creationdate", movieDate.map(quickTimeDate))
        add("com.apple.quicktime.location.ISO6709", location?.iso6709)
        return items
    }

    private var timeZone: TimeZone {
        timeZoneOffset.flatMap { TimeZone(secondsFromGMT: $0) } ?? .current
    }

    private func exifDate(_ date: Date) -> String {
        format(date, "yyyy:MM:dd HH:mm:ss")
    }

    private func quickTimeDate(_ date: Date) -> String {
        format(date, "yyyy-MM-dd'T'HH:mm:ss") + (offsetText(colon: false) ?? "")
    }

    private func format(_ date: Date, _ pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }

    /// `+08:00` for Exif, `+0800` for QuickTime; nil when the video gave no offset.
    private func offsetText(colon: Bool) -> String? {
        guard let timeZoneOffset else { return nil }
        let minutes = abs(timeZoneOffset) / 60
        return String(format: colon ? "%@%02d:%02d" : "%@%02d%02d", timeZoneOffset < 0 ? "-" : "+", minutes / 60, minutes % 60)
    }
}
