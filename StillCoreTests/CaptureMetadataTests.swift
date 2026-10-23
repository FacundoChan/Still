import Foundation
import Testing
@testable import StillCore

@Suite("Capture metadata")
struct CaptureMetadataTests {
    @Test func readsQuickTimeCreationDates() throws {
        let parsed = try #require(CaptureMetadata.parseCreationDate("2024-05-21T15:36:27+0800"))
        #expect(parsed.offset == 8 * 3600)
        #expect(parsed.date == Date(timeIntervalSince1970: 1_716_276_987))
        #expect(CaptureMetadata.parseCreationDate("2024-05-21T07:36:27Z")?.offset == 0)
        #expect(CaptureMetadata.parseCreationDate("2024-05-21T15:36:27-05:30")?.offset == -(5 * 3600 + 30 * 60))
        #expect(CaptureMetadata.parseCreationDate("yesterday") == nil)
    }

    @Test func readsAndWritesISO6709Locations() throws {
        let location = try #require(CaptureLocation(iso6709: "+48.8584+002.2945+035.000/"))
        #expect(location.latitude == 48.8584 && location.longitude == 2.2945 && location.altitude == 35)
        let south = try #require(CaptureLocation(iso6709: "-33.8568+151.2153/"))
        #expect(south.latitude == -33.8568 && south.altitude == nil)
        #expect(CaptureLocation(iso6709: "+91.0+000.0/") == nil)
        #expect(location.iso6709 == "+48.8584+002.2945+035.000/")
    }

    @Test func locationIsOffUntilChosen() throws {
        var state = try EditState(source: SourceInfo(duration: 10, frameRate: 30, orientedSize: CGSize(width: 1920, height: 1080),
                                                     hasAudio: true, hasLocation: true))
        #expect(state.canIncludeLocation && !state.includesLocation && !state.plan.includesLocation)
        state.setIncludesLocation(true)
        #expect(state.plan.includesLocation)

        var noLocation = try EditState(source: SourceInfo(duration: 10, frameRate: 30, orientedSize: CGSize(width: 1920, height: 1080), hasAudio: true))
        noLocation.setIncludesLocation(true)
        #expect(!noLocation.includesLocation)
    }
}
