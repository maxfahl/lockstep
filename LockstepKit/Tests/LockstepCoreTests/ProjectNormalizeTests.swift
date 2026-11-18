import Foundation
import Testing
@testable import LockstepCore

/// A 997 Hz tone whose highest sample is `db` dBFS, `seconds` long.
private func tone(_ db: Double, seconds: Double) -> [Float] {
    let amplitude = pow(10, db / 20)
    return (0..<Int(seconds * 48_000)).map { Float(amplitude * sin(2 * .pi * 997 * Double($0) / 48_000)) }
}

/// How loud a clip is heard after Normalize, in LUFS: what it plays, with `normalizeGainDb` applied.
private func normalizedLoudness(of clip: Clip, _ sounds: [UUID: [Float]]) -> Double? {
    let gain = Float(pow(10, (clip.normalizeGainDb ?? 0) / 20))
    return Loudness.integrated(Loudness.samples(of: clip) { sounds[$0] }.map { $0 * gain })
}

@Suite("Project normalize")
struct ProjectNormalizeTests {
    /// A six-second recording at the start of the song: three seconds of a loud tone, then three of a quiet one.
    /// A second, silent recording starts at ten seconds. One track with a clip on each of the three.
    private struct Song {
        var project: Project
        var sounds: [UUID: [Float]]
        var loud: UUID
        var quiet: UUID
        var silent: UUID
    }

    private func makeSong() -> Song {
        let voice = Recording(lengthSamples: 288_000, rawStart: 0)
        let nothing = Recording(lengthSamples: 96_000, rawStart: 10)
        let loud = Clip(segments: [Segment(recordingID: voice.id, inSample: 0, outSample: 144_000)], gainDb: 3)
        let quiet = Clip(segments: [Segment(recordingID: voice.id, inSample: 144_000, outSample: 288_000)], gainDb: -2)
        let silent = Clip(segments: [Segment(recordingID: nothing.id, inSample: 0, outSample: 96_000)], gainDb: 1)
        let project = Project(
            songLengthSamples: 960_000,
            tracks: [Track(name: "Track 1", clips: [loud, quiet, silent])],
            recordings: [voice, nothing]
        )
        let sounds = [
            voice.id: tone(-6, seconds: 3) + tone(-30, seconds: 3),
            nothing.id: [Float](repeating: 0, count: 96_000),
        ]
        return Song(project: project, sounds: sounds, loud: loud.id, quiet: quiet.id, silent: silent.id)
    }

    @Test func clipsAtDifferentLevelsEndAtTheTarget() throws {
        let song = makeSong()
        var project = song.project
        let changed = project.normalize(clips: [song.loud, song.quiet], target: -18) { song.sounds[$0] }
        #expect(changed)

        let loud = try #require(project.clip(song.loud))
        let quiet = try #require(project.clip(song.quiet))
        // They started 24 dB apart.
        #expect(abs((quiet.normalizeGainDb ?? 0) - (loud.normalizeGainDb ?? 0) - 24) < 0.2)
        #expect(abs(try #require(normalizedLoudness(of: loud, song.sounds)) + 18) < 0.2)
        #expect(abs(try #require(normalizedLoudness(of: quiet, song.sounds)) + 18) < 0.2)
    }

    @Test func aClipThatWasNotChosenIsLeftAlone() {
        let song = makeSong()
        var project = song.project
        project.normalize(clips: [song.loud], target: -18) { song.sounds[$0] }
        #expect(project.clip(song.loud)?.normalizeGainDb != nil)
        #expect(project.clip(song.quiet)?.normalizeGainDb == nil)
    }

    @Test func aSilentClipIsUntouched() {
        let song = makeSong()
        var project = song.project
        project.normalize(clips: [song.silent], target: -18) { song.sounds[$0] }
        #expect(project == song.project)

        // Also one that was given a value before, and one whose recording has no sound at all.
        project.tracks[0].clips[2].normalizeGainDb = 4
        let before = project
        let changed = project.normalize(clips: [song.silent, song.loud], target: -18) { _ in nil }
        #expect(!changed)
        #expect(project == before)
    }

    @Test func theClipsOwnVolumeIsUnchanged() {
        let song = makeSong()
        var project = song.project
        project.normalizeTrack(project.tracks[0].id, target: -18) { song.sounds[$0] }
        #expect(project.clip(song.loud)?.gainDb == 3)
        #expect(project.clip(song.quiet)?.gainDb == -2)
        #expect(project.clip(song.silent)?.gainDb == 1)
        // Nothing but the normalising was written.
        var expected = song.project
        for index in expected.tracks[0].clips.indices {
            expected.tracks[0].clips[index].normalizeGainDb = project.tracks[0].clips[index].normalizeGainDb
        }
        #expect(project == expected)
    }

    @Test func normalizeTrackTakesEveryClipOfTheTrackAndNoOther() {
        let song = makeSong()
        var project = song.project
        let other = Recording(lengthSamples: 144_000, rawStart: 20)
        let elsewhere = Clip(segments: [Segment(recordingID: other.id, inSample: 0, outSample: 144_000)])
        project.recordings.append(other)
        project.tracks.append(Track(name: "Track 2", clips: [elsewhere]))
        var sounds = song.sounds
        sounds[other.id] = tone(-12, seconds: 3)

        project.normalizeTrack(project.tracks[0].id, target: -20) { sounds[$0] }
        #expect(project.clip(song.loud)?.normalizeGainDb != nil)
        #expect(project.clip(song.quiet)?.normalizeGainDb != nil)
        #expect(project.clip(elsewhere.id)?.normalizeGainDb == nil)
    }

    @Test func everyTakeOfAClipGetsAValue() throws {
        // Two recordings of the same line, the second one 10 dB quieter and the active take.
        let first = Recording(lengthSamples: 144_000, rawStart: 2)
        let second = Recording(lengthSamples: 144_000, rawStart: 2)
        let waiting = Clip(
            segments: [Segment(recordingID: first.id, inSample: 0, outSample: 144_000)],
            isActiveTake: false
        )
        let active = Clip(
            segments: [Segment(recordingID: second.id, inSample: 0, outSample: 144_000)],
            line: waiting.line
        )
        var project = Project(
            songLengthSamples: 960_000,
            tracks: [Track(name: "Track 1", clips: [waiting, active])],
            recordings: [first, second]
        )
        let sounds = [first.id: tone(-10, seconds: 3), second.id: tone(-20, seconds: 3)]
        try #require(project.takes(of: active.id).count == 2)

        project.normalize(clips: [active.id], target: -18) { sounds[$0] }

        let takes = project.takes(of: active.id)
        #expect(takes.allSatisfy { $0.normalizeGainDb != nil })
        // Each take by its own loudness, so both are heard at the target.
        for take in takes {
            #expect(abs(try #require(normalizedLoudness(of: take, sounds)) + 18) < 0.2)
        }
    }

    @Test func measuringFirstGivesTheSameAsInOneGo() {
        let song = makeSong()
        var inOneGo = song.project
        inOneGo.normalize(clips: [song.loud, song.quiet, song.silent], target: -16) { song.sounds[$0] }

        var inTwoSteps = song.project
        let clips = inTwoSteps.clipsToNormalize([song.loud, song.quiet, song.silent])
        let loudness = Project.loudness(of: clips) { song.sounds[$0] }
        #expect(loudness[song.silent] == nil)
        inTwoSteps.normalize(clips: [song.loud, song.quiet, song.silent], target: -16, loudness: loudness)
        #expect(inTwoSteps == inOneGo)
    }

    @MainActor
    @Test func undoRestoresTheOldValues() {
        let song = makeSong()
        var start = song.project
        start.tracks[0].clips[0].normalizeGainDb = 2.5
        let store = ProjectStore(project: start)
        store.undoManager.groupsByEvent = false

        store.edit("Normalize") { project in
            project.normalize(clips: [song.loud, song.quiet], target: -18) { song.sounds[$0] }
        }
        #expect(store.project != start)
        #expect(store.undoTitle == "Undo Normalize")

        store.undo()
        #expect(store.project == start)
        #expect(store.project.clip(song.loud)?.normalizeGainDb == 2.5)
        #expect(store.project.clip(song.quiet)?.normalizeGainDb == nil)
    }
}
