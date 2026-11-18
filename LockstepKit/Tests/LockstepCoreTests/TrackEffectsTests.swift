import Foundation
import Testing
@testable import LockstepCore

/// The answer of a call that changes what it is called on. Such a call cannot stand inside `#expect` itself.
private func answer<Answer>(_ change: () -> Answer) -> Answer {
    change()
}

/// A twenty-second song with two empty tracks and a beat every half second.
private func song() -> Project {
    var project = Project(
        songLengthSamples: 960_000,
        grid: Grid(beats: (0..<40).map { Beat(number: $0, time: Double($0) * 0.5) })
    )
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

/// An id that is the same in every run, so the saved text is too.
private func id(_ number: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number))!
}

private func recipe(of clipID: UUID, in project: Project) -> ClipSoundRecipe? {
    project.clip(clipID).flatMap { ClipSoundRecipe(of: $0, in: project, edgeFadeMs: 5, voices: .none) }
}

@Suite("A track's effects and a clip's changes in the project file")
struct TrackEffectShapesTests {
    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/\(name)"))
    }

    @Test func aProjectSavedBeforeHasNeitherAndIsWrittenToTheSameText() throws {
        let before = try fixture("project-before-sounds.json")
        let read = try ProjectPackage.decode(before)
        #expect(read.tracks.count == 2)
        #expect(read.tracks.allSatisfy { $0.effects.isEmpty })
        #expect(read.tracks.flatMap(\.clips).count == 2)
        #expect(read.tracks.flatMap(\.clips).allSatisfy { $0.effectChanges.isEmpty })
        #expect(try ProjectPackage.encode(read) == before)
    }

    @Test func aTracksEffectsAndAClipsChangesAreWrittenAndReadBackTheSame() throws {
        var project = song()
        project.tracks[0].effects = [
            ClipEffect(id: id(40), kind: .thick, levelDb: -9),
            ClipEffect(id: id(41), kind: .phone),
        ]
        let changed = record(2, in: &project)
        let other = record(6, in: &project)
        project.setClips([changed], trackEffect: id(40), levelDb: -6)
        project.setClips([changed], trackEffect: id(41), isOff: true)

        let text = try ProjectPackage.encode(project)
        let read = try ProjectPackage.decode(text)
        #expect(read == project)
        #expect(read.tracks[0].effects.map(\.kind) == [.thick, .phone])
        #expect(read.clip(changed)?.effectChanges == [
            ClipEffectChange(effectID: id(40), levelDb: -6),
            ClipEffectChange(effectID: id(41), isOff: true),
        ])
        #expect(read.clip(other)?.effectChanges.isEmpty == true)

        // The track and the clip that have none say nothing about it, and a change says only what it changes.
        let saved = try #require(JSONSerialization.jsonObject(with: text) as? [String: Any])
        let tracks = try #require(saved["tracks"] as? [[String: Any]])
        let clips = try #require(tracks[0]["clips"] as? [[String: Any]])
        #expect((tracks[0]["effects"] as? [[String: Any]])?.count == 2)
        #expect((tracks[0]["effects"] as? [[String: Any]])?.first?["kind"] as? String == "thick")
        #expect(tracks[1]["effects"] == nil)
        let changes = try #require(clips[0]["effectChanges"] as? [[String: Any]])
        #expect(changes.count == 2)
        #expect(changes[0]["effect"] as? String == id(40).uuidString)
        #expect(changes[0]["levelDb"] as? Double == -6)
        #expect(changes[0]["off"] == nil)
        #expect(changes[1]["effect"] as? String == id(41).uuidString)
        #expect(changes[1]["levelDb"] == nil)
        #expect(changes[1]["off"] as? Bool == true)
        #expect(clips[0]["effects"] == nil)
        #expect(clips[1]["effectChanges"] == nil)
    }

    @Test func aSpanOnATracksEffectIsDroppedAnUnknownKindIsSkippedAndAChangeOfNothingIsNotKept() throws {
        let recording = id(1).uuidString
        let text = """
        {"tracks":[{"name":"Track 1",
          "effects":[
            {"id":"\(id(40).uuidString)","kind":"thick","levelDb":-9,
             "span":{"recordingID":"\(recording)","inSample":100,"outSample":200}},
            {"id":"\(id(41).uuidString)","kind":"robot","levelDb":-3,"depth":7},
            {"id":"\(id(42).uuidString)","kind":"echoQuarter","levelDb":-6}
          ],
          "clips":[{
            "id":"\(id(10).uuidString)",
            "name":"Verse",
            "segments":[{"recordingID":"\(recording)","inSample":0,"outSample":96000}],
            "effectChanges":[
              {"effect":"\(id(40).uuidString)"},
              {"effect":"\(id(42).uuidString)","levelDb":-12},
              {"effect":"\(id(41).uuidString)","off":false},
              {"effect":"\(id(43).uuidString)","off":true}
            ]}]}]}
        """
        let track = try #require(try JSONDecoder().decode(Project.self, from: Data(text.utf8)).tracks.first)
        #expect(track.name == "Track 1")
        #expect(track.effects == [
            ClipEffect(id: id(40), kind: .thick, levelDb: -9),
            ClipEffect(id: id(42), kind: .echoQuarter, levelDb: -6),
        ])
        #expect(track.clips.first?.name == "Verse")
        // The change for an effect the track does not have is kept: it counts for nothing.
        #expect(track.clips.first?.effectChanges == [
            ClipEffectChange(effectID: id(42), levelDb: -12),
            ClipEffectChange(effectID: id(43), isOff: true),
        ])
    }
}

@Suite("What a clip is heard with: its track's effects, then its own")
struct HeardEffectsTests {
    @Test func theTracksEffectsComeFirstInTheTracksOrderAndThenTheClipsOwn() throws {
        var project = song()
        let clip = record(2, in: &project)
        let own = try #require(answer { project.addEffect(clip, kind: .high) })
        #expect(project.effects(heardOn: project.clip(clip)!).map(\.id) == [own])

        let track = project.tracks[0].id
        let thick = try #require(answer { project.addTrackEffect(track, kind: .thick) })
        let phone = try #require(answer { project.addTrackEffect(track, kind: .phone) })
        let heard = project.effects(heardOn: project.clip(clip)!)
        #expect(heard.map(\.id) == [thick, phone, own])
        #expect(heard.map(\.kind) == [.thick, .phone, .high])
        #expect(heard.map(\.levelDb) == [-9, 0, -16])
        #expect(heard.allSatisfy { $0.span == nil })

        // A clip of the other track has none of them.
        let elsewhere = record(2, in: &project, track: 1)
        #expect(project.effects(heardOn: project.clip(elsewhere)!).isEmpty)
    }

    @Test func aClipsOwnLevelCountsAndAnEffectItSwitchedOffIsLeftOut() throws {
        var project = song()
        let clip = record(2, in: &project)
        let follower = record(6, in: &project)
        let track = project.tracks[0].id
        let thick = try #require(answer { project.addTrackEffect(track, kind: .thick) })
        let echo = try #require(answer { project.addTrackEffect(track, kind: .echoEighth) })

        project.setClips([clip], trackEffect: thick, levelDb: -3)
        project.setClips([clip], trackEffect: echo, isOff: true)
        #expect(project.effects(heardOn: project.clip(clip)!) == [ClipEffect(id: thick, kind: .thick, levelDb: -3)])
        #expect(project.effects(heardOn: project.clip(follower)!).map(\.levelDb) == [-9, -6])

        // The track's level moves the clip that follows and not the one with its own level.
        project.setTrackEffect(thick, of: track, levelDb: -12)
        #expect(project.effects(heardOn: project.clip(clip)!).map(\.levelDb) == [-3])
        #expect(project.effects(heardOn: project.clip(follower)!).map(\.levelDb) == [-12, -6])
    }

    @Test func aChangeForAnEffectTheTrackDoesNotHaveCountsForNothing() throws {
        var project = song()
        let clip = record(2, in: &project)
        let thick = try #require(answer { project.addTrackEffect(project.tracks[0].id, kind: .thick) })
        project.tracks[0].clips[0].effectChanges = [
            ClipEffectChange(effectID: UUID(), levelDb: 3),
            ClipEffectChange(effectID: UUID(), isOff: true),
        ]
        #expect(project.effects(heardOn: project.clip(clip)!) == [ClipEffect(id: thick, kind: .thick, levelDb: -9)])
    }

    @Test func theClipIsReadAsItIsHandedInSoADraggedLevelCanBeAskedAbout() throws {
        var project = song()
        let clip = record(2, in: &project)
        let thick = try #require(answer { project.addTrackEffect(project.tracks[0].id, kind: .thick) })
        var dragged = try #require(project.clip(clip))
        dragged.effectChanges = [ClipEffectChange(effectID: thick, levelDb: -20)]
        #expect(project.effects(heardOn: dragged).map(\.levelDb) == [-20])
        #expect(project.effects(heardOn: project.clip(clip)!).map(\.levelDb) == [-9])
        // The track in hand answers the same without looking for it.
        #expect(project.tracks[0].effects(heardOn: dragged) == project.effects(heardOn: dragged))
    }

    // MARK: The recipe

    @Test func aClipOnATrackWithADoubleHasARecipeThoughTheTrackHasNoSound() throws {
        var project = song()
        let clip = record(2, in: &project)
        #expect(recipe(of: clip, in: project) == nil)
        let thick = try #require(answer { project.addTrackEffect(project.tracks[0].id, kind: .thick) })

        let made = try #require(recipe(of: clip, in: project))
        #expect(made.chain == nil)
        #expect(made.effects == [ClipSoundRecipe.HeardEffect(id: thick, kind: .thick, levelDb: -9)])
        #expect(made.beats.isEmpty)
        // Switched off for the clip, it needs no finished sound again.
        project.setClips([clip], trackEffect: thick, isOff: true)
        #expect(recipe(of: clip, in: project) == nil)
    }

    @Test func theRecipeChangesWithTheTracksEffectItsLevelTheClipsOwnLevelAndOff() throws {
        var project = song()
        let clip = record(2, in: &project)
        let track = project.tracks[0].id
        project.setTrack(track, sound: SoundPreset.builtIn[0].sound)
        let plain = try #require(recipe(of: clip, in: project))

        let thick = try #require(answer { project.addTrackEffect(track, kind: .thick) })
        let withEffect = try #require(recipe(of: clip, in: project))
        #expect(withEffect != plain)
        #expect(withEffect.chain == plain.chain)

        project.setTrackEffect(thick, of: track, levelDb: -4)
        let trackTurned = try #require(recipe(of: clip, in: project))
        #expect(trackTurned != withEffect)
        #expect(trackTurned.effects.map(\.levelDb) == [-4])

        project.setClips([clip], trackEffect: thick, levelDb: -15)
        let clipTurned = try #require(recipe(of: clip, in: project))
        #expect(clipTurned != trackTurned)
        #expect(clipTurned.effects.map(\.levelDb) == [-15])

        project.setClips([clip], trackEffect: thick, isOff: true)
        #expect(recipe(of: clip, in: project) == plain)
        project.resetClips([clip], trackEffect: thick)
        #expect(recipe(of: clip, in: project) == trackTurned)
    }

    @Test func aTracksEchoBringsTheBeatsAndComesBeforeAClipsOwnEffectOnAStretch() throws {
        var project = song()
        let clip = record(2, in: &project)
        let recording = try #require(project.clip(clip)?.segments.first?.recordingID)
        let own = try #require(answer { project.addEffect(
            clip, kind: .phone, span: ClipSpan(recordingID: recording, inSample: 4_800, outSample: 24_000)
        ) })
        #expect(recipe(of: clip, in: project)?.beats.isEmpty == true)

        let echo = try #require(answer { project.addTrackEffect(project.tracks[0].id, kind: .echoQuarter) })
        let made = try #require(recipe(of: clip, in: project))
        #expect(made.effects == [
            ClipSoundRecipe.HeardEffect(id: echo, kind: .echoQuarter, levelDb: -6),
            ClipSoundRecipe.HeardEffect(id: own, kind: .phone, levelDb: 0, span: 4_800..<24_000),
        ])
        #expect(!made.beats.isEmpty)
        // What is drawn on the clip stays about its own effects.
        #expect(project.effectStretches(of: project.clip(clip)!, voices: .none).map(\.id) == [own])
    }
}

@Suite("The edits of a track's effects and of a clip's changes")
@MainActor
struct TrackEffectEditsTests {
    // MARK: The track's own

    @Test func anEffectIsAddedAtTheEndAtTheLevelItsKindStartsAt() throws {
        var project = song()
        let track = project.tracks[0].id
        let thick = try #require(answer { project.addTrackEffect(track, kind: .thick) })
        let low = try #require(answer { project.addTrackEffect(track, kind: .lowOctave) })
        // Any of the twelve kinds may be a track's, and two of a kind are two effects.
        let stutter = try #require(answer { project.addTrackEffect(track, kind: .stutter) })
        let again = try #require(answer { project.addTrackEffect(track, kind: .thick) })
        #expect(project.tracks[0].effects == [
            ClipEffect(id: thick, kind: .thick, levelDb: -9),
            ClipEffect(id: low, kind: .lowOctave, levelDb: -10),
            ClipEffect(id: stutter, kind: .stutter, levelDb: 0),
            ClipEffect(id: again, kind: .thick, levelDb: -9),
        ])
        #expect(Set([thick, low, stutter, again]).count == 4)
        #expect(project.tracks[1].effects.isEmpty)
        #expect(project.addTrackEffect(UUID(), kind: .thick) == nil)
    }

    @Test func theTracksLevelIsHeldToItsRangeAndAKindWithoutALevelHasNone() throws {
        var project = song()
        let track = project.tracks[0].id
        let thick = try #require(answer { project.addTrackEffect(track, kind: .thick) })
        let phone = try #require(answer { project.addTrackEffect(track, kind: .phone) })

        #expect(answer { project.setTrackEffect(thick, of: track, levelDb: -6) })
        #expect(project.tracks[0].effects[0].levelDb == -6)
        #expect(!answer { project.setTrackEffect(thick, of: track, levelDb: -6) })
        #expect(answer { project.setTrackEffect(thick, of: track, levelDb: 40) })
        #expect(project.tracks[0].effects[0].levelDb == 6)
        #expect(answer { project.setTrackEffect(thick, of: track, levelDb: -90) })
        #expect(project.tracks[0].effects[0].levelDb == -24)

        #expect(!answer { project.setTrackEffect(phone, of: track, levelDb: -6) })
        #expect(!answer { project.setTrackEffect(thick, of: project.tracks[1].id, levelDb: 0) })
        #expect(!answer { project.setTrackEffect(UUID(), of: track, levelDb: 0) })
    }

    @Test func removingATracksEffectTakesTheClipsChangesOfItAwayTheWaitingTakesToo() throws {
        var project = song()
        let track = project.tracks[0].id
        let first = record(2, in: &project)
        let second = record(2, in: &project)
        let elsewhere = record(2, in: &project, track: 1)
        let thick = try #require(answer { project.addTrackEffect(track, kind: .thick) })
        let echo = try #require(answer { project.addTrackEffect(track, kind: .echoQuarter) })
        project.setClips([second], trackEffect: thick, levelDb: -3)
        project.setClips([second], trackEffect: echo, isOff: true)
        // A clip of another track that names the effect, as one moved away does, keeps what it says.
        project.tracks[1].clips[0].effectChanges = [ClipEffectChange(effectID: thick, isOff: true)]

        #expect(answer { project.removeTrackEffect(thick, from: track) })
        #expect(project.tracks[0].effects.map(\.id) == [echo])
        for take in [first, second] {
            #expect(project.clip(take)?.effectChanges == [ClipEffectChange(effectID: echo, isOff: true)])
        }
        #expect(project.clip(elsewhere)?.effectChanges == [ClipEffectChange(effectID: thick, isOff: true)])
        #expect(!answer { project.removeTrackEffect(thick, from: track) })
        #expect(!answer { project.removeTrackEffect(echo, from: project.tracks[1].id) })
    }

    // MARK: A clip's changes

    @Test func aClipsOwnLevelReachesItsWaitingTakesAndIsItsOwnAlsoWhenItEqualsTheTracks() throws {
        var project = song()
        let track = project.tracks[0].id
        let first = record(2, in: &project)
        let second = record(2, in: &project)
        let other = record(6, in: &project)
        let elsewhere = record(2, in: &project, track: 1)
        let thick = try #require(answer { project.addTrackEffect(track, kind: .thick) })
        let phone = try #require(answer { project.addTrackEffect(track, kind: .phone) })
        #expect(project.takes(of: first).map(\.id) == [first, second])

        // The track's own level: the clip no longer follows the track with it.
        #expect(answer { project.setClips([second], trackEffect: thick, levelDb: -9) })
        #expect(project.clip(first)?.effectChanges == [ClipEffectChange(effectID: thick, levelDb: -9)])
        #expect(project.clip(second)?.effectChanges == [ClipEffectChange(effectID: thick, levelDb: -9)])
        #expect(project.clip(other)?.effectChanges.isEmpty == true)
        #expect(!answer { project.setClips([first], trackEffect: thick, levelDb: -9) })
        project.setTrackEffect(thick, of: track, levelDb: 0)
        #expect(project.effects(heardOn: project.clip(second)!).first?.levelDb == -9)

        #expect(answer { project.setClips([first], trackEffect: thick, levelDb: 90) })
        #expect(project.clip(second)?.effectChanges == [ClipEffectChange(effectID: thick, levelDb: 6)])

        // Nothing for a kind without a level, for a clip of another track, or for an effect no track has.
        #expect(!answer { project.setClips([first], trackEffect: phone, levelDb: -3) })
        #expect(!answer { project.setClips([elsewhere], trackEffect: thick, levelDb: -3) })
        #expect(project.clip(elsewhere)?.effectChanges.isEmpty == true)
        #expect(!answer { project.setClips([first], trackEffect: UUID(), levelDb: -3) })
    }

    @Test func anEffectIsSwitchedOffAndOnForAClipAndItsTakesAndKeepsTheClipsLevel() throws {
        var project = song()
        let track = project.tracks[0].id
        let first = record(2, in: &project)
        let second = record(2, in: &project)
        let other = record(6, in: &project)
        let thick = try #require(answer { project.addTrackEffect(track, kind: .thick) })
        let phone = try #require(answer { project.addTrackEffect(track, kind: .phone) })

        #expect(!answer { project.setClips([first], trackEffect: thick, isOff: false) })
        #expect(answer { project.setClips([first], trackEffect: thick, isOff: true) })
        #expect(project.clip(second)?.effectChanges == [ClipEffectChange(effectID: thick, isOff: true)])
        #expect(project.clip(other)?.effectChanges.isEmpty == true)
        #expect(!answer { project.setClips([second], trackEffect: thick, isOff: true) })
        // On again without a level of its own: nothing is left to keep.
        #expect(answer { project.setClips([second], trackEffect: thick, isOff: false) })
        #expect(project.clip(first)?.effectChanges.isEmpty == true)
        #expect(project.clip(second)?.effectChanges.isEmpty == true)

        // With a level of its own, the level is there again when the effect is switched on.
        project.setClips([first], trackEffect: thick, levelDb: -4)
        project.setClips([first], trackEffect: thick, isOff: true)
        #expect(project.clip(first)?.effectChanges == [ClipEffectChange(effectID: thick, levelDb: -4, isOff: true)])
        project.setClips([first], trackEffect: thick, isOff: false)
        #expect(project.clip(second)?.effectChanges == [ClipEffectChange(effectID: thick, levelDb: -4)])

        // A kind without a level can be switched off too.
        #expect(answer { project.setClips([other], trackEffect: phone, isOff: true) })
        #expect(project.effects(heardOn: project.clip(other)!).map(\.id) == [thick])
    }

    @Test func puttingBackTakesTheLevelAndTheOffAwayTogether() throws {
        var project = song()
        let track = project.tracks[0].id
        let first = record(2, in: &project)
        let second = record(2, in: &project)
        let thick = try #require(answer { project.addTrackEffect(track, kind: .thick) })
        let echo = try #require(answer { project.addTrackEffect(track, kind: .echoEighth) })
        project.setClips([first], trackEffect: thick, levelDb: -4)
        project.setClips([first], trackEffect: thick, isOff: true)
        project.setClips([first], trackEffect: echo, levelDb: -1)

        #expect(answer { project.resetClips([second], trackEffect: thick) })
        for take in [first, second] {
            #expect(project.clip(take)?.effectChanges == [ClipEffectChange(effectID: echo, levelDb: -1)])
        }
        #expect(project.effects(heardOn: project.clip(first)!).map(\.levelDb) == [-9, -1])
        #expect(!answer { project.resetClips([first], trackEffect: thick) })
    }

    // MARK: What the other edits do

    @Test func aNewTakeStartsWithTheChangesOfTheTakeHeardUntilThen() throws {
        var project = song()
        let first = record(2, in: &project)
        let thick = try #require(answer { project.addTrackEffect(project.tracks[0].id, kind: .thick) })
        project.setClips([first], trackEffect: thick, levelDb: -2)
        let second = record(2, in: &project)
        #expect(project.takes(of: first).map(\.id) == [first, second])
        #expect(project.clip(second)?.effectChanges == [ClipEffectChange(effectID: thick, levelDb: -2)])
        // A clip on a line of its own follows its track, and is heard with the track's effect.
        let other = record(6, in: &project)
        #expect(project.clip(other)?.effectChanges.isEmpty == true)
        #expect(project.effects(heardOn: project.clip(other)!).map(\.levelDb) == [-9])
    }

    @Test func aSplitKeepsTheChangesOnBothPiecesAJoinedClipKeepsTheFirstClipsAndACopyKeepsThem() throws {
        var project = song()
        let track = project.tracks[0].id
        let clip = record(2, 2, in: &project)
        let thick = try #require(answer { project.addTrackEffect(track, kind: .thick) })
        project.setClips([clip], trackEffect: thick, levelDb: -2)
        let change = [ClipEffectChange(effectID: thick, levelDb: -2)]

        let pieces = try #require(answer { project.splitClip(clip, at: 3, voices: .none) })
        #expect(project.clip(pieces.first)?.effectChanges == change)
        #expect(project.clip(pieces.second)?.effectChanges == change)

        project.setClips([pieces.second], trackEffect: thick, isOff: true)
        let joined = try #require(answer { project.joinClips([pieces.first, pieces.second], voices: .none) })
        #expect(project.clip(joined)?.effectChanges == change)
        // The track's effect is not made one of the joined clip's own.
        #expect(project.clip(joined)?.effects.isEmpty == true)

        let copies = project.paste(project.copyClips([joined]), onTrack: track, atSample: 480_000, voices: .none)
        #expect(copies.count == 1)
        #expect(project.clip(copies[0].id)?.effectChanges == change)
        #expect(project.effects(heardOn: project.clip(copies[0].id)!).map(\.levelDb) == [-2])
    }

    @Test func duplicateTrackKeepsTheEffectsWithTheirIdsSoTheCopiedClipsChangesStillHold() throws {
        var project = song()
        let track = project.tracks[0].id
        let clip = record(2, in: &project)
        let thick = try #require(answer { project.addTrackEffect(track, kind: .thick) })
        let phone = try #require(answer { project.addTrackEffect(track, kind: .phone) })
        project.setClips([clip], trackEffect: thick, levelDb: -2)
        project.setClips([clip], trackEffect: phone, isOff: true)

        let copy = try #require(answer { project.duplicateTrack(track, withClips: true) })
        let copied = try #require(project.track(copy))
        #expect(copied.effects == project.tracks[0].effects)
        #expect(copied.effects.map(\.id) == [thick, phone])
        #expect(project.effects(heardOn: copied.clips[0]) == [ClipEffect(id: thick, kind: .thick, levelDb: -2)])
        // Removing the effect from the copy leaves the original track and its clip as they are.
        project.removeTrackEffect(thick, from: copy)
        #expect(project.clip(clip)?.effectChanges.count == 2)
        #expect(project.effects(heardOn: project.clip(clip)!).map(\.levelDb) == [-2])
        // Without its clips the copy still has the effects.
        let empty = try #require(answer { project.duplicateTrack(track, withClips: false) })
        #expect(project.track(empty)?.effects.map(\.id) == [thick, phone])
    }

    @Test func aClipMovedToAnotherTrackFollowsThatTracksEffectsAndHasItsChangesBackAtHome() throws {
        var project = song()
        let home = project.tracks[0].id
        let away = project.tracks[1].id
        let clip = record(2, in: &project)
        let thick = try #require(answer { project.addTrackEffect(home, kind: .thick) })
        let echo = try #require(answer { project.addTrackEffect(away, kind: .echoQuarter) })
        project.setClips([clip], trackEffect: thick, levelDb: -2)

        #expect(!answer { project.moveClips([clip], bySamples: 0, trackSteps: 1, voices: .none) }.isNothing)
        #expect(project.tracks[1].clips.map(\.id) == [clip])
        #expect(project.effects(heardOn: project.clip(clip)!) == [ClipEffect(id: echo, kind: .echoQuarter, levelDb: -6)])
        #expect(project.clip(clip)?.effectChanges == [ClipEffectChange(effectID: thick, levelDb: -2)])

        #expect(!answer { project.moveClips([clip], bySamples: 0, trackSteps: -1, voices: .none) }.isNothing)
        #expect(project.effects(heardOn: project.clip(clip)!) == [ClipEffect(id: thick, kind: .thick, levelDb: -2)])
    }

    @Test func afterMergeIntoTheClipsThatCameFollowTheEffectsOfTheTrackTheyCameTo() throws {
        var project = song()
        let source = project.tracks[0].id
        let target = project.tracks[1].id
        let came = record(2, in: &project)
        let stayed = record(6, in: &project, track: 1)
        let thick = try #require(answer { project.addTrackEffect(source, kind: .thick) })
        let echo = try #require(answer { project.addTrackEffect(target, kind: .echoQuarter) })
        project.setClips([came], trackEffect: thick, isOff: true)

        #expect(answer { project.mergeTrack(source, into: target, voices: .none) })
        #expect(project.tracks.map(\.id) == [target])
        #expect(project.tracks[0].effects.map(\.id) == [echo])
        #expect(project.effects(heardOn: project.clip(came)!).map(\.id) == [echo])
        #expect(project.effects(heardOn: project.clip(stayed)!).map(\.id) == [echo])
    }

    @Test func eachEditIsOneUndoStep() throws {
        var start = song()
        let clip = record(2, in: &start)
        let track = start.tracks[0].id
        let store = ProjectStore(project: start)

        var thick: ClipEffect.ID?
        store.edit("Add Track Effect") { thick = $0.addTrackEffect(track, kind: .thick) }
        let effect = try #require(thick)
        store.edit("Change Effect Level") { $0.setClips([clip], trackEffect: effect, levelDb: -3) }
        store.edit("Remove Track Effect") { $0.removeTrackEffect(effect, from: track) }
        #expect(store.project.tracks[0].effects.isEmpty)
        #expect(store.project.clip(clip)?.effectChanges.isEmpty == true)

        // Undo brings the effect back with what the clip had changed of it.
        store.undo()
        #expect(store.project.tracks[0].effects.map(\.id) == [effect])
        #expect(store.project.clip(clip)?.effectChanges == [ClipEffectChange(effectID: effect, levelDb: -3)])
        store.undo()
        #expect(store.project.clip(clip)?.effectChanges.isEmpty == true)
        store.undo()
        #expect(store.project == start)
    }
}

@Suite("The effects several selected clips share")
struct SharedEffectsTests {
    @Test func oneClipAnswersItsWholeClipEffectsItsTracksFirst() throws {
        var project = song()
        let track = project.tracks[0].id
        let clip = record(2, in: &project)
        let recording = try #require(project.clip(clip)?.segments.first?.recordingID)
        let own = try #require(answer { project.addEffect(clip, kind: .high) })
        try #require(answer { project.addEffect(
            clip, kind: .echoQuarter, span: ClipSpan(recordingID: recording, inSample: 4_800, outSample: 24_000)
        ) } != nil)
        let thick = try #require(answer { project.addTrackEffect(track, kind: .thick) })
        let phone = try #require(answer { project.addTrackEffect(track, kind: .phone) })
        project.setClips([clip], trackEffect: thick, levelDb: -3)
        project.setClips([clip], trackEffect: phone, isOff: true)

        let shared = project.sharedEffects(of: [clip])
        // The effect on a stretch is one take's words and is never listed. The one switched off is.
        #expect(shared.map(\.id) == [thick, phone, own])
        #expect(shared.map(\.kind) == [.thick, .phone, .high])
        #expect(shared.map(\.levelDb) == [-3, 0, -16])
        #expect(shared.map(\.isMixed) == [false, false, false])
        #expect(shared.map(\.isOfTrack) == [true, true, false])
        #expect(shared.map(\.isOff) == [false, true, false])
        #expect(shared.map(\.isChanged) == [true, true, false])
        #expect(shared[0].members == [SharedEffect.Member(clipID: clip, effectID: thick, isOfTrack: true)])
        #expect(shared[2].members == [SharedEffect.Member(clipID: clip, effectID: own, isOfTrack: false)])

        #expect(project.sharedEffects(of: []).isEmpty)
        #expect(project.sharedEffects(of: [UUID()]).isEmpty)
    }

    @Test func twoClipsOfOneTrackShareTheTracksEffectAndSayWhenTheirLevelsDiffer() throws {
        var project = song()
        let track = project.tracks[0].id
        let first = record(2, in: &project)
        let second = record(6, in: &project)
        let thick = try #require(answer { project.addTrackEffect(track, kind: .thick) })

        var shared = project.sharedEffects(of: [first, second])
        #expect(shared.count == 1)
        #expect(shared[0].id == thick)
        #expect(shared[0].members == [
            SharedEffect.Member(clipID: first, effectID: thick, isOfTrack: true),
            SharedEffect.Member(clipID: second, effectID: thick, isOfTrack: true),
        ])
        #expect(shared[0].levelDb == -9)
        #expect(!shared[0].isMixed && shared[0].isOfTrack && !shared[0].isOff && !shared[0].isChanged)

        // One clip with its own level: the mean, and the row reads "Mixed".
        project.setClips([second], trackEffect: thick, levelDb: -3)
        shared = project.sharedEffects(of: [first, second])
        #expect(shared[0].levelDb == -6)
        #expect(shared[0].isMixed && shared[0].isChanged && !shared[0].isOff)

        // Switched off on one clip it is still shared, and off only when it is off on all.
        project.setClips([first], trackEffect: thick, isOff: true)
        shared = project.sharedEffects(of: [first, second])
        #expect(shared.count == 1)
        #expect(!shared[0].isOff && shared[0].isChanged)
        project.setClips([second], trackEffect: thick, isOff: true)
        #expect(project.sharedEffects(of: [first, second])[0].isOff)
    }

    @Test func clipsOfTwoTracksThatEachHaveAThickShareItByItsKind() throws {
        var project = song()
        let upper = record(2, in: &project)
        let lower = record(2, in: &project, track: 1)
        let one = try #require(answer { project.addTrackEffect(project.tracks[0].id, kind: .thick) })
        let two = try #require(answer { project.addTrackEffect(project.tracks[1].id, kind: .thick) })
        try #require(answer { project.addTrackEffect(project.tracks[1].id, kind: .phone) } != nil)
        project.setTrackEffect(two, of: project.tracks[1].id, levelDb: -5)

        let shared = project.sharedEffects(of: [lower, upper])
        // The phone is only the lower clip's: a kind that not every clip has is not listed.
        #expect(shared.count == 1)
        #expect(shared[0].kind == .thick)
        #expect(shared[0].members == [
            SharedEffect.Member(clipID: upper, effectID: one, isOfTrack: true),
            SharedEffect.Member(clipID: lower, effectID: two, isOfTrack: true),
        ])
        #expect(shared[0].id == one)
        #expect(shared[0].levelDb == -7)
        // The levels differ, though neither clip changed anything.
        #expect(shared[0].isMixed && shared[0].isOfTrack && !shared[0].isChanged)
    }

    @Test func aClipsOwnThickAndAnotherClipsTracksThickAreShared() throws {
        var project = song()
        let withOwn = record(2, in: &project, track: 1)
        let onTrack = record(2, in: &project)
        let own = try #require(answer { project.addEffect(withOwn, kind: .thick) })
        let tracks = try #require(answer { project.addTrackEffect(project.tracks[0].id, kind: .thick) })

        let shared = project.sharedEffects(of: [withOwn, onTrack])
        #expect(shared.count == 1)
        #expect(shared[0].members == [
            SharedEffect.Member(clipID: onTrack, effectID: tracks, isOfTrack: true),
            SharedEffect.Member(clipID: withOwn, effectID: own, isOfTrack: false),
        ])
        #expect(!shared[0].isOfTrack && !shared[0].isMixed && !shared[0].isOff)
    }

    @Test func twoOfAKindGoFirstWithFirstAndSecondWithSecond() throws {
        var project = song()
        let first = record(2, in: &project)
        let second = record(6, in: &project)
        let third = record(10, in: &project)
        let a1 = try #require(answer { project.addEffect(first, kind: .thick) })
        let high = try #require(answer { project.addEffect(first, kind: .high) })
        let a2 = try #require(answer { project.addEffect(first, kind: .thick) })
        let b1 = try #require(answer { project.addEffect(second, kind: .thick) })
        let b2 = try #require(answer { project.addEffect(second, kind: .thick) })
        let c1 = try #require(answer { project.addEffect(third, kind: .thick) })
        try #require(answer { project.addEffect(second, kind: .small) } != nil)
        project.setEffect(a2, of: first, levelDb: -1)
        project.setEffect(b2, of: second, levelDb: -3)

        let two = project.sharedEffects(of: [first, second])
        // The High and the Small are each only one clip's.
        #expect(two.map(\.id) == [a1, a2])
        #expect(two[0].members.map(\.effectID) == [a1, b1])
        #expect(two[1].members.map(\.effectID) == [a2, b2])
        #expect(two.map(\.levelDb) == [-9, -2])
        #expect(two.map(\.isMixed) == [false, true])
        #expect(!two.contains { $0.id == high })

        // The third clip has one Thick only, so one is shared by all three.
        let three = project.sharedEffects(of: [first, second, third])
        #expect(three.map(\.members).map { $0.map(\.effectID) } == [[a1, b1, c1]])
    }

    @Test func anEffectOnAStretchIsNeverShared() throws {
        var project = song()
        let first = record(2, in: &project)
        let second = record(6, in: &project)
        for clip in [first, second] {
            let recording = try #require(project.clip(clip)?.segments.first?.recordingID)
            try #require(answer { project.addEffect(
                clip, kind: .echoQuarter, span: ClipSpan(recordingID: recording, inSample: 4_800, outSample: 24_000)
            ) } != nil)
        }
        #expect(project.sharedEffects(of: [first, second]).isEmpty)
    }

    // MARK: Set for all, removed from all

    @Test func theLevelIsSetForAllOwnEffectsAndAsTheClipsOwnLevelForATracks() throws {
        var project = song()
        let withOwn = record(2, in: &project, track: 1)
        let waiting = record(2, in: &project, track: 1)
        let onTrack = record(2, in: &project)
        let own = try #require(answer { project.addEffect(waiting, kind: .thick) })
        let tracks = try #require(answer { project.addTrackEffect(project.tracks[0].id, kind: .thick) })
        #expect(project.takes(of: withOwn).map(\.id) == [withOwn, waiting])

        let shared = try #require(project.sharedEffects(of: [withOwn, onTrack]).first)
        #expect(answer { project.setEffects(shared, levelDb: -4) })
        // The clip's own effect, on its waiting take too, and the other clip's own level for its track's.
        #expect(project.clip(withOwn)?.effects.map(\.levelDb) == [-4])
        #expect(project.clip(waiting)?.effects.map(\.levelDb) == [-4])
        #expect(project.clip(onTrack)?.effectChanges == [ClipEffectChange(effectID: tracks, levelDb: -4)])
        #expect(project.tracks[0].effects.map(\.levelDb) == [-9])
        let after = try #require(project.sharedEffects(of: [withOwn, onTrack]).first)
        #expect(after.id == shared.id)
        #expect(after.levelDb == -4 && !after.isMixed && after.isChanged)
        #expect(after.members.map(\.effectID) == [tracks, own])
        #expect(!answer { project.setEffects(after, levelDb: -4) })
    }

    @Test func removingTakesAClipsOwnEffectAwayAndSwitchesATracksOffForThatClip() throws {
        var project = song()
        let withOwn = record(2, in: &project, track: 1)
        let onTrack = record(2, in: &project)
        let follower = record(6, in: &project)
        try #require(answer { project.addEffect(withOwn, kind: .thick) } != nil)
        let tracks = try #require(answer { project.addTrackEffect(project.tracks[0].id, kind: .thick) })

        let shared = try #require(project.sharedEffects(of: [withOwn, onTrack]).first)
        #expect(answer { project.removeEffects(shared) })
        #expect(project.clip(withOwn)?.effects.isEmpty == true)
        #expect(project.clip(onTrack)?.effectChanges == [ClipEffectChange(effectID: tracks, isOff: true)])
        // The track still has it, and the clip that was not selected is heard with it.
        #expect(project.tracks[0].effects.map(\.id) == [tracks])
        #expect(project.effects(heardOn: project.clip(follower)!).map(\.id) == [tracks])
        #expect(project.effects(heardOn: project.clip(onTrack)!).isEmpty)
        #expect(!answer { project.removeEffects(shared) })
        // The clip with nothing of its own left no longer shares a Thick.
        #expect(project.sharedEffects(of: [withOwn, onTrack]).isEmpty)
    }

    @Test func aTracksEffectIsSwitchedOffAndOnAndPutBackForAllOfThem() throws {
        var project = song()
        let upper = record(2, in: &project)
        let lower = record(2, in: &project, track: 1)
        let one = try #require(answer { project.addTrackEffect(project.tracks[0].id, kind: .thick) })
        let two = try #require(answer { project.addTrackEffect(project.tracks[1].id, kind: .thick) })
        func shared() throws -> SharedEffect {
            try #require(project.sharedEffects(of: [upper, lower]).first)
        }

        #expect(answer { project.setEffects(try! shared(), isOff: true) })
        #expect(project.clip(upper)?.effectChanges == [ClipEffectChange(effectID: one, isOff: true)])
        #expect(project.clip(lower)?.effectChanges == [ClipEffectChange(effectID: two, isOff: true)])
        let off = try shared()
        #expect(off.isOff)
        #expect(answer { project.setEffects(try! shared(), isOff: false) })
        let on = try shared()
        #expect(!on.isOff && !on.isChanged)

        project.setEffects(try shared(), levelDb: -2)
        let turned = try shared()
        #expect(turned.isChanged)
        #expect(answer { project.resetEffects(try! shared()) })
        #expect(project.clip(upper)?.effectChanges.isEmpty == true)
        #expect(project.clip(lower)?.effectChanges.isEmpty == true)
        #expect(!answer { project.resetEffects(try! shared()) })
    }
}
