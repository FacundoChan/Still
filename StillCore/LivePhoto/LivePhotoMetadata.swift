import AVFoundation
import CoreMedia
import ImageIO

/// The keys that pair a still image and a movie into one Live Photo (goal.md §10).
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
