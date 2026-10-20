import CoreImage
import CoreVideo
import ImageIO
import UniformTypeIdentifiers

/// Writes the Key Photo JPEG from the exact frame the movie encodes at the Key Photo time.
struct KeyPhotoWriter {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    func write(_ pixelBuffer: CVPixelBuffer, to url: URL, contentIdentifier: String) throws {
        tagAsRec709(pixelBuffer)
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: colorSpace),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else {
            throw LivePhotoExportError.keyPhotoEncodingFailed
        }
        let properties = LivePhotoMetadata.imageProperties(contentIdentifier: contentIdentifier, quality: 0.92)
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw LivePhotoExportError.keyPhotoEncodingFailed
        }
    }

    /// The composition renders Rec. 709; make sure Core Image interprets the buffer the same way
    /// even if the compositor left a color attachment out.
    private func tagAsRec709(_ buffer: CVPixelBuffer) {
        let attachments: [(CFString, CFString)] = [
            (kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2),
            (kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2),
            (kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2),
        ]
        for (key, value) in attachments where CVBufferCopyAttachment(buffer, key, nil) == nil {
            CVBufferSetAttachment(buffer, key, value, .shouldPropagate)
        }
    }
}
