import Foundation
import Testing
@testable import LockstepCore

/// A tightened or finished sound made from a voice is heard only while that voice, or the one just before it on
/// the same track, stands in. After the Voice is switched off, taken off, undone or the clip is moved to
/// another track, the clip is heard from what stands in now, never in the old voice.
///
/// The scene is the one of `VoiceStandInTests`: one recording, a clip of it on a track with the Voice
/// "Darker", and a made voice that stands in.
@Suite("An older result is never heard in a voice that no longer stands in")
struct VoiceOlderResultsTests {
    typealias Dry = ClipExporterTests
    typealias Scene = VoiceStandInTests.Scene
    typealias Fix = VoiceFixture

    /// The scene with Lines on, a tightened sound of its segment made from its voice on its track, and the
    /// samples of that sound among the scene's sounds.
    struct Corrected {
        var scene: Scene
        var tightenedID = UUID()
        var tightened = TightenedSounds()

        init(madeFrom sources: ((Scene) -> VoiceSources)? = nil) {
            scene = Scene { $0.tighten = .lines }
            let sources = sources?(scene)
                ?? VoiceSources([scene.recording.id: scene.voiceID], onTrack: scene.track.id)
            tightened.set(
                tightenedID, for: scene.clip.segments[0], at: 0, of: scene.clip.id, madeFrom: sources
            )
            // Half as loud as the voice, so a file that held it would be told from every other one.
            let voice = scene.sounds[scene.voiceID] ?? []
            scene.sounds[tightenedID] = Fix.voice(of: Array(voice[1_000..<41_000]), times: 0.5)
        }
    }

    /// The scene with a Sound on its track and a finished sound of its clip made from its voice.
    struct Finished {
        var scene: Scene
        var soundID = UUID()
        var finished = FinishedSounds()
        var samples: [UUID: StereoSound] = [:]

        init(madeFrom sources: ((Scene) -> VoiceSources)? = nil) {
            scene = Scene()
            scene.project.tracks[0].sound = SoundPreset.builtIn[0].sound
            let sources = sources?(scene)
                ?? VoiceSources([scene.recording.id: scene.voiceID], onTrack: scene.track.id)
            finished.set(
                FinishedSounds.Sound(
                    id: soundID, drySamples: 40_000, tailSamples: 0, pieces: scene.clip.segments, madeFrom: sources
                ),
                for: scene.clip.id
            )
            samples[soundID] = StereoSound(
                left: [Float](repeating: 0.25, count: 40_000), right: [Float](repeating: 0.25, count: 40_000)
            )
        }
    }

    // MARK: Off, Undo, taken off

    @Test("With the Voice off, taken off or undone, the plan plays the recording, not the voiced tightened sound")
    func aTightenedSoundOfAVoiceThatIsOff() {
        var made = Corrected()
        let voices = made.scene.voices
        #expect(made.scene.project.clipPlaybackPlan(from: 0, tightened: made.tightened, voices: voices)
            .map(\.recordingID) == [made.tightenedID])

        // Switched off, or an Undo back to off: Max's own recording at once, not the corrected voice.
        made.scene.project.tracks[0].voice?.isOn = false
        #expect(made.scene.project.clipPlaybackPlan(from: 0, tightened: made.tightened, voices: voices)
            .map(\.recordingID) == [made.scene.recording.id])
        // Taken off, or an Undo back to before it was chosen.
        made.scene.project.tracks[0].voice = nil
        #expect(made.scene.project.clipPlaybackPlan(from: 0, tightened: made.tightened, voices: voices)
            .map(\.recordingID) == [made.scene.recording.id])
        // Both knobs in the middle: nothing is heard in their place.
        made.scene.project.tracks[0].voice = TrackVoice(knobs: .neutral)
        #expect(made.scene.project.clipPlaybackPlan(from: 0, tightened: made.tightened, voices: voices)
            .map(\.recordingID) == [made.scene.recording.id])
        // The same with `.none`: a dry plan never plays a sound made from a voice.
        made.scene.project.tracks[0].voice = Fix.darker
        #expect(made.scene.project.clipPlaybackPlan(from: 0, tightened: made.tightened, voices: .none)
            .map(\.recordingID) == [made.scene.recording.id])
    }

    @Test("A knob turned once keeps the voiced tightened sound until the new one is made; turned again it does not")
    func aKnobTurnedWhileTheSoundIsMade() {
        let made = Corrected()
        let scene = made.scene
        let next = UUID()
        var turned = TrackVoices.none
        turned.set(heard: next, before: scene.voiceID, forRecording: scene.recording.id, onTrack: scene.track.id)
        #expect(scene.project.clipPlaybackPlan(from: 0, tightened: made.tightened, voices: turned)
            .map(\.recordingID) == [made.tightenedID])

        // Turned again before the sound was made again: the setting before is no longer the one it was made
        // from, and the clip is heard from the voice that stands in now, uncorrected until its sound is made.
        let third = UUID()
        var again = TrackVoices.none
        again.set(heard: third, before: next, forRecording: scene.recording.id, onTrack: scene.track.id)
        #expect(scene.project.clipPlaybackPlan(from: 0, tightened: made.tightened, voices: again)
            .map(\.recordingID) == [third])
    }

    @Test("A tightened sound made from Max's own recording may be heard on, also once a voice has arrived")
    func aTightenedSoundOfTheRecording() {
        let made = Corrected { _ in .recordings }
        #expect(made.scene.project.clipPlaybackPlan(from: 0, tightened: made.tightened, voices: made.scene.voices)
            .map(\.recordingID) == [made.tightenedID])
    }

    @Test("With the Voice off or taken off, the plan plays the clip's segments, not the voiced finished sound")
    func aFinishedSoundOfAVoiceThatIsOff() {
        var made = Finished()
        let voices = made.scene.voices
        let heard = made.scene.project.clipPlaybackPlan(from: 0, finished: made.finished, voices: voices)
        #expect(heard.map(\.recordingID) == [made.soundID])
        #expect(heard.allSatisfy { $0.isFinished })

        made.scene.project.tracks[0].voice?.isOn = false
        let off = made.scene.project.clipPlaybackPlan(from: 0, finished: made.finished, voices: voices)
        #expect(off.map(\.recordingID) == [made.scene.recording.id])
        #expect(!off.contains { $0.isFinished })

        made.scene.project.tracks[0].voice = nil
        #expect(made.scene.project.clipPlaybackPlan(from: 0, finished: made.finished, voices: voices)
            .map(\.recordingID) == [made.scene.recording.id])

        // A finished sound made from the recording is heard on when a voice arrives.
        let own = Finished { _ in .recordings }
        #expect(own.scene.project.clipPlaybackPlan(from: 0, finished: own.finished, voices: own.scene.voices)
            .map(\.recordingID) == [own.soundID])
    }

    // MARK: A move to another track

    /// The scene with a second track with the same Voice, on which another voice stands in for the recording
    /// (`other`), and the scene's clip moved there.
    static func moved(_ scene: Scene, other: UUID, before: UUID? = nil) -> (Project, TrackVoices) {
        var project = scene.project
        let clip = project.tracks[0].clips.removeFirst()
        project.tracks.append(Track(name: "Ad-libs", voice: Fix.darker, clips: [clip]))
        var voices = scene.voices
        voices.set(heard: other, before: before, forRecording: scene.recording.id, onTrack: project.tracks[1].id)
        return (project, voices)
    }

    @Test("A clip moved to another track is heard from that track's voice, not its tightened or finished sound")
    func aClipMovedToAnotherTrack() {
        let corrected = Corrected()
        let other = UUID()
        let (project, voices) = Self.moved(corrected.scene, other: other)
        #expect(project.clipPlaybackPlan(from: 0, tightened: corrected.tightened, voices: voices)
            .map(\.recordingID) == [other])
        // On a track without a Voice: the recording.
        var plain = project
        plain.tracks[1].voice = nil
        #expect(plain.clipPlaybackPlan(from: 0, tightened: corrected.tightened, voices: voices)
            .map(\.recordingID) == [corrected.scene.recording.id])

        let finished = Finished()
        let (moved, movedVoices) = Self.moved(finished.scene, other: other)
        let plan = moved.clipPlaybackPlan(from: 0, finished: finished.finished, voices: movedVoices)
        #expect(plan.map(\.recordingID) == [other])
        #expect(!plan.contains { $0.isFinished })
    }

    @Test("A clip moved to the track it came from again, where its voice still stands in, has its sound back")
    func aClipMovedBack() {
        let corrected = Corrected()
        let (project, voices) = Self.moved(corrected.scene, other: UUID())
        var back = project
        back.tracks[0].clips = back.tracks[1].clips
        back.tracks[1].clips = []
        #expect(back.clipPlaybackPlan(from: 0, tightened: corrected.tightened, voices: voices)
            .map(\.recordingID) == [corrected.tightenedID])
    }

    // MARK: A dry send

    @Test("A dry export handed a voiced tightened sound is never voiced: it is the clip of Max's own recording")
    func aDryExportRefusesAVoicedTightenedSound() throws {
        let made = Corrected()
        let scene = made.scene
        let peaks = Dry.peaks(of: scene.sounds)
        func export(_ tightened: TightenedSounds, _ voices: TrackVoices, in project: Project) throws -> ClipExport {
            try #require(ClipExporter.export(
                scene.clip.id, in: project, recordings: scene.sounds, peaks: peaks, edgeFadeMs: 5,
                tightened: tightened, voices: voices
            ))
        }
        let own = try export(.none, .none, in: scene.withoutVoice)
        let voiced = try export(made.tightened, scene.voices, in: scene.project)
        #expect(voiced.samples != own.samples)

        #expect(try export(made.tightened, .none, in: scene.project) == own)
        // The Voice switched off, with the voices still handed in: the same.
        var off = scene.project
        off.tracks[0].voice?.isOn = false
        #expect(try export(made.tightened, scene.voices, in: off) == own)
        // The dry sound and the start the window shows agree.
        let dry = ClipDry.render(
            scene.clip, in: scene.project, recordings: scene.sounds, peaks: peaks, edgeFadeMs: 5,
            tightened: made.tightened, voices: .none
        )
        #expect(dry == ClipDry.render(
            scene.clip, in: scene.withoutVoice, recordings: scene.sounds, peaks: peaks, edgeFadeMs: 5, voices: .none
        ))
        #expect(ClipExporter.startSample(of: scene.clip.id, in: scene.project, tightened: made.tightened, voices: .none)
            == ClipExporter.startSample(of: scene.clip.id, in: scene.withoutVoice, voices: .none))
    }

    @Test("A dry export handed a voiced finished sound is the mono file of Max's own recording")
    func aDryExportRefusesAVoicedFinishedSound() throws {
        let made = Finished()
        let scene = made.scene
        let peaks = Dry.peaks(of: scene.sounds)
        let voiced = try #require(ClipExporter.export(
            scene.clip.id, in: scene.project, recordings: scene.sounds, peaks: peaks, edgeFadeMs: 5,
            finished: made.finished, finishedSamples: made.samples, voices: scene.voices
        ))
        #expect(voiced.channels == 2)
        let dry = try #require(ClipExporter.export(
            scene.clip.id, in: scene.project, recordings: scene.sounds, peaks: peaks, edgeFadeMs: 5,
            finished: made.finished, finishedSamples: made.samples, voices: .none
        ))
        let own = try #require(ClipExporter.export(
            scene.clip.id, in: scene.withoutVoice, recordings: scene.sounds, peaks: peaks, edgeFadeMs: 5, voices: .none
        ))
        #expect(dry == own)
        #expect(dry.channels == 1)
    }

    @Test("The recipe of a dry finished sound does not name a voiced tightened sound it would not be made from")
    func theRecipeNamesOnlyWhatIsHeard() throws {
        var made = Corrected()
        made.scene.project.tracks[0].sound = SoundPreset.builtIn[0].sound
        let scene = made.scene
        let clip = scene.project.tracks[0].clips[0]
        let voiced = try #require(ClipSoundRecipe(
            of: clip, in: scene.project, tightened: made.tightened, edgeFadeMs: 5, voices: scene.voices
        ))
        #expect(voiced.dry.tightenedIDs == [made.tightenedID])
        let dry = try #require(ClipSoundRecipe(
            of: clip, in: scene.project, tightened: made.tightened, edgeFadeMs: 5, voices: .none
        ))
        #expect(dry.dry.tightenedIDs == [nil])
        #expect(dry == ClipSoundRecipe(of: clip, in: scene.project, edgeFadeMs: 5, voices: .none))
    }
}

/// Every voice in the `TrackVoices` a rule is handed has its samples with the recordings', so what a sound is
/// named after is what it was made from. Whoever holds the samples filters the lookup once
/// (`TrackVoices.having`) and hands that same lookup to every rule. See finding 4 of the review of the rules.
@Suite("A sound is named after the voice it was made from, also when the voice's samples come later")
struct VoiceSamplesArriveLaterTests {
    typealias Dry = ClipExporterTests
    typealias Tight = ClipTighteningTests
    typealias Scene = VoiceStandInTests.Scene
    typealias Fix = VoiceFixture

    @Test("Before its samples are there the recipe and the dry sound are the recording's; when they arrive both change")
    func theFinishedSoundIsMadeAgain() throws {
        var scene = Scene()
        scene.project.tracks[0].sound = SoundPreset.builtIn[0].sound
        let peaks = Dry.peaks(of: scene.sounds)
        var early = scene.sounds
        early[scene.voiceID] = nil
        func recipe(_ voices: TrackVoices) throws -> ClipSoundRecipe {
            try #require(ClipSoundRecipe(of: scene.clip, in: scene.project, edgeFadeMs: 5, peaks: peaks, voices: voices))
        }
        func dry(_ voices: TrackVoices, _ samples: [UUID: [Float]]) -> ClipDry.Sound? {
            ClipDry.render(scene.clip, in: scene.project, recordings: samples, peaks: peaks, edgeFadeMs: 5, voices: voices)
        }

        // The voice is known to the app, its samples are not in yet: the lookup handed on names nothing.
        let before = scene.voices.having(early)
        #expect(before.isEmpty)
        let made = try recipe(before)
        #expect(made.dry.madeFrom == .recordings)
        #expect(made == (try recipe(.none)))
        #expect(dry(before, early) == dry(.none, scene.sounds))

        // The samples arrive: the recipe differs, so the sound is made again, and from the voice.
        let after = scene.voices.having(scene.sounds)
        #expect(after == scene.voices)
        let remade = try recipe(after)
        #expect(remade != made)
        #expect(remade.dry.madeFrom == VoiceSources([scene.recording.id: scene.voiceID], onTrack: scene.track.id))
        let voiced = try #require(dry(after, scene.sounds))
        let own = try #require(dry(.none, scene.sounds))
        #expect(voiced.samples == Fix.turned(own.samples))
        // The sound made early, from the recording, may be heard until then: one change in the ear.
        #expect(after.mayBeHeardOn(madeFrom: made.dry.madeFrom, for: scene.clip, on: scene.track))
    }

    @Test("Before its samples are there the inputs name no voice; when they arrive they do, and the sound is made")
    func theTightenedSoundIsMadeAgain() throws {
        let project = VoiceTighteningTests.project { $0.tighten = .lines }
        let clip = project.tracks[0].clips[0]
        let voiceID = UUID()
        let voices = VoiceTighteningTests.voices(voiceID, in: project)
        let early = [Tight.recording.id: Tight.sound]
        var late = early
        late[voiceID] = Fix.voice(of: Tight.sound)
        func inputs(_ voices: TrackVoices) throws -> ClipTightening.Inputs {
            try #require(ClipTightening.Inputs(correcting: clip, in: project, markers: Tight.markers, voices: voices))
        }

        let first = try inputs(voices.having(early))
        #expect(first == (try inputs(.none)))
        #expect(first.sources == .recordings)
        // Made from the recording, and it has a sound: the clip is corrected meanwhile, not left uncorrected.
        let made = ClipTightening.render(first, levels: Tight.levels, recordings: early)
        #expect(made.contains { $0.samples != nil })

        let second = try inputs(voices.having(late))
        #expect(second != first)
        #expect(second.sources == VoiceSources([Tight.recording.id: voiceID], onTrack: project.tracks[0].id))
        let remade = ClipTightening.render(second, levels: Tight.levels, recordings: late)
        #expect(remade.first?.samples == made.first?.samples.map(Fix.turned))
    }
}
