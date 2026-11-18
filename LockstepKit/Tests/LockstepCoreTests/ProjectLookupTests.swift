import Foundation
import Testing
@testable import LockstepCore

/// A project of four tracks over a song of two minutes, with clips of 1.5 s on each track that lie 20 ms
/// apart, a second and a third take on some lines, beats every half second, and Lines chosen for most
/// clips. It has the same shape every time, with new ids.
func projectWithManyClips() -> Project {
    var project = Project(songLengthSamples: 48_000 * 120)
    project.grid = Grid(beats: (0..<230).map { Beat(number: $0, time: 1 + Double($0) * 0.5) })
    while project.tracks.count < 4 { _ = project.addTrack() }
    for track in 0..<4 {
        for place in 0..<8 {
            let start = 2.07 + Double(place) * 1.52 + Double(track) * 0.11
            let takes = (place + track) % 3 == 0 ? 3 : 1
            for _ in 0..<takes {
                let recording = Recording(lengthSamples: 72_000, rawStart: start)
                _ = project.addRecording(
                    recording, samples: 0..<72_000, asClipOn: project.tracks[track].id, aim: RecordAim(place: start), voices: .none
                )
            }
        }
        for clip in project.tracks[track].clips.indices {
            project.tracks[track].clips[clip].tighten = clip % 4 == 3 ? .off : (clip % 4 == 2 ? .all : .lines)
            project.tracks[track].clips[clip].strength = clip % 2 == 0 ? 1 : 0.8
        }
    }
    project.normalizeTakes()
    return project
}

@Suite("ProjectLookup")
struct ProjectLookupTests {
    @Test func everyAnswerIsTheProjectsOwn() {
        let project = projectWithManyClips()
        let lookup = ProjectLookup(project)
        #expect(project.tracks.flatMap(\.clips).count > 40)
        for recording in project.recordings {
            #expect(lookup.recording(recording.id) == project.recording(recording.id))
        }
        for track in project.tracks {
            #expect(lookup.track(track.id) == project.track(track.id))
            #expect(lookup.takeGroups(on: track.id) == project.takeGroups(on: track.id))
            #expect(lookup.takeGroups(on: track.id).contains { $0.count == 3 })
            for clip in track.clips {
                #expect(lookup.clip(clip.id) == project.clip(clip.id))
                #expect(lookup.trackID(ofClip: clip.id) == track.id)
                #expect(lookup.start(of: clip) == project.start(of: clip))
                #expect(lookup.end(of: clip) == project.end(of: clip))
                #expect(lookup.takes(of: clip.id) == project.takes(of: clip.id))
                for segment in clip.segments {
                    #expect(lookup.start(of: segment) == project.start(of: segment))
                    #expect(lookup.end(of: segment) == project.end(of: segment))
                }
            }
        }
    }

    @Test func theMarkersOfAClipAreTheProjectsOwn() {
        var project = projectWithManyClips()
        let markers = Dictionary(uniqueKeysWithValues: project.recordings.map { recording in
            (recording.id, [9_000, 30_000, 52_000].map { SyllableMarker(sample: $0, strength: 20) })
        })
        project.recordings[0].setExcluded(true, markerAt: 30_000, among: markers[project.recordings[0].id]!)
        let lookup = ProjectLookup(project)
        for clip in project.tracks.flatMap(\.clips) {
            #expect(lookup.markers(in: clip, allMarkers: markers) == project.markers(in: clip, allMarkers: markers))
        }
        #expect(lookup.markers(in: project.tracks[0].clips[0], allMarkers: markers).count == 3)
    }

    @Test func whetherAClipCanBeSplitIsTheProjectsOwnAnswer() {
        let project = projectWithManyClips()
        let lookup = ProjectLookup(project)
        let clip = project.tracks[1].clips[0]
        let start = project.start(of: clip)!
        for seconds in [start - 1, start, start + 0.001, start + 0.7, start + 1.499, start + 1.5, start + 3, .nan] {
            #expect(lookup.canSplit(clip: clip.id, at: seconds) == project.canSplit(clip: clip.id, at: seconds))
        }
        #expect(lookup.canSplit(clip: clip.id, at: start + 0.7))
        #expect(!lookup.canSplit(clip: UUID(), at: start + 0.7))
    }

    @Test func whatTheProjectDoesNotHaveIsNil() {
        let project = projectWithManyClips()
        let lookup = ProjectLookup(project)
        let unknown = UUID()
        #expect(lookup.recording(unknown) == nil)
        #expect(lookup.track(unknown) == nil)
        #expect(lookup.clip(unknown) == nil)
        #expect(lookup.trackID(ofClip: unknown) == nil)
        #expect(lookup.takes(of: unknown).isEmpty)
        #expect(lookup.takeGroups(on: unknown).isEmpty)
        let segment = Segment(recordingID: unknown, inSample: 0, outSample: 48_000)
        #expect(lookup.start(of: segment) == nil)
        #expect(lookup.end(of: segment) == nil)
        var clip = Clip()
        clip.segments = []
        #expect(lookup.start(of: clip) == nil)
    }

    @Test func theFirstOfTwoWithOneIDIsFound() {
        // A recording or a clip that is in the project twice is found as the project finds it: the first.
        var project = projectWithManyClips()
        var again = project.recordings[3]
        again.rawStart += 5
        project.recordings.append(again)
        var copy = project.tracks[0].clips[2]
        copy.name = "the second"
        project.tracks[2].clips.append(copy)
        let lookup = ProjectLookup(project)
        #expect(lookup.recording(again.id) == project.recordings[3])
        #expect(lookup.clip(copy.id) == project.tracks[0].clips[2])
        #expect(lookup.trackID(ofClip: copy.id) == project.tracks[0].id)
        #expect(lookup.recordingOrder(again.id) == 3)
    }

    @Test func takesComeInTheOrderRecordedAfterAnEdit() {
        var project = projectWithManyClips()
        let track = project.tracks[1]
        let group = project.takeGroups(on: track.id)[0]
        // The first take of a line is chosen, and one of the others deleted.
        project.setActiveTake(group[0].id)
        project.removeClips([group[1].id])
        project.normalizeTakes()
        let lookup = ProjectLookup(project)
        #expect(lookup.takes(of: group[0].id).map(\.id) == [group[0].id, group[2].id])
        #expect(lookup.takes(of: group[0].id) == project.takes(of: group[0].id))
        #expect(lookup.takeGroups(on: track.id) == project.takeGroups(on: track.id))
    }
}
