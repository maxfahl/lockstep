import Foundation
import Testing
@testable import LockstepCore

/// The answer of a call that changes what it is called on. Such a call cannot stand inside `#expect` itself.
private func answer<Answer>(_ change: () -> Answer) -> Answer {
    change()
}

/// A twenty-second song with two empty tracks.
private func song() -> Project {
    var project = Project(songLengthSamples: 960_000)
    project.addTrack()
    return project
}

/// Records a clip the way the app does: a new recording whose clip begins `start` seconds into the song and is
/// `seconds` long. Returns the id of the clip.
@discardableResult
private func record(_ start: Double, _ seconds: Double = 1, in project: inout Project, track: Int = 0) -> UUID {
    let recording = Recording(lengthSamples: Int((seconds * Lockstep.sampleRate).rounded()), rawStart: start)
    return project.addRecording(recording, samples: 0..<recording.lengthSamples, asClipOn: project.tracks[track].id, voices: .none)!
}

private let rapLead = SoundPreset.builtIn[0].sound
private let sungHook = SoundPreset.builtIn[4].sound

@Suite("A track's Sound and a clip's own knobs")
@MainActor
struct ProjectSoundsTests {
    // MARK: A track's Sound

    @Test func aTrackGetsASoundAndLosesItAgainAndSaysWhetherAnythingChanged() {
        var project = song()
        let track = project.tracks[0].id
        #expect(project.tracks[0].sound == nil)
        #expect(!answer { project.setTrack(track, sound: nil) })

        #expect(answer { project.setTrack(track, sound: rapLead) })
        #expect(project.tracks[0].sound == rapLead)
        #expect(project.tracks[1].sound == nil)
        #expect(!answer { project.setTrack(track, sound: rapLead) })

        #expect(answer { project.setTrack(track, sound: sungHook) })
        #expect(project.tracks[0].sound?.character == .sungHook)
        #expect(answer { project.setTrack(track, sound: nil) })
        #expect(project.tracks[0].sound == nil)
        #expect(!answer { project.setTrack(UUID(), sound: rapLead) })
    }

    @Test func aTracksKnobsAreTurnedTogetherAndKeptInWholePercent() {
        var project = song()
        let track = project.tracks[0].id
        let knobs = SoundKnobs(squeeze: 0.333, tone: 1.7, warmth: -0.2, space: 0.5)
        // A track without a Sound has no knobs to turn.
        #expect(!answer { project.setTrack(track, knobs: knobs) })

        project.setTrack(track, sound: rapLead)
        #expect(answer { project.setTrack(track, knobs: knobs) })
        #expect(project.tracks[0].sound == TrackSound(
            name: "Rap lead", character: .rapLead, knobs: SoundKnobs(squeeze: 0.33, tone: 1, warmth: 0, space: 0.5)
        ))
        // The same position again, or one that is the same whole percent, changes nothing.
        #expect(!answer { project.setTrack(track, knobs: knobs) })
        #expect(!answer { project.setTrack(track, knobs: SoundKnobs(squeeze: 0.3349, tone: 1, warmth: 0, space: 0.5)) })
    }

    @Test func aChosenSoundIsKeptInWholePercentToo() {
        var project = song()
        var sound = rapLead
        sound.knobs.space = 0.0849
        project.setTrack(project.tracks[0].id, sound: sound)
        #expect(project.tracks[0].sound?.knobs.space == 0.08)
    }

    // MARK: A clip's own knobs

    @Test func aClipFollowsItsTrackUntilOneOfItsOwnKnobsIsTurned() throws {
        var project = song()
        let clip = record(2, in: &project)
        // No Sound on the track: nothing for the chain.
        #expect(project.chainParameters(of: try #require(project.clip(clip))) == nil)
        #expect(project.knobs(of: try #require(project.clip(clip))) == nil)

        project.setTrack(project.tracks[0].id, sound: rapLead)
        #expect(project.knobs(of: try #require(project.clip(clip))) == rapLead.knobs)
        #expect(project.chainParameters(of: try #require(project.clip(clip))) == SoundCharacter.rapLead.parameters(rapLead.knobs))

        #expect(answer { project.setClips([clip], knob: .space, to: 0.6) })
        var own = rapLead.knobs
        own.space = 0.6
        #expect(project.clip(clip)?.knobs == ClipKnobs(space: 0.6))
        #expect(project.knobs(of: try #require(project.clip(clip))) == own)
        #expect(project.chainParameters(of: try #require(project.clip(clip))) == SoundCharacter.rapLead.parameters(own))

        // The other knobs still follow the track.
        var turned = rapLead.knobs
        turned.squeeze = 0.2
        project.setTrack(project.tracks[0].id, knobs: turned)
        own.squeeze = 0.2
        #expect(project.knobs(of: try #require(project.clip(clip))) == own)
    }

    @Test func aTurnedKnobIsPutBackToTheTracksValue() throws {
        var project = song()
        let clip = record(2, in: &project)
        project.setTrack(project.tracks[0].id, sound: rapLead)
        // Nothing to put back yet.
        #expect(!answer { project.resetClips([clip], knob: .space) })

        project.setClips([clip], knob: .space, to: 0.6)
        project.setClips([clip], knob: .tone, to: 0.1)
        #expect(answer { project.resetClips([clip], knob: .space) })
        #expect(project.clip(clip)?.knobs == ClipKnobs(tone: 0.1))
        #expect(!answer { project.resetClips([clip], knob: .space) })
        #expect(answer { project.resetClips([clip], knob: .tone) })
        #expect(project.clip(clip)?.knobs.isEmpty == true)
        #expect(project.knobs(of: try #require(project.clip(clip))) == rapLead.knobs)
    }

    @Test func aClipsKnobIsHeldBetweenNothingAndAllInWholePercentAndSaysWhetherItChanged() {
        var project = song()
        let clip = record(2, in: &project)
        #expect(answer { project.setClips([clip], knob: .warmth, to: 0.456) })
        #expect(project.clip(clip)?.knobs.warmth == 0.46)
        #expect(!answer { project.setClips([clip], knob: .warmth, to: 0.46) })
        #expect(!answer { project.setClips([clip], knob: .warmth, to: 0.4649) })
        #expect(answer { project.setClips([clip], knob: .warmth, to: 9) })
        #expect(project.clip(clip)?.knobs.warmth == 1)
        #expect(answer { project.setClips([clip], knob: .warmth, to: -3) })
        #expect(project.clip(clip)?.knobs.warmth == 0)
        #expect(!answer { project.setClips([UUID()], knob: .warmth, to: 0.5) })
        // A knob turned to the track's own value is still the clip's own: it stays when the track is turned.
        project.setTrack(project.tracks[0].id, sound: rapLead)
        #expect(answer { project.setClips([clip], knob: .tone, to: rapLead.knobs.tone) })
        #expect(project.clip(clip)?.knobs.tone == rapLead.knobs.tone)
    }

    @Test func aClipKeepsItsKnobsWhileItsTrackHasNoSound() throws {
        var project = song()
        let clip = record(2, in: &project)
        #expect(answer { project.setClips([clip], knob: .space, to: 0.9) })
        #expect(project.chainParameters(of: try #require(project.clip(clip))) == nil)

        project.setTrack(project.tracks[0].id, sound: sungHook)
        #expect(project.chainParameters(of: try #require(project.clip(clip)))?.reverb?.mix
            == SoundCharacter.sungHook.parameters(SoundKnobs(squeeze: 0, tone: 0, warmth: 0, space: 0.9)).reverb?.mix)
        project.setTrack(project.tracks[0].id, sound: nil)
        #expect(project.clip(clip)?.knobs == ClipKnobs(space: 0.9))
    }

    @Test func aKnobReachesTheTakesWaitingBehindTheClipAndNoOtherLine() {
        var project = song()
        let first = record(2, in: &project)
        let second = record(2, in: &project)
        let other = record(6, in: &project)
        #expect(project.takes(of: first).map(\.id) == [first, second])

        #expect(answer { project.setClips([second], knob: .squeeze, to: 0.3) })
        #expect(project.clip(first)?.knobs.squeeze == 0.3)
        #expect(project.clip(second)?.knobs.squeeze == 0.3)
        #expect(project.clip(other)?.knobs.isEmpty == true)

        #expect(answer { project.resetClips([first], knob: .squeeze) })
        #expect(project.clip(first)?.knobs.isEmpty == true)
        #expect(project.clip(second)?.knobs.isEmpty == true)
    }

    @Test func aNewTakeStartsWithTheKnobsOfTheTakeHeardUntilThen() {
        var project = song()
        let first = record(2, in: &project)
        project.setClips([first], knob: .space, to: 0.7)
        let second = record(2, in: &project)
        #expect(project.takes(of: first).map(\.id) == [first, second])
        #expect(project.clip(second)?.knobs == ClipKnobs(space: 0.7))
        // A clip on a line of its own follows its track.
        let other = record(6, in: &project)
        #expect(project.clip(other)?.knobs.isEmpty == true)
    }

    @Test func eachEditIsOneUndoStep() {
        var start = song()
        let clip = record(2, in: &start)
        let track = start.tracks[0].id
        let store = ProjectStore(project: start)

        store.edit("Choose Sound") { $0.setTrack(track, sound: rapLead) }
        let chosen = store.project
        store.edit("Change Clip Sound") { $0.setClips([clip], knob: .space, to: 0.6) }
        let turned = store.project
        store.edit("Reset Knob") { $0.resetClips([clip], knob: .space) }
        #expect(store.project == chosen)

        store.undo()
        #expect(store.project == turned)
        store.undo()
        #expect(store.project == chosen)
        store.undo()
        #expect(store.project.tracks[0].sound == nil)
        store.redo()
        #expect(store.project == chosen)
    }

    // MARK: Through the other edits

    @Test func aSplitKeepsTheKnobsOnBothPieces() throws {
        var project = song()
        let clip = record(2, 2, in: &project)
        project.setTrack(project.tracks[0].id, sound: rapLead)
        project.setClips([clip], knob: .space, to: 0.6)
        project.setClips([clip], knob: .warmth, to: 0.1)

        let pieces = try #require(answer { project.splitClip(clip, at: 3, voices: .none) })
        let knobs = ClipKnobs(warmth: 0.1, space: 0.6)
        #expect(project.clip(pieces.first)?.knobs == knobs)
        #expect(project.clip(pieces.second)?.knobs == knobs)
    }

    @Test func aJoinedClipKeepsTheFirstClipsKnobs() throws {
        var project = song()
        let first = record(2, in: &project)
        let second = record(4, in: &project)
        project.setClips([first], knob: .tone, to: 0.2)
        project.setClips([second], knob: .space, to: 0.9)

        let joined = try #require(answer { project.joinClips([first, second], voices: .none) })
        #expect(project.clip(joined)?.knobs == ClipKnobs(tone: 0.2))
    }

    @Test func aCopyKeepsTheKnobsAndFollowsTheTrackItLandsOn() throws {
        var project = song()
        let clip = record(2, in: &project)
        project.setTrack(project.tracks[0].id, sound: rapLead)
        project.setTrack(project.tracks[1].id, sound: sungHook)
        project.setClips([clip], knob: .space, to: 0.6)

        let pasted = project.paste(project.copyClips([clip]), onTrack: project.tracks[1].id, atSample: 48_000 * 6, voices: .none)
        let copy = try #require(pasted.first.flatMap { project.clip($0.id) })
        #expect(copy.knobs == ClipKnobs(space: 0.6))
        var own = sungHook.knobs
        own.space = 0.6
        #expect(project.chainParameters(of: copy) == SoundCharacter.sungHook.parameters(own))

        // A drag with Option held.
        let dragged = project.duplicateClips([clip], by: ClipMove(samples: 48_000 * 10, trackSteps: 0), voices: .none)
        #expect(dragged.first?.knobs == ClipKnobs(space: 0.6))
    }

    @Test func duplicateTrackKeepsTheSoundAndTheClipsKnobs() throws {
        var project = song()
        let clip = record(2, in: &project)
        project.setTrack(project.tracks[0].id, sound: rapLead)
        project.setClips([clip], knob: .squeeze, to: 0.4)

        let copy = try #require(answer { project.duplicateTrack(project.tracks[0].id, withClips: true) })
        let track = try #require(project.track(copy))
        #expect(track.sound == rapLead)
        #expect(track.clips.map(\.knobs) == [ClipKnobs(squeeze: 0.4)])

        let empty = try #require(answer { project.duplicateTrack(project.tracks[0].id, withClips: false) })
        #expect(project.track(empty)?.sound == rapLead)
    }

    @Test func mergedClipsFollowTheSoundOfTheTrackTheyComeToAndKeepTheirOwnKnobs() throws {
        var project = song()
        let clip = record(2, in: &project, track: 0)
        project.setTrack(project.tracks[0].id, sound: rapLead)
        project.setTrack(project.tracks[1].id, sound: sungHook)
        project.setClips([clip], knob: .space, to: 0.6)

        #expect(answer { project.mergeTrack(project.tracks[0].id, into: project.tracks[1].id, voices: .none) })
        #expect(project.tracks.count == 1)
        #expect(project.tracks[0].sound == sungHook)
        let came = try #require(project.clip(clip))
        #expect(came.knobs == ClipKnobs(space: 0.6))
        var own = sungHook.knobs
        own.space = 0.6
        #expect(project.chainParameters(of: came) == SoundCharacter.sungHook.parameters(own))
    }
}
