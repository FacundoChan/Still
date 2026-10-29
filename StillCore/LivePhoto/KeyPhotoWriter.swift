import CoreImage
import CoreVideo
import ImageIO
import UniformTypeIdentifiers

/// Writes the Key Photo JPEG from the exact frame the movie encodes at the Key Photo time.
///
/// In HDR the JPEG is an SDR image with an ISO gain map, as iPhone HDR photos are: screens without HDR show the
/// SDR image, and Photos uses the gain map to show the HDR frame on screens that can.
struct KeyPhotoWriter {
    let dynamicRange: DynamicRange
    let capture: CaptureStamp
    private let context = CIContext(options: [.cacheIntermediates: false])

    func write(_ pixelBuffer: CVPixelBuffer, to url: URL, contentIdentifier: String) throws {
        dynamicRange.tag(pixelBuffer)
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        var properties = LivePhotoMetadata.imageProperties(contentIdentifier: contentIdentifier, quality: 0.92)
            .merging(capture.imageProperties) { kept, _ in kept }
        let cgImage: CGImage?
        switch dynamicRange {
        case .standard:
            cgImage = context.createCGImage(image, from: image.extent, format: .RGBA8,
                                            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        case .high:
            // Half floats keep the highlights above SDR white, which ImageIO turns into the gain map.
            cgImage = context.createCGImage(image, from: image.extent, format: .RGBAh,
                                            colorSpace: CGColorSpace(name: CGColorSpace.itur_2100_HLG)!)
            properties[kCGImageDestinationEncodeRequest] = kCGImageDestinationEncodeToISOGainmap
        }
        guard let cgImage,
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else {
            throw LivePhotoExportError.keyPhotoEncodingFailed
        }
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw LivePhotoExportError.keyPhotoEncodingFailed
        }
    }
}
