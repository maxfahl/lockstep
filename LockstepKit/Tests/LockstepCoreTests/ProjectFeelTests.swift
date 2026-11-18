import Foundation
import Testing
@testable import LockstepCore

@Suite("ProjectFeel")
struct ProjectFeelTests {
    /// A song with a beat every half second from 2 s on, and one clip whose recording starts with the song,
    /// so a syllable's place in the recording is its moment in the song.
    private func song(
        clipFeel: ClipFeel, syllables: [Double]
    ) -> (project: Project, clip: Clip, markers: [UUID: [SyllableMarker]]) {
        var project = Project(songLengthSamples: 48_000 * 40)
        project.grid = Grid(beats: (0..<60).map { Beat(number: $0, time: 2 + Double($0) * 0.5) })
        let recording = Recording(lengthSamples: 48_000 * 30, rawStart: 0)
        let id = project.addRecording(recording, samples: 0..<48_000 * 30, asClipOn: project.tracks[0].id, voices: .none)!
        project.tracks[0].clips[0].feel = clipFeel
        let markers = syllables.map { SyllableMarker(sample: Int(($0 * 48_000).rounded()), strength: 20) }
        return (project, project.clip(id)!, [recording.id: markers])
    }

    /// Syllables at the given places within each beat, beat after beat from the third beat on.
    private func syllables(_ count: Int, at places: [Double]) -> [Double] {
        (0..<count).map { (index: Int) -> Double in
            let beatsIn: Double = 2 + Double(index / places.count) + places[index % places.count]
            return 2 + beatsIn * 0.5
        }
    }

    private var onTriplets: [Double] { syllables(12, at: [0, 1.0 / 3, 2.0 / 3]) }
    private var onSixteenths: [Double] { syllables(16, at: [0, 0.25, 0.5, 0.75]) }

    @Test func aNewClipStartsOnSixteenths() {
        #expect(Clip().feel == .sixteenths)
    }

    @Test func aClipOnSixteenthsGivesSixteenths() {
        // Also when its syllables sit on triplets: nothing is listened to.
        let made = song(clipFeel: .sixteenths, syllables: onTriplets)
        #expect(made.project.grid(for: made.clip, markers: made.markers) == .sixteenths)
        #expect(made.project.chosenGrid(for: made.clip) == .sixteenths)
    }

    @Test func aClipOnTripletsGivesTriplets() {
        let made = song(clipFeel: .triplets, syllables: onSixteenths)
        #expect(made.project.grid(for: made.clip, markers: made.markers) == .triplets)
        #expect(made.project.chosenGrid(for: made.clip) == .triplets)
    }

    @Test func aClipOnAutoIsHeard() {
        let triplets = song(clipFeel: .auto, syllables: onTriplets)
        #expect(triplets.project.chosenGrid(for: triplets.clip) == nil)
        #expect(triplets.project.grid(for: triplets.clip, markers: triplets.markers) == .triplets)
        let sixteenths = song(clipFeel: .auto, syllables: onSixteenths)
        #expect(sixteenths.project.grid(for: sixteenths.clip, markers: sixteenths.markers) == .sixteenths)
    }

    @Test func aClipOnAutoWithTooFewMarkersStaysOnSixteenths() {
        let few = song(clipFeel: .auto, syllables: Array(onTriplets.prefix(3)))
        #expect(few.project.grid(for: few.clip, markers: few.markers) == .sixteenths)
        // The same while the syllables are not found yet, and while the song has no beats.
        #expect(few.project.grid(for: few.clip, markers: [:]) == .sixteenths)
        var noBeats = song(clipFeel: .auto, syllables: onTriplets)
        noBeats.project.grid = nil
        #expect(noBeats.project.grid(for: noBeats.clip, markers: noBeats.markers) == .sixteenths)
    }

    @Test func excludedSyllablesAreNotListenedTo() {
        // Twelve syllables on triplets, and Max has excluded all but three of them.
        var made = song(clipFeel: .auto, syllables: onTriplets)
        let samples = made.markers.values.first!.map(\.sample)
        made.project.recordings[0].excludedMarkers = Array(samples.dropFirst(3))
        #expect(made.project.feelMarkerTimes(of: made.clip, markers: made.markers).count == 3)
        #expect(made.project.grid(for: made.clip, markers: made.markers) == .sixteenths)
    }

    @Test func aMarkersDistanceIsMeasuredToTheTripletGrid() throws {
        let made = song(clipFeel: .triplets, syllables: onTriplets)
        let beats = try #require(made.project.grid)
        let perBeat = made.project.grid(for: made.clip, markers: made.markers).perBeat
        #expect(perBeat == 6)
        // The second syllable of a triplet, a third of a beat after the beat at 3 s, and 10 ms late.
        let third = 3 + 0.5 / 3
        let time = third + 0.010
        let nearest = try #require(MarkerDistance.nearestSubBeat(to: time, grid: beats, perBeat: perBeat))
        #expect(abs(nearest.subBeatTime - third) < 1e-9)
        #expect(abs(nearest.spacing - 0.5 / 6) < 1e-9)
        #expect(abs((time - nearest.subBeatTime) - 0.010) < 1e-9)
        // Against sixteenths the same syllable would be measured to the sixteenth at 3.125 s, 52 ms away.
        let wrong = try #require(MarkerDistance.nearestSubBeat(to: time, grid: beats, perBeat: 4))
        #expect(abs(wrong.subBeatTime - 3.125) < 1e-9)
    }

    @Test func theMemoryAnswersLikeTheProjectAndListensOnlyWhenSomethingChanged() {
        var made = song(clipFeel: .auto, syllables: onTriplets)
        var memory = FeelMemory()
        #expect(memory.grid(for: made.clip, in: made.project, markers: made.markers) == .triplets)
        #expect(memory.grid(for: made.clip, in: made.project, markers: made.markers) == .triplets)
        #expect(memory.detections == 1)

        // Other syllables are listened to again.
        let sixteenths = [made.markers.keys.first!: onSixteenths.map {
            SyllableMarker(sample: Int(($0 * 48_000).rounded()), strength: 20)
        }]
        #expect(memory.grid(for: made.clip, in: made.project, markers: sixteenths) == .sixteenths)
        #expect(memory.detections == 2)

        // So are new beats: with the beats a third of a beat apart from before, nothing sits on triplets alone.
        made.project.grid = Grid(beats: (0..<60).map { Beat(number: $0, time: 2 + Double($0) * 0.4) })
        _ = memory.grid(for: made.clip, in: made.project, markers: sixteenths)
        #expect(memory.detections == 3)

        // A choice is never listened for, and is not remembered in place of what was heard.
        var chosen = made.clip
        chosen.feel = .triplets
        #expect(memory.grid(for: chosen, in: made.project, markers: sixteenths) == .triplets)
        #expect(memory.detections == 3)
        _ = memory.grid(for: made.clip, in: made.project, markers: sixteenths)
        #expect(memory.detections == 3)

        // A clip that is gone is forgotten, and heard afresh if it comes back.
        memory.forget(allBut: [])
        _ = memory.grid(for: made.clip, in: made.project, markers: sixteenths)
        #expect(memory.detections == 4)
    }

    // MARK: Projects saved while the song had sub-beats of its own

    /// A project as it was saved before the sub-beats became the clip's alone: the song's choice, when it
    /// had one saved, and four clips on two tracks. The first says it follows the song, the second says
    /// nothing, as a clip saved before phase 21 does, and the last two have a choice of their own.
    private func savedBefore(songFeel: String?) throws -> [ClipFeel] {
        let song = songFeel.map { "\"feel\": \"\($0)\"," } ?? ""
        let text = """
            {
              \(song)
              "tracks": [
                { "name": "Track 1", "clips": [ { "feel": "followSong" }, { } ] },
                { "name": "Track 2", "clips": [ { "feel": "sixteenths" }, { "feel": "triplets" } ] }
              ]
            }
            """
        let project = try JSONDecoder().decode(Project.self, from: Data(text.utf8))
        return project.tracks.flatMap(\.clips).map(\.feel)
    }

    @Test func aClipThatFollowedASongOnSixteenthsIsOnSixteenths() throws {
        #expect(try savedBefore(songFeel: "sixteenths") == [.sixteenths, .sixteenths, .sixteenths, .triplets])
        // A song saved before it had a choice counted in sixteenths.
        #expect(try savedBefore(songFeel: nil) == [.sixteenths, .sixteenths, .sixteenths, .triplets])
    }

    @Test func aClipThatFollowedASongOnTripletsIsOnTriplets() throws {
        #expect(try savedBefore(songFeel: "triplets") == [.triplets, .triplets, .sixteenths, .triplets])
    }

    @Test func aClipThatFollowedASongOnAutoIsOnAuto() throws {
        #expect(try savedBefore(songFeel: "auto") == [.auto, .auto, .sixteenths, .triplets])
    }

    @Test func aProjectSavedNowKeepsEveryClipsChoiceAndNoChoiceForTheSong() throws {
        let clips = [Clip(feel: .sixteenths), Clip(feel: .triplets), Clip(feel: .auto)]
        let project = Project(tracks: [Track(name: "Track 1", clips: clips)])
        let data = try JSONEncoder().encode(project)
        let read = try JSONDecoder().decode(Project.self, from: data)
        #expect(read.tracks[0].clips.map(\.feel) == [.sixteenths, .triplets, .auto])
        // The song's choice is not written any more: only clips have a "feel".
        let saved = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(saved["feel"] == nil)
    }
}
