import Foundation
import Testing
@testable import LockstepCore

/// The answer of a call that changes what it is called on. Such a call cannot stand inside `#expect` itself.
private func answer<Answer>(_ change: () -> Answer) -> Answer {
    change()
}

/// A twenty-second song with three empty tracks and a beat every half second.
private func song() -> Project {
    var project = Project(
        songLengthSamples: 960_000,
        grid: Grid(beats: (0..<40).map { Beat(number: $0, time: Double($0) * 0.5) })
    )
    project.addTrack()
    project.addTrack()
    return project
}

/// Records a clip the way the app does: a new recording whose clip begins `start` seconds into the song and is
/// one second long. Returns the id of the clip.
@discardableResult
private func record(_ start: Double, in project: inout Project, track: Int = 0) -> UUID {
    let recording = Recording(lengthSamples: 48_000, rawStart: start)
    return project.addRecording(recording, samples: 0..<recording.lengthSamples, asClipOn: project.tracks[track].id, voices: .none)!
}

/// A stretch in the middle of the one recording a clip plays, for an effect on a word.
private func word(of clipID: UUID, in project: Project) -> ClipSpan {
    ClipSpan(recordingID: project.clip(clipID)!.segments[0].recordingID, inSample: 9_600, outSample: 24_000)
}

private typealias Effect = SoundPreset.Effect

/// The effects a clip is heard with on the whole of it, as kinds and levels, sorted so that two lists with
/// the same effects are equal whatever order the track's and the clip's own came in.
private func heardWhole(_ clipID: UUID, in project: Project) -> [Effect] {
    sorted(project.effects(heardOn: project.clip(clipID)!).filter { $0.span == nil }.map(Effect.init))
}

private func sorted(_ effects: [Effect]) -> [Effect] {
    effects.sorted { ($0.kind.rawValue, $0.levelDb) < ($1.kind.rawValue, $1.levelDb) }
}

private let rapLead = SoundPreset.builtIn(named: "Rap lead")!.sound
private let sungLead = SoundPreset.builtIn(named: "Sung lead")!.sound

@MainActor
@Suite("A preset keeps a track's effects")
struct PresetEffectsTests {
    private let knobs = SoundKnobs(squeeze: 0.7, tone: 0.5, warmth: 0.3, space: 0.2)

    @Test func aPresetWithEffectsAndOneWithoutAreKeptWithTheSettingsAndReadAgain() throws {
        let store = try MeasuredDelaysTests.Store()
        let settings = AppSettings(store: store.defaults)
        let sound = TrackSound(name: "Sung lead", character: .sungLead, knobs: knobs)
        let effects = [
            ClipEffect(kind: .thick, levelDb: -4.5),
            ClipEffect(kind: .phone),
            ClipEffect(kind: .echoEighth, levelDb: 90),
        ]
        #expect(settings.saveOwnPreset(named: "Wide", from: sound, effects: effects))
        #expect(settings.saveOwnPreset(named: "Plain", from: sound))

        let again = try store.settingsAfterRestart()[.ownPresets].presets
        #expect(again == [
            SoundPreset(name: "Wide", character: .sungLead, knobs: knobs, effects: [
                Effect(kind: .thick, levelDb: -4.5),
                Effect(kind: .phone, levelDb: 0),
                // A level is held to its range, as on a track.
                Effect(kind: .echoEighth, levelDb: 6),
            ]),
            SoundPreset(name: "Plain", character: .sungLead, knobs: knobs),
        ])
        #expect(again[1].effects.isEmpty)
    }

    @Test func aRowSavedBeforeHasNoEffectsAndAnUnknownKindIsSkippedWithTheOthersKept() throws {
        let stored: [Any] = [
            ["name": "Old", "character": "rapDouble", "squeeze": 0.8, "tone": 0.5, "warmth": 0.25, "space": 0.12],
            [
                "name": "Newer", "character": "rapLead", "squeeze": 0.7, "tone": 0.5, "warmth": 0.3, "space": 0.2,
                "effects": [
                    ["kind": "thick", "levelDb": -6],
                    ["kind": "choir", "levelDb": -3],
                    "not an effect",
                    ["kind": "phone"],
                ] as [Any],
            ],
        ]
        let own = try #require(SoundPresets(stored: stored))
        #expect(own.presets.map(\.name) == ["Old", "Newer"])
        #expect(own.presets[0].effects.isEmpty)
        #expect(own.presets[1].effects == [Effect(kind: .thick, levelDb: -6), Effect(kind: .phone, levelDb: 0)])

        // A preset without effects is kept as a row was before: no `effects` in it.
        let rows = try #require(own.storedForm as? [[String: Any]])
        #expect(rows[0]["effects"] == nil)
        #expect((rows[1]["effects"] as? [[String: Any]])?.count == 2)
    }

    @Test func savingOverAPresetOfTheSameNameReplacesItsEffectsToo() throws {
        let store = try MeasuredDelaysTests.Store()
        let settings = AppSettings(store: store.defaults)
        let sound = TrackSound(name: "Rap lead", character: .rapLead, knobs: knobs)
        settings.saveOwnPreset(named: "Mine", from: sound, effects: [ClipEffect(kind: .thick, levelDb: -9)])
        settings.saveOwnPreset(named: "Other", from: sound)
        #expect(settings.saveOwnPreset(named: "mine", from: sound, effects: [ClipEffect(kind: .big, levelDb: -2)]))
        #expect(settings[.ownPresets].presets.map(\.name) == ["mine", "Other"])
        #expect(settings[.ownPresets].presets[0].effects == [Effect(kind: .big, levelDb: -2)])
        #expect(settings.saveOwnPreset(named: "Mine", from: sound))
        #expect(settings[.ownPresets].presets[0].effects.isEmpty)
    }

    @Test func thePresetsAreWrittenAndReadBackAsTextWithAndWithoutEffects() throws {
        var own = SoundPresets()
        own.add(SoundPreset(name: "One", character: .sungHook, knobs: knobs, effects: [Effect(kind: .high, levelDb: -16)]))
        own.add(SoundPreset(name: "Two", character: .adLib, knobs: knobs))
        let text = try JSONEncoder().encode(own)
        #expect(try JSONDecoder().decode(SoundPresets.self, from: text) == own)
        // Text written before presets had effects is read as presets without.
        let before = Data(#"{"presets":[{"name":"Old","character":"adLib","knobs":{"squeeze":0.5,"tone":0.5,"warmth":0.5,"space":0.5}}]}"#.utf8)
        #expect(try JSONDecoder().decode(SoundPresets.self, from: before).presets[0].effects.isEmpty)
    }

    @Test func aPresetWithEffectsGivesTheTrackItsSoundAndCopiesOfThemInPlaceOfItsOwn() throws {
        var project = song()
        let track = project.tracks[0].id
        let clip = record(2, in: &project)
        let waiting = record(2, in: &project)
        let old = try #require(answer { project.addTrackEffect(track, kind: .lowOctave) })
        project.setClips([clip], trackEffect: old, levelDb: -3)
        #expect(project.clip(waiting)?.effectChanges.isEmpty == false)
        // A change that names an effect of another track is kept for the way back.
        let elsewhere = ClipEffectChange(effectID: UUID(), isOff: true)
        project.tracks[0].clips[0].effectChanges.append(elsewhere)

        let preset = SoundPreset(name: "Wide", character: .sungLead, knobs: knobs, effects: [
            Effect(kind: .thick, levelDb: -4), Effect(kind: .phone, levelDb: 0),
        ])
        #expect(answer { project.setTrack(track, preset: preset) })
        let now = try #require(project.track(track))
        #expect(now.sound == preset.sound)
        #expect(now.effects.map(Effect.init) == preset.effects)
        #expect(now.effects.allSatisfy { $0.span == nil && $0.id != old })
        #expect(Set(now.effects.map(\.id)).count == 2)
        #expect(project.tracks[0].clips[0].effectChanges == [elsewhere])
        #expect(project.clip(waiting)?.effectChanges.isEmpty == true)

        // Chosen again, nothing changes: the effects keep their ids, so the clips' changes still hold.
        let ids = now.effects.map(\.id)
        #expect(!answer { project.setTrack(track, preset: preset) })
        #expect(project.track(track)?.effects.map(\.id) == ids)
        // No such track.
        #expect(!answer { project.setTrack(UUID(), preset: preset) })
    }

    @Test func aPresetWithoutEffectsLeavesTheTracksEffectsAndTheClipsChangesAlone() throws {
        var project = song()
        let track = project.tracks[0].id
        let clip = record(2, in: &project)
        let thick = try #require(answer { project.addTrackEffect(track, kind: .thick) })
        project.setClips([clip], trackEffect: thick, isOff: true)

        #expect(answer { project.setTrack(track, preset: SoundPreset.builtIn[0]) })
        #expect(project.track(track)?.sound == SoundPreset.builtIn[0].sound)
        #expect(project.track(track)?.effects.map(\.id) == [thick])
        #expect(project.clip(clip)?.effectChanges == [ClipEffectChange(effectID: thick, isOff: true)])
        #expect(!answer { project.setTrack(track, preset: SoundPreset.builtIn[0]) })
    }
}

@MainActor
@Suite("Copy Sound and Paste Sound")
struct SoundCopyTests {
    /// A project whose first track has a Sound, a Thick double, an echo and the phone voice, and a clip that
    /// changed all it can for itself: a knob, its own level for the Thick, the echo off, a double of its own
    /// and an effect on a word.
    private struct Tuned {
        var project: Project
        var source: UUID
        var thick: UUID
        var echo: UUID
        var phone: UUID
        /// What Copy Sound takes from `source`.
        var copied: CopiedSound

        init() throws {
            var project = song()
            let track = project.tracks[0].id
            let source = record(2, in: &project)
            project.setTrack(track, sound: rapLead)
            let thick = try #require(answer { project.addTrackEffect(track, kind: .thick) })
            let echo = try #require(answer { project.addTrackEffect(track, kind: .echoQuarter) })
            let phone = try #require(answer { project.addTrackEffect(track, kind: .phone) })
            project.setClips([source], knob: .space, to: 0.6)
            project.setClips([source], trackEffect: thick, levelDb: -3)
            project.setClips([source], trackEffect: echo, isOff: true)
            let low = try #require(answer { project.addEffect(source, kind: .lowOctave) })
            project.setEffect(low, of: source, levelDb: -12)
            let onWord = word(of: source, in: project)
            _ = try #require(answer { project.addEffect(source, kind: .stutter, span: onWord) })
            var knobs = rapLead.knobs
            knobs.space = 0.6
            self.project = project
            self.source = source
            self.thick = thick
            self.echo = echo
            self.phone = phone
            copied = CopiedSound(
                sound: TrackSound(name: "Rap lead", character: .rapLead, knobs: knobs),
                effects: [
                    Effect(kind: .thick, levelDb: -3), Effect(kind: .phone, levelDb: 0),
                    Effect(kind: .lowOctave, levelDb: -12),
                ]
            )
        }
    }

    @Test func aClipsSoundIsItsTracksWithItsOwnKnobsAndEveryWholeClipEffectItIsHeardWith() throws {
        let tuned = try Tuned()
        #expect(tuned.project.copiedSound(ofClip: tuned.source) == tuned.copied)
        #expect(tuned.project.copiedSound(ofClip: UUID()) == nil)

        // A clip on a track without a Sound and without effects has a sound too: none of either.
        var project = tuned.project
        let plain = record(2, in: &project, track: 1)
        #expect(project.copiedSound(ofClip: plain) == CopiedSound(sound: nil, effects: []))
    }

    @Test func aTracksSoundIsItsSoundAndItsEffects() throws {
        let tuned = try Tuned()
        let track = tuned.project.tracks[0].id
        #expect(tuned.project.copiedSound(ofTrack: track) == CopiedSound(sound: rapLead, effects: [
            Effect(kind: .thick, levelDb: -9), Effect(kind: .echoQuarter, levelDb: -6), Effect(kind: .phone, levelDb: 0),
        ]))
        #expect(tuned.project.copiedSound(ofTrack: tuned.project.tracks[1].id) == CopiedSound(sound: nil, effects: []))
        #expect(tuned.project.copiedSound(ofTrack: UUID()) == nil)
    }

    @Test func pastedOnAClipOfTheSameTrackItIsHeardTheSameAndPastedAgainNothingChanges() throws {
        var tuned = try Tuned()
        let target = record(6, in: &tuned.project)
        let wordEffect = try #require(answer {
            tuned.project.addEffect(target, kind: .tapeStop, span: word(of: target, in: tuned.project))
        })

        #expect(answer { tuned.project.pasteSound(tuned.copied, onClips: [target]) })
        let clip = try #require(tuned.project.clip(target))
        // A knob follows the track where the copied value is the track's, and is the clip's own where not.
        #expect(clip.knobs == ClipKnobs(space: 0.6))
        #expect(tuned.project.knobs(of: clip) == tuned.copied.sound?.knobs)
        #expect(clip.effectChanges == [
            ClipEffectChange(effectID: tuned.thick, levelDb: -3),
            ClipEffectChange(effectID: tuned.echo, isOff: true),
        ])
        #expect(heardWhole(target, in: tuned.project) == sorted(tuned.copied.effects))
        // Its effect on a word stays, and the double that was left over is its own, under an id of its own.
        #expect(clip.effects.map(\.kind) == [.tapeStop, .lowOctave])
        #expect(clip.effects[0].id == wordEffect)
        #expect(tuned.project.clip(tuned.source)?.effects.contains { $0.id == clip.effects[1].id } == false)
        #expect(!tuned.project.hasAnotherSound(than: tuned.copied, onTracksOf: [target]))

        #expect(!answer { tuned.project.pasteSound(tuned.copied, onClips: [target]) })
        // The clip it was copied from has it already.
        #expect(!answer { tuned.project.pasteSound(tuned.copied, onClips: [tuned.source]) })
        #expect(!answer { tuned.project.pasteSound(tuned.copied, onClips: []) })
    }

    @Test func pastedOnAClipOfATrackWithOtherEffectsTheTracksAreMatchedSwitchedOffOrLeveled() throws {
        var tuned = try Tuned()
        let other = tuned.project.tracks[1].id
        tuned.project.setTrack(other, sound: sungLead)
        let big = try #require(answer { tuned.project.addTrackEffect(other, kind: .big) })
        let thick = try #require(answer { tuned.project.addTrackEffect(other, kind: .thick) })
        let phone = try #require(answer { tuned.project.addTrackEffect(other, kind: .phone) })
        let target = record(4, in: &tuned.project, track: 1)
        // What the clip had for itself: the phone off, a High of its own and a Low of its own at its level.
        tuned.project.setClips([target], trackEffect: phone, isOff: true)
        _ = try #require(answer { tuned.project.addEffect(target, kind: .high) })
        let low = try #require(answer { tuned.project.addEffect(target, kind: .lowOctave) })

        #expect(answer { tuned.project.pasteSound(tuned.copied, onClips: [target]) })
        let clip = try #require(tuned.project.clip(target))
        #expect(clip.effectChanges == [
            ClipEffectChange(effectID: big, isOff: true),
            ClipEffectChange(effectID: thick, levelDb: -3),
        ])
        // The High had no partner and is gone. The Low is the same effect at the copied level.
        #expect(clip.effects == [ClipEffect(id: low, kind: .lowOctave, levelDb: -12)])
        #expect(heardWhole(target, in: tuned.project) == sorted(tuned.copied.effects))
        // The track keeps its Sound, and the clip has the copied knobs over it.
        #expect(tuned.project.track(other)?.sound == sungLead)
        #expect(tuned.project.knobs(of: clip) == tuned.copied.sound?.knobs)
        #expect(tuned.project.hasAnotherSound(than: tuned.copied, onTracksOf: [target]))
        // The track's own effects are as they were.
        #expect(tuned.project.track(other)?.effects.map(\.levelDb) == [-9, -9, 0])
    }

    @Test func pastedOnAClipOfATrackWithoutASoundTheKnobsAndEffectsAreItsOwn() throws {
        var tuned = try Tuned()
        let target = record(4, in: &tuned.project, track: 2)

        #expect(tuned.project.hasAnotherSound(than: tuned.copied, onTracksOf: [target]))
        #expect(answer { tuned.project.pasteSound(tuned.copied, onClips: [target]) })
        let clip = try #require(tuned.project.clip(target))
        let knobs = try #require(tuned.copied.sound?.knobs)
        #expect(clip.knobs == ClipKnobs(squeeze: knobs.squeeze, tone: knobs.tone, warmth: knobs.warmth, space: knobs.space))
        #expect(clip.effects.map(Effect.init) == tuned.copied.effects)
        #expect(heardWhole(target, in: tuned.project) == sorted(tuned.copied.effects))
        #expect(tuned.project.tracks[2].sound == nil)

        // A copied sound without a Sound leaves the knobs alone and takes the effects away.
        #expect(answer { tuned.project.pasteSound(CopiedSound(sound: nil, effects: []), onClips: [target]) })
        #expect(tuned.project.clip(target)?.knobs == clip.knobs)
        #expect(tuned.project.clip(target)?.effects.isEmpty == true)
        #expect(!tuned.project.hasAnotherSound(than: CopiedSound(sound: nil, effects: []), onTracksOf: [target]))
        #expect(tuned.project.hasAnotherSound(than: CopiedSound(sound: nil, effects: []), onTracksOf: [tuned.source]))
    }

    @Test func theWaitingTakesGetTheSameAndKeepTheirOwnEffectsOnWords() throws {
        var tuned = try Tuned()
        let first = record(6, in: &tuned.project)
        let firstWord = try #require(answer {
            tuned.project.addEffect(first, kind: .swell, span: word(of: first, in: tuned.project))
        })
        let second = record(6, in: &tuned.project)
        #expect(tuned.project.takes(of: first).map(\.id) == [first, second])
        let shown = try #require(tuned.project.takes(of: first).first(where: \.isActiveTake)?.id)

        #expect(answer { tuned.project.pasteSound(tuned.copied, onClips: [shown]) })
        let takes = try [first, second].map { try #require(tuned.project.clip($0)) }
        for take in takes {
            #expect(take.knobs == ClipKnobs(space: 0.6))
            #expect(take.effectChanges == [
                ClipEffectChange(effectID: tuned.thick, levelDb: -3),
                ClipEffectChange(effectID: tuned.echo, isOff: true),
            ])
            #expect(heardWhole(take.id, in: tuned.project) == sorted(tuned.copied.effects))
        }
        // The added double is one effect of the line: the same id on every take.
        let added = takes.map { $0.effects.first { $0.span == nil }?.id }
        #expect(added[0] != nil && added[0] == added[1])
        #expect(takes[0].effects.contains { $0.id == firstWord && $0.span != nil })
        #expect(takes[1].effects.allSatisfy { $0.span == nil })
    }

    @Test func pastedOnATrackEveryClipOfItIsHeardWithExactlyTheCopiedSound() throws {
        var tuned = try Tuned()
        let track = tuned.project.tracks[0].id
        let other = record(6, in: &tuned.project)
        let waiting = record(6, in: &tuned.project)
        tuned.project.setClips([other], knob: .tone, to: 0.1)
        _ = try #require(answer { tuned.project.addEffect(other, kind: .small) })
        let onWord = try #require(answer { tuned.project.addEffect(other, kind: .phone, span: word(of: other, in: tuned.project)) })
        let elsewhere = record(2, in: &tuned.project, track: 1)
        tuned.project.setClips([elsewhere], knob: .tone, to: 0.9)

        #expect(answer { tuned.project.pasteSound(tuned.copied, onTrack: track) })
        let now = try #require(tuned.project.track(track))
        #expect(now.sound == tuned.copied.sound)
        #expect(now.effects.map(Effect.init) == tuned.copied.effects)
        #expect(now.effects.allSatisfy { ![tuned.thick, tuned.echo, tuned.phone].contains($0.id) })
        for clip in now.clips {
            #expect(clip.knobs.isEmpty)
            #expect(clip.effectChanges.isEmpty)
            #expect(clip.effects.allSatisfy { $0.span != nil })
            #expect(tuned.project.knobs(of: clip) == tuned.copied.sound?.knobs)
            #expect(heardWhole(clip.id, in: tuned.project) == sorted(tuned.copied.effects))
            #expect(tuned.project.copiedSound(ofClip: clip.id) == tuned.copied)
        }
        #expect(Set(now.clips.map(\.id)) == [tuned.source, other, waiting])
        // The effects on words stay, on the clip it was copied from too.
        #expect(tuned.project.clip(other)?.effects.map(\.id) == [onWord])
        #expect(tuned.project.clip(tuned.source)?.effects.map(\.kind) == [.stutter])
        // A clip of another track is left alone.
        #expect(tuned.project.clip(elsewhere)?.knobs == ClipKnobs(tone: 0.9))

        // Pasted again, nothing changes.
        let ids = now.effects.map(\.id)
        #expect(!answer { tuned.project.pasteSound(tuned.copied, onTrack: track) })
        #expect(tuned.project.track(track)?.effects.map(\.id) == ids)
        #expect(!answer { tuned.project.pasteSound(tuned.copied, onTrack: UUID()) })
    }

    @Test func aSoundWithoutASoundPastedOnATrackTakesItsSoundAway() throws {
        var tuned = try Tuned()
        let track = tuned.project.tracks[0].id
        #expect(answer { tuned.project.pasteSound(CopiedSound(sound: nil, effects: []), onTrack: track) })
        let now = try #require(tuned.project.track(track))
        #expect(now.sound == nil)
        #expect(now.effects.isEmpty)
        #expect(tuned.project.copiedSound(ofClip: tuned.source) == CopiedSound(sound: nil, effects: []))
    }

    @Test func twoOfAKindArePairedInOrderAndALeftOverOneIsAdded() throws {
        var project = song()
        let track = project.tracks[0].id
        let target = record(2, in: &project)
        let first = try #require(answer { project.addTrackEffect(track, kind: .thick) })
        let own = try #require(answer { project.addEffect(target, kind: .thick) })
        let copied = CopiedSound(sound: nil, effects: [
            Effect(kind: .thick, levelDb: -1), Effect(kind: .thick, levelDb: -2), Effect(kind: .thick, levelDb: -30),
        ])

        #expect(answer { project.pasteSound(copied, onClips: [target]) })
        let clip = try #require(project.clip(target))
        #expect(clip.effectChanges == [ClipEffectChange(effectID: first, levelDb: -1)])
        #expect(clip.effects.map(\.levelDb) == [-2, -24])
        #expect(clip.effects[0].id == own)
        #expect(clip.knobs.isEmpty)
    }
}
