import Foundation
import Testing
@testable import LockstepCore

@Suite("The song's own volume")
struct SongGainTests {
    @Test func aProjectSavedBeforeTheSongHadAVolumePlaysItAsItIs() throws {
        let old = try JSONDecoder().decode(Project.self, from: Data(#"{"songName":"Old","version":1}"#.utf8))
        #expect(old.songGainDb == 0)
        #expect(old.songGain == 1)
    }

    @Test func theVolumeIsSavedAndReadBack() throws {
        var project = Project(songName: "Song")
        project.songGainDb = -7.5
        let read = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project))
        #expect(read.songGainDb == -7.5)
        #expect(read == project)
    }

    @Test func aVolumeOutsideTheRangeInTheFileIsBroughtIntoIt() throws {
        let loud = try JSONDecoder().decode(Project.self, from: Data(#"{"songGainDb":6}"#.utf8))
        #expect(loud.songGainDb == 0)
        let quiet = try JSONDecoder().decode(Project.self, from: Data(#"{"songGainDb":-90}"#.utf8))
        #expect(quiet.songGainDb == Project.songGainRange.lowerBound)
    }

    @Test func sixDecibelsDownIsAboutHalf() {
        let project = Project(songGainDb: -6)
        #expect(abs(project.songGain - 0.501) < 0.001)
    }
}
