import Photos

public enum PhotosSaveError: Error, LocalizedError {
    case accessDenied
    case saveFailed(Error?)

    public var errorDescription: String? {
        switch self {
        case .accessDenied:
            "Still doesn’t have permission to add to your Photos library."
        case let .saveFailed(error):
            ["Photos couldn’t save the Live Photo.", error?.localizedDescription].compactMap(\.self).joined(separator: " ")
        }
    }

    /// The Photos error behind a failed save, if Photos gave one.
    public var photosErrorCode: PHPhotosError.Code? {
        guard case let .saveFailed(error?) = self else { return nil }
        return (error as? PHPhotosError)?.code
    }
}

/// Adds a paired JPEG and MOV to the Photos library as one Live Photo asset.
public enum PhotosLibrarySaver {
    /// Asks for add-only access the first time; afterwards returns the stored decision without asking.
    ///
    /// Call this before rendering, so a refusal is known before the user waits for a render.
    public static func ensureAddAccess() async throws {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        let decided = status == .notDetermined ? await PHPhotoLibrary.requestAuthorization(for: .addOnly) : status
        switch decided {
        case .authorized, .limited:
            return
        default:
            throw PhotosSaveError.accessDenied
        }
    }

    /// Saves the pair and returns once Photos has confirmed creation.
    ///
    /// Once this starts, the save can’t be called back: Photos either creates the asset or reports an error.
    ///
    /// - Parameter originalFilename: base name Photos records for both resources. During development
    ///   pass a `StillTest-` prefix so test assets are easy to find.
    public static func save(_ pair: LivePhotoPair, originalFilename: String) async throws {
        try await ensureAddAccess()

        let imageURL = pair.imageURL
        let videoURL = pair.videoURL
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                let photoOptions = PHAssetResourceCreationOptions()
                photoOptions.originalFilename = "\(originalFilename).JPG"
                let videoOptions = PHAssetResourceCreationOptions()
                videoOptions.originalFilename = "\(originalFilename).MOV"
                request.addResource(with: .photo, fileURL: imageURL, options: photoOptions)
                request.addResource(with: .pairedVideo, fileURL: videoURL, options: videoOptions)
            }
        } catch {
            if (error as? PHPhotosError)?.code == .accessUserDenied { throw PhotosSaveError.accessDenied }
            throw PhotosSaveError.saveFailed(error)
        }
    }
}
