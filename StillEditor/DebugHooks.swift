import Foundation
import Photos
import StillCore

/// Launch arguments for exercising export failure and cancellation paths by hand or with automation.
/// They exist only in Debug builds.
///
/// - `-StillSimulateFailure photosDenied | photosFailed | diskFull | render`
/// - `-StillExportFrameDelay <seconds>` slows rendering down, so there is time to press Cancel.
enum DebugHooks {
    enum Point {
        case photosAccess
        case render
        case photosSave
    }

    static var frameDelay: TimeInterval? {
        #if DEBUG
        let delay = UserDefaults.standard.double(forKey: "StillExportFrameDelay")
        return delay > 0 ? delay : nil
        #else
        return nil
        #endif
    }

    static func simulateFailure(at point: Point) throws {
        #if DEBUG
        switch (UserDefaults.standard.string(forKey: "StillSimulateFailure"), point) {
        case ("photosDenied", .photosAccess):
            throw PhotosSaveError.accessDenied
        case ("diskFull", .render):
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)
        case ("render", .render):
            throw LivePhotoExportError.renderFailed
        case ("photosFailed", .photosSave):
            throw PhotosSaveError.saveFailed(NSError(
                domain: PHPhotosErrorDomain, code: PHPhotosError.Code.internalError.rawValue,
                userInfo: [NSLocalizedDescriptionKey: "The operation couldn’t be completed."]
            ))
        default:
            break
        }
        #endif
    }
}
