import Foundation
import Testing
@testable import LockstepCore

/// What the Voice tests share: two Voices, and made voices that can be told from their recording sample for
/// sample.
enum VoiceFixture {
    static let darker = TrackVoice(name: "Darker", knobs: VoiceKnobs(depth: 6, pitch: -1))
    static let deeper = TrackVoice(name: "Deeper", knobs: VoiceKnobs(depth: 10, pitch: -2))

    /// A stand-in for a made voice: the recording with every sample multiplied. At -1 it is as loud as the
    /// recording and peaks where it does, so whatever is made from it is what is made from the recording with
    /// the sign turned, sample for sample.
    static func voice(of sound: [Float], times factor: Float = -1) -> [Float] {
        sound.map { $0 * factor }
    }

    static func turned(_ samples: [Float]) -> [Float] {
        samples.map { -$0 }
    }
}

/// The stand-in: a made voice is read in place of the recording wherever a clip's samples are read, on the
/// track that has the Voice and nowhere else.
///
/// The song, the recording and the made-up sound are those of `ClipExporterTests`.
@Suite("A track's Voice stands in for the recording")
struct VoiceStandInTests {
    typealias Dry = ClipExporterTests
    typealias Fix = VoiceFixture

    /// One recording, a clip of it on a track with the Voice "Darker", and a made voice that stands in.
    struct Scene {
        var recording = Dry.recording()
        var project: Project
        var clip: Clip
        var voiceID = UUID()
        var sounds: [UUID: [Float]]
        var voices = TrackVoices.none

        var track: Track { project.tracks[0] }

        init(_ samples: Range<Int> = 1_000..<41_000, change: (inout Clip) -> Void = { _ in }) {
            var clip = Dry.clip(recording, samples)
            change(&clip)
            self.clip = clip
            project = Dry.project(recording, [clip])
            project.tracks[0].voice = Fix.darker
            let sound = Dry.voice(96_000)
            sounds = [recording.id: sound, voiceID: Fix.voice(of: sound)]
            voices.set(heard: voiceID, before: nil, forRecording: recording.id, onTrack: project.tracks[0].id)
        }

        /// The same project with the Voice taken off its track.
        var withoutVoice: Project {
            var plain = project
            plain.tracks[0].voice = nil
            return plain
        }
    }

    // MARK: The plan

    @Test("A clip on a track with a Voice plays the voice's id at the recording's offsets, lengths and fades")
    func thePlanNamesTheVoice() throws {
        var scene = Scene()
        scene.project.tracks[0].clips[0].segments.append(
            Segment(recordingID: scene.recording.id, inSample: 50_000, outSample: 70_000, gainDb: -2)
        )
        let own = scene.project.clipPlaybackPlan(from: 20_000, to: 75_000, voices: .none)
        let voiced = scene.project.clipPlaybackPlan(from: 20_000, to: 75_000, voices: scene.voices)

        #expect(own.count == 2)
        #expect(own.allSatisfy { $0.recordingID == scene.recording.id })
        #expect(voiced.allSatisfy { $0.recordingID == scene.voiceID })
        // Everything but the id is the recording's.
        #expect(voiced.map { piece -> ClipPiece in
            var named = piece
            named.recordingID = scene.recording.id
            return named
        } == own)
    }

    @Test("Without voices, with a Voice that is off and with one in the middle, the plan is the recording's")
    func thePlanWithoutAVoice() {
        var scene = Scene()
        let own = scene.withoutVoice.clipPlaybackPlan(from: 0, voices: .none)
        #expect(scene.project.clipPlaybackPlan(from: 0, voices: .none) == own)
        #expect(scene.project.clipPlaybackPlan(from: 0, voices: .none) == own)
        #expect(scene.withoutVoice.clipPlaybackPlan(from: 0, voices: scene.voices) == own)

        scene.project.tracks[0].voice?.isOn = false
        #expect(scene.project.clipPlaybackPlan(from: 0, voices: scene.voices) == own)

        scene.project.tracks[0].voice = TrackVoice(knobs: .neutral)
        #expect(scene.project.clipPlaybackPlan(from: 0, voices: scene.voices) == own)
    }

    @Test("A segment with a tightened sound plays the tightened sound, voice or not")
    func theTightenedSoundComesFirst() {
        var scene = Scene { $0.tighten = .lines }
        let tightenedID = UUID()
        var tightened = TightenedSounds()
        tightened.set(tightenedID, for: scene.clip.segments[0], at: 0, of: scene.clip.id, lead: 240, madeFrom: .recordings)
        let plan = scene.project.clipPlaybackPlan(from: 0, tightened: tightened, voices: scene.voices)
        #expect(plan.map(\.recordingID) == [tightenedID])
        #expect(plan == scene.project.clipPlaybackPlan(from: 0, tightened: tightened, voices: .none).map { $0 })

        // Switched off, the clip no longer asks for its tightened sound, and the voice is next in line.
        scene.project.tracks[0].clips[0].tighten = .off
        #expect(scene.project.clipPlaybackPlan(from: 0, tightened: tightened, voices: scene.voices)
            .map(\.recordingID) == [scene.voiceID])
    }

    @Test("One recording on three tracks, one without a Voice and two with different ones, plays each its own")
    func oneRecordingOnThreeTracks() {
        let recording = Dry.recording()
        var project = Dry.project(recording, [Dry.clip(recording, 1_000..<41_000)])
        project.tracks.append(Track(name: "Ad-libs", voice: Fix.darker, clips: [Dry.clip(recording, 1_000..<41_000)]))
        project.tracks.append(Track(name: "Hook", voice: Fix.deeper, clips: [Dry.clip(recording, 20_000..<60_000)]))
        let (darker, deeper) = (UUID(), UUID())
        var voices = TrackVoices.none
        voices.set(heard: darker, before: nil, forRecording: recording.id, onTrack: project.tracks[1].id)
        voices.set(heard: deeper, before: nil, forRecording: recording.id, onTrack: project.tracks[2].id)

        #expect(project.clipPlaybackPlan(from: 0, voices: voices).map(\.recordingID) == [recording.id, darker, deeper])
        #expect(voices.soundID(forRecording: recording.id, on: project.tracks[0]) == nil)
        #expect(voices.standIns(for: project.tracks[2].clips[0], on: project.tracks[2]) == [recording.id: deeper])

        // A voice made for one track is not heard on a track that has a Voice of its own and no voice yet.
        var onlyDarker = TrackVoices.none
        onlyDarker.set(heard: darker, before: nil, forRecording: recording.id, onTrack: project.tracks[1].id)
        #expect(project.clipPlaybackPlan(from: 0, voices: onlyDarker).map(\.recordingID)
            == [recording.id, darker, recording.id])
    }

    @Test("A voice whose samples are not at hand is not played: the recording is")
    func aVoiceWithoutSamples() throws {
        let scene = Scene()
        let missing = [scene.recording.id: try #require(scene.sounds[scene.recording.id])]
        #expect(scene.voices.having(missing).isEmpty)
        #expect(scene.voices.having(scene.sounds) == scene.voices)
        let peaks = Dry.peaks(of: scene.sounds)
        let own = ClipDry.render(scene.clip, in: scene.project, recordings: missing, peaks: peaks, edgeFadeMs: 5, voices: .none)
        #expect(ClipDry.render(
            scene.clip, in: scene.project, recordings: missing, peaks: peaks, edgeFadeMs: 5, voices: scene.voices
        ) == own)
        #expect(OfflineMix.render(
            scene.project, recordings: missing, peaks: peaks, edgeFadeMs: 5, voices: scene.voices
        ) == OfflineMix.render(scene.project, recordings: missing, peaks: peaks, edgeFadeMs: 5, voices: .none))
    }

    // MARK: The dry sound and the exporter

    @Test("With voices the dry sound is the voice's samples, on the same first sample and as long")
    func theDrySoundIsTheVoices() throws {
        let scene = Scene { $0.normalizeGainDb = 1.5 }
        let peaks = Dry.peaks(of: scene.sounds)
        let own = try #require(ClipDry.render(
            scene.clip, in: scene.project, recordings: scene.sounds, peaks: peaks, edgeFadeMs: 5, voices: .none
        ))
        let voiced = try #require(ClipDry.render(
            scene.clip, in: scene.project, recordings: scene.sounds, peaks: peaks, edgeFadeMs: 5, voices: scene.voices
        ))
        #expect(voiced.firstSample == own.firstSample)
        #expect(voiced.samples.count == own.samples.count)
        #expect(voiced.samples == Fix.turned(own.samples))
        #expect(voiced.samples != own.samples)
        // With `.none` it is the dry sound of the same project without the Voice.
        #expect(own == ClipDry.render(
            scene.clip, in: scene.withoutVoice, recordings: scene.sounds, peaks: peaks, edgeFadeMs: 5, voices: .none
        ))
        #expect(own == ClipDry.render(
            scene.clip, in: scene.project, recordings: scene.sounds, peaks: peaks, edgeFadeMs: 5, voices: .none
        ))
    }

    @Test("A clip is sent in its track's voice with voices, on the same frame and as long, and dry without")
    func theExportIsTheVoices() throws {
        let scene = Scene()
        let peaks = Dry.peaks(of: scene.sounds)
        let own = try #require(ClipExporter.export(
            scene.clip.id, in: scene.withoutVoice, recordings: scene.sounds, peaks: peaks, edgeFadeMs: 5, voices: .none
        ))
        let dry = try #require(ClipExporter.export(
            scene.clip.id, in: scene.project, recordings: scene.sounds, peaks: peaks, edgeFadeMs: 5, voices: .none
        ))
        let voiced = try #require(ClipExporter.export(
            scene.clip.id, in: scene.project, recordings: scene.sounds, peaks: peaks, edgeFadeMs: 5,
            voices: scene.voices
        ))
        // Without voices: the very export of the project with the Voice taken off.
        #expect(dry == own)
        #expect(voiced.startFrame == own.startFrame)
        #expect(voiced.timecode == own.timecode)
        #expect(voiced.paddingSamples == own.paddingSamples)
        #expect(voiced.clipSamples == own.clipSamples)
        #expect(voiced.fileName == own.fileName)
        #expect(voiced.channels == 1)
        #expect(voiced.samples == Fix.turned(own.samples))
        #expect(voiced.samples != own.samples)
    }

    @Test("A waiting take is made from its track's voice too, though the plan has no piece for it")
    func aTakeThatWaits() throws {
        var scene = Scene()
        var waiting = Dry.clip(scene.recording, 1_000..<41_000)
        waiting.line = scene.clip.line
        waiting.isActiveTake = false
        scene.project.tracks[0].clips.append(waiting)
        let peaks = Dry.peaks(of: scene.sounds)

        #expect(scene.project.clipPlaybackPlan(from: 0, voices: scene.voices).count == 1)
        let own = try #require(ClipDry.render(
            waiting, in: scene.project, recordings: scene.sounds, peaks: peaks, edgeFadeMs: 5, voices: .none
        ))
        let voiced = try #require(ClipDry.render(
            waiting, in: scene.project, recordings: scene.sounds, peaks: peaks, edgeFadeMs: 5, voices: scene.voices
        ))
        #expect(voiced.samples == Fix.turned(own.samples))
        #expect(voiced.firstSample == own.firstSample)
    }

    @Test("A take recorded slower is read from its voice at the places of its sped-up sound")
    func aTakeRecordedSlower() {
        var scene = Scene()
        // Everything about such a recording counts in the sped-up sound, and so does its voice.
        scene.project.recordings[0].recordedSpeed = 0.85
        let own = scene.project.clipPlaybackPlan(from: 0, voices: .none)
        let voiced = scene.project.clipPlaybackPlan(from: 0, voices: scene.voices)
        #expect(voiced.map(\.recordingID) == [scene.voiceID])
        #expect(voiced.map(\.offset) == own.map(\.offset))
        #expect(voiced.map(\.startDelay) == own.map(\.startDelay))
        #expect(voiced.map(\.length) == own.map(\.length))
    }

    @Test("A clip of two joined recordings plays each recording's own voice, and a recording without one itself")
    func aClipOfTwoRecordings() throws {
        var scene = Scene()
        let second = Recording(lengthSamples: 48_000, rawStart: 2)
        scene.project.recordings.append(second)
        scene.project.tracks[0].clips[0].segments.append(
            Segment(recordingID: second.id, inSample: 0, outSample: 24_000)
        )
        let clip = scene.project.tracks[0].clips[0]
        let secondSound = Array(Dry.voice(96_000).reversed().prefix(48_000))
        scene.sounds[second.id] = secondSound

        // Only the first recording has its voice yet.
        var plan = scene.project.clipPlaybackPlan(from: 0, voices: scene.voices)
        #expect(plan.map(\.recordingID) == [scene.voiceID, second.id])
        #expect(scene.voices.standIns(for: clip, on: scene.track) == [scene.recording.id: scene.voiceID])

        let secondVoice = UUID()
        scene.sounds[secondVoice] = Fix.voice(of: secondSound)
        scene.voices.set(heard: secondVoice, before: nil, forRecording: second.id, onTrack: scene.track.id)
        plan = scene.project.clipPlaybackPlan(from: 0, voices: scene.voices)
        #expect(plan.map(\.recordingID) == [scene.voiceID, secondVoice])

        let peaks = Dry.peaks(of: scene.sounds)
        let own = try #require(ClipDry.render(clip, in: scene.project, recordings: scene.sounds, peaks: peaks, edgeFadeMs: 5, voices: .none))
        let voiced = try #require(ClipDry.render(
            clip, in: scene.project, recordings: scene.sounds, peaks: peaks, edgeFadeMs: 5, voices: scene.voices
        ))
        #expect(voiced.samples == Fix.turned(own.samples))
    }

    // MARK: The recipe of a finished sound

    @Test("The recipe of a finished sound names the voices, and differs when one arrives or changes")
    func theRecipeNamesTheVoices() throws {
        var scene = Scene()
        scene.project.tracks[0].sound = SoundPreset.builtIn[0].sound
        let peaks = Dry.peaks(of: scene.sounds)
        func recipe(_ voices: TrackVoices) throws -> ClipSoundRecipe {
            try #require(ClipSoundRecipe(of: scene.clip, in: scene.project, edgeFadeMs: 5, peaks: peaks, voices: voices))
        }
        let own = try recipe(.none)
        let voiced = try recipe(scene.voices)
        #expect(own.dry.sources.isEmpty)
        #expect(voiced.dry.sources == [scene.recording.id: scene.voiceID])
        #expect(voiced != own)
        #expect(try recipe(scene.voices) == voiced)
        // Without the sources the two are the same recipe: only where the samples come from differs.
        var named = voiced
        named.dry.sources = [:]
        named.dry.sourcesTrackID = nil
        #expect(named == own)
        // With `.none` it is the recipe of the same project with the Voice taken off: what a dry send makes.
        #expect(own == ClipSoundRecipe(of: scene.clip, in: scene.withoutVoice, edgeFadeMs: 5, peaks: peaks, voices: .none))

        var changed = scene.voices
        changed.set(heard: UUID(), before: scene.voiceID, forRecording: scene.recording.id, onTrack: scene.track.id)
        #expect(try recipe(changed) != voiced)

        // The recipe of the same project with the Voice off, or taken off, is the one made from the recordings.
        var off = scene.project
        off.tracks[0].voice?.isOn = false
        let offRecipe = try #require(ClipSoundRecipe(
            of: scene.clip, in: off, edgeFadeMs: 5, peaks: peaks, voices: scene.voices
        ))
        #expect(offRecipe == own)
    }

    @Test("An effect on a stretch stays on the same samples of the dry sound when a voice stands in")
    func anEffectOnAStretch() throws {
        var scene = Scene { clip in
            clip.effects = [ClipEffect(
                kind: .phone,
                span: ClipSpan(recordingID: clip.segments[0].recordingID, inSample: 9_000, outSample: 15_000)
            )]
        }
        scene.project.tracks[0].clips[0] = scene.clip
        let own = try #require(ClipSoundRecipe(of: scene.clip, in: scene.project, edgeFadeMs: 5, voices: .none))
        let voiced = try #require(ClipSoundRecipe(of: scene.clip, in: scene.project, edgeFadeMs: 5, voices: scene.voices))
        // The stretch is named in samples of the recording, and the voice has every sample where the
        // recording has it.
        #expect(voiced.effects == own.effects)
        #expect(voiced.effects.first?.span == 8_000..<14_000)
        #expect(voiced.dry.sources == [scene.recording.id: scene.voiceID])
    }
}

/// The correction on a track with a Voice: the tightened sound is made from the voice, with the lines and the
/// syllables of the recording. The song, the recording and its lines are those of `ClipTighteningTests`.
@Suite("The correction of a clip on a track with a Voice")
struct VoiceTighteningTests {
    typealias Tight = ClipTighteningTests
    typealias Fix = VoiceFixture

    /// A project with one clip on a track with the Voice "Darker", corrected as the clip says.
    static func project(_ change: (inout Clip) -> Void) -> Project {
        var clip = Tight.clip()
        change(&clip)
        return Project(
            songLengthSamples: Tight.songSamples,
            grid: Tight.grid,
            tracks: [Track(name: "Track 1", voice: Fix.darker, clips: [clip])],
            recordings: [Tight.recording]
        )
    }

    static func voices(_ id: UUID, before: UUID? = nil, in project: Project) -> TrackVoices {
        var voices = TrackVoices.none
        voices.set(heard: id, before: before, forRecording: Tight.recording.id, onTrack: project.tracks[0].id)
        return voices
    }

    @Test("The inputs differ when a voice arrives and when it changes, and are equal when nothing did")
    func theInputsNameTheVoice() throws {
        let project = Self.project { $0.tighten = .lines }
        let clip = project.tracks[0].clips[0]
        func inputs(_ voices: TrackVoices, in project: Project = project) throws -> ClipTightening.Inputs {
            try #require(ClipTightening.Inputs(correcting: clip, in: project, markers: Tight.markers, voices: voices))
        }
        let own = try inputs(.none)
        let first = UUID()
        let voiced = try inputs(Self.voices(first, in: project))
        #expect(own.voices.isEmpty)
        #expect(voiced.voices == [Tight.recording.id: first])
        #expect(voiced != own)
        #expect(try inputs(Self.voices(first, in: project)) == voiced)
        #expect(try inputs(Self.voices(UUID(), before: first, in: project)) != voiced)

        // With `.none` on a track with a Voice, the inputs are those of the project without the Voice.
        var plain = project
        plain.tracks[0].voice = nil
        #expect(try inputs(.none, in: plain) == own)
        #expect(try inputs(Self.voices(first, in: plain), in: plain) == own)
        // A Voice that is off, and a voice of another track, name nothing.
        var off = project
        off.tracks[0].voice?.isOn = false
        #expect(try inputs(Self.voices(first, in: off), in: off) == own)
        var elsewhere = TrackVoices.none
        elsewhere.set(heard: first, before: nil, forRecording: Tight.recording.id, onTrack: UUID())
        #expect(try inputs(elsewhere) == own)
    }

    @Test("A tightened sound made with a voice holds the voice's samples moved as the recording's would be")
    func theTightenedSoundIsTheVoiceMoved() throws {
        let stretcher = LinearStretcher()
        for change: (inout Clip) -> Void in [
            { $0.tighten = .lines },
            { $0.tighten = .all; $0.strength = 0.8 },
            { $0.tighten = .all; $0.strength = 0.8; $0.stretch = true },
        ] {
            let project = Self.project(change)
            let clip = project.tracks[0].clips[0]
            let voiceID = UUID()
            let sounds = [Tight.recording.id: Tight.sound, voiceID: Fix.voice(of: Tight.sound)]
            let own = ClipTightening.render(
                try #require(ClipTightening.Inputs(correcting: clip, in: project, markers: Tight.markers, voices: .none)),
                levels: Tight.levels, recordings: sounds, stretcher: stretcher
            )
            let voiced = ClipTightening.render(
                try #require(ClipTightening.Inputs(
                    correcting: clip, in: project, markers: Tight.markers, voices: Self.voices(voiceID, in: project)
                )),
                levels: Tight.levels, recordings: sounds, stretcher: stretcher
            )
            // The same lines, slid as far, and the same edges: only the samples are the voice's.
            #expect(voiced.map(\.lines) == own.map(\.lines))
            #expect(voiced.map(\.leadSamples) == own.map(\.leadSamples))
            #expect(voiced.map(\.tailSamples) == own.map(\.tailSamples))
            let ownSamples = try #require(own.first?.samples)
            #expect(voiced.first?.samples == Fix.turned(ownSamples))
            #expect(voiced.first?.samples != ownSamples)
        }
    }

    @Test("A voice whose samples are missing gives no tightened sound, never one made from the recording")
    func noSoundFromAnotherSource() throws {
        let project = Self.project { $0.tighten = .lines }
        let inputs = try #require(ClipTightening.Inputs(
            correcting: project.tracks[0].clips[0], in: project, markers: Tight.markers,
            voices: Self.voices(UUID(), in: project)
        ))
        let made = ClipTightening.render(inputs, levels: Tight.levels, recordings: [Tight.recording.id: Tight.sound])
        #expect(made.allSatisfy { $0.samples == nil })
        #expect(made.contains { !$0.lines.isEmpty })
    }

    @Test("A dry send of a corrected clip on a track with a Voice is the bytes of the project without the Voice")
    func aDrySendIsMaxsOwnVoice() throws {
        let stretcher = LinearStretcher()
        for change: (inout Clip) -> Void in [
            { $0.tighten = .lines },
            { $0.tighten = .all; $0.strength = 0.8 },
            { $0.tighten = .all; $0.strength = 0.8; $0.stretch = true },
        ] {
            let project = Self.project { clip in
                change(&clip)
                clip.normalizeGainDb = 3
            }
            var plain = project
            plain.tracks[0].voice = nil
            let clip = project.tracks[0].clips[0]
            let voiceID = UUID()
            // A voice that peaks higher than the recording, so the safe limit would also tell them apart.
            let recordings = [Tight.recording.id: Tight.sound, voiceID: Fix.voice(of: Tight.sound, times: -1.9)]
            let voices = Self.voices(voiceID, in: project)

            /// What a send does, with the source chosen once and handed to every step.
            func send(_ voices: TrackVoices, in project: Project) throws -> ClipExport {
                var sounds = recordings
                let inputs = try #require(ClipTightening.Inputs(
                    correcting: clip, in: project, markers: Tight.markers, voices: voices
                ))
                var tightened = TightenedSounds()
                let made = ClipTightening.render(inputs, levels: Tight.levels, recordings: sounds, stretcher: stretcher)
                for (index, segment) in made.enumerated() {
                    guard let samples = segment.samples else { continue }
                    let id = UUID()
                    sounds[id] = samples
                    tightened.set(
                        id, for: clip.segments[index], at: index, of: clip.id,
                        lead: segment.leadSamples, tail: segment.tailSamples,
                        madeFrom: VoiceSources(inputs.voices, onTrack: project.tracks[0].id)
                    )
                }
                #expect(!tightened.isEmpty)
                return try #require(ClipExporter.export(
                    clip.id, in: project, recordings: sounds, peaks: ClipExporterTests.peaks(of: sounds),
                    edgeFadeMs: 5, tightened: tightened, voices: voices
                ))
            }
            let own = try send(.none, in: plain)
            let dry = try send(.none, in: project)
            let voiced = try send(voices, in: project)
            #expect(dry == own)
            #expect(voiced.samples != own.samples)
            #expect(voiced.timecode == own.timecode)
            #expect(voiced.samples.count == own.samples.count)
        }
    }

    @Test("The memory of the inputs works a track out again when a voice arrives, and only that track")
    func theMemoryKnowsOfVoices() throws {
        var project = Self.project { $0.tighten = .lines }
        var other = Tight.clip()
        other.tighten = .lines
        project.tracks.append(Track(name: "Track 2", clips: [other]))
        var memory = TighteningInputsMemory()
        func entries(_ voices: TrackVoices) -> [TighteningInputsMemory.Entry] {
            memory.inputs(
                in: ProjectLookup(project), markers: Tight.markers, settings: TightenSettings(),
                perBeat: { _ in 4 }, voices: voices
            )
        }
        let first = entries(.none)
        #expect(memory.builds == 2)
        #expect(first.allSatisfy { $0.inputs.voices.isEmpty })
        #expect(entries(.none).map(\.stamp) == first.map(\.stamp))
        #expect(memory.builds == 2)

        // A voice arrives on the first track: its clip is worked out again, the other track's is kept.
        let voiceID = UUID()
        let voiced = entries(Self.voices(voiceID, in: project))
        #expect(memory.builds == 3)
        #expect(voiced[0].inputs.voices == [Tight.recording.id: voiceID])
        #expect(voiced[0].stamp != first[0].stamp)
        #expect(voiced[1].stamp == first[1].stamp)
        #expect(voiced[1].inputs.voices.isEmpty)
        // The same voices again: nothing is worked out.
        #expect(entries(Self.voices(voiceID, in: project)).map(\.stamp) == voiced.map(\.stamp))
        #expect(memory.builds == 3)
        // The voice changes, and then the Voice is switched off: each time that track alone.
        _ = entries(Self.voices(UUID(), before: voiceID, in: project))
        #expect(memory.builds == 4)
        project.tracks[0].voice?.isOn = false
        let off = entries(Self.voices(voiceID, in: project))
        #expect(off[0].inputs == first[0].inputs)
        // Each entry holds what `Inputs(correcting:)` gives for its clip.
        #expect(off[0].inputs == ClipTightening.Inputs(
            correcting: project.tracks[0].clips[0], in: project, markers: Tight.markers,
            voices: Self.voices(voiceID, in: project)
        ))
    }
}

/// A double locked to its lead on tracks with a Voice: the double is made from its own track's voice, and is
/// held against the lead's syllables, which are the lead's recording's whatever voice the lead is heard in.
/// The song, the recording and its lines are those of `ClipTighteningTests`; the lead's syllables are those
/// of `LockedDoubleTests`.
@Suite("A locked double on tracks with a Voice")
struct VoiceLockedDoubleTests {
    typealias Tight = ClipTighteningTests
    typealias Fix = VoiceFixture

    /// The lead as the double hears it, 18 ms before the double's first line and 25 ms after its second.
    static let leadSyllables = [1.512, 1.637, 1.762, 1.887, 3.130, 3.255, 3.380, 3.505]
        .map { TimingTargets.Target(time: $0) }

    /// The lead's track first and the double's second, both with a Voice, the double on All aimed at the
    /// lead. Both play the recording of `ClipTighteningTests`.
    static func project() -> Project {
        let leadTrack = Track(name: "Lead", voice: Fix.darker, clips: [Tight.clip()])
        var double = Tight.clip()
        double.tighten = .all
        double.aimTrack = leadTrack.id
        return Project(
            songLengthSamples: Tight.songSamples,
            grid: Tight.grid,
            tracks: [leadTrack, Track(name: "Double", voice: Fix.deeper, clips: [double])],
            recordings: [Tight.recording]
        )
    }

    static func inputs(_ project: Project, _ voices: TrackVoices) throws -> ClipTightening.Inputs {
        try #require(ClipTightening.Inputs(
            correcting: project.tracks[1].clips[0], in: project, markers: Tight.markers,
            aimedAt: leadSyllables, voices: voices
        ))
    }

    @Test("A double on a track with a Voice is corrected from that track's voice, held against the same lead")
    func theDoubleReadsItsOwnVoice() throws {
        let project = Self.project()
        let voiceID = UUID()
        var voices = TrackVoices.none
        voices.set(heard: voiceID, before: nil, forRecording: Tight.recording.id, onTrack: project.tracks[1].id)
        let own = try Self.inputs(project, .none)
        let voiced = try Self.inputs(project, voices)
        #expect(voiced.voices == [Tight.recording.id: voiceID])
        #expect(voiced.sources == VoiceSources([Tight.recording.id: voiceID], onTrack: project.tracks[1].id))
        #expect(voiced.targets == own.targets)
        #expect(voiced.targets == .times(Self.leadSyllables))

        let sounds = [Tight.recording.id: Tight.sound, voiceID: Fix.voice(of: Tight.sound)]
        let stretcher = LinearStretcher()
        let ownSound = ClipTightening.render(own, levels: Tight.levels, recordings: sounds, stretcher: stretcher)
        let voicedSound = ClipTightening.render(voiced, levels: Tight.levels, recordings: sounds, stretcher: stretcher)
        // The same lines and moves, held against the same lead: only the samples are the voice's.
        #expect(voicedSound.map(\.lines) == ownSound.map(\.lines))
        let ownSamples = try #require(ownSound.first?.samples)
        #expect(voicedSound.first?.samples == Fix.turned(ownSamples))
    }

    @Test("A voice arriving on the lead's track changes neither the lead's syllables nor the double's inputs")
    func theLeadsVoiceLeavesTheDoubleAlone() throws {
        let project = Self.project()
        var voices = TrackVoices.none
        voices.set(heard: UUID(), before: nil, forRecording: Tight.recording.id, onTrack: project.tracks[0].id)
        // The double's inputs are what they were: nothing on its own track changed, and the lead's syllables
        // it is handed are the lead's recording's.
        #expect(try Self.inputs(project, voices) == (try Self.inputs(project, .none)))

        // The lead corrected in its voice slides its lines as far as in Max's own, so where its syllables are
        // heard, which is what the double is held against, does not move when its voice arrives.
        var lead = project
        lead.tracks[0].clips[0].tighten = .lines
        let leadClip = lead.tracks[0].clips[0]
        let ownLead = try #require(ClipTightening.Inputs(
            correcting: leadClip, in: lead, markers: Tight.markers, voices: .none
        ))
        let voicedLead = try #require(ClipTightening.Inputs(
            correcting: leadClip, in: lead, markers: Tight.markers, voices: voices
        ))
        #expect(voicedLead != ownLead)
        #expect(ClipTightening.lines(of: voicedLead, levels: Tight.levels)
            == ClipTightening.lines(of: ownLead, levels: Tight.levels))
    }
}
