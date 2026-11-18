import Foundation
import Testing
@testable import LockstepCore

/// Which older results may still be heard: `TrackVoices.mayBeHeardOn`.
@Suite("Which results may still be heard on a track with a Voice")
struct VoiceMayBeHeardTests {
    typealias Fix = VoiceFixture

    let recording = Recording(lengthSamples: 96_000, rawStart: 1)
    let clip: Clip
    let track: Track
    let now = UUID()
    let before = UUID()
    var voices = TrackVoices.none

    init() {
        clip = Clip(segments: [Segment(recordingID: recording.id, inSample: 0, outSample: 48_000)])
        track = Track(name: "Ad-libs", voice: Fix.darker, clips: [clip])
        voices.set(heard: now, before: before, forRecording: recording.id, onTrack: track.id)
    }

    @Test("A result made from the recording, from the voice that stands in now or from the one before may play")
    func whatMayBeHeard() {
        #expect(voices.mayBeHeardOn(madeFrom: .recordings, for: clip, on: track))
        #expect(voices.mayBeHeardOn(madeFrom: VoiceSources([recording.id: recording.id], onTrack: track.id), for: clip, on: track))
        #expect(voices.mayBeHeardOn(madeFrom: VoiceSources([recording.id: now], onTrack: track.id), for: clip, on: track))
        #expect(voices.mayBeHeardOn(madeFrom: VoiceSources([recording.id: before], onTrack: track.id), for: clip, on: track))
        // A result made from the recording may play on a track without a Voice too, and with no voices at all.
        #expect(TrackVoices.none.mayBeHeardOn(madeFrom: .recordings, for: clip, on: Track(clips: [clip])))
    }

    @Test("A result made from any other voice may not: an older setting, or another track's")
    func otherVoices() {
        #expect(!voices.mayBeHeardOn(madeFrom: VoiceSources([recording.id: UUID()], onTrack: track.id), for: clip, on: track))
        // The voice of another track for the same recording.
        var other = Track(name: "Hook", voice: Fix.deeper, clips: [clip])
        other.id = UUID()
        let theirs = UUID()
        var both = voices
        both.set(heard: theirs, before: nil, forRecording: recording.id, onTrack: other.id)
        #expect(!both.mayBeHeardOn(madeFrom: VoiceSources([recording.id: theirs], onTrack: track.id), for: clip, on: track))
        #expect(both.mayBeHeardOn(madeFrom: VoiceSources([recording.id: theirs], onTrack: other.id), for: clip, on: other))
        // Nothing stands in for the recording on this track yet.
        #expect(!TrackVoices.none.mayBeHeardOn(madeFrom: VoiceSources([recording.id: now], onTrack: track.id), for: clip, on: track))
    }

    @Test("Once the track's Voice is off, gone or in the middle, no result made from a voice may play")
    func theVoiceIsOff() {
        var off = track
        off.voice?.isOn = false
        var gone = track
        gone.voice = nil
        var neutral = track
        neutral.voice?.knobs = .neutral
        for track in [off, gone, neutral] {
            #expect(!voices.mayBeHeardOn(madeFrom: VoiceSources([recording.id: now], onTrack: track.id), for: clip, on: track))
            #expect(!voices.mayBeHeardOn(madeFrom: VoiceSources([recording.id: before], onTrack: track.id), for: clip, on: track))
            #expect(voices.mayBeHeardOn(madeFrom: .recordings, for: clip, on: track))
        }
    }

    @Test("A clip moved to a track with another Voice may not be heard from what it was made from")
    func aClipMovedToAnotherTrack() {
        var project = Project(
            songLengthSamples: 480_000,
            tracks: [track, Track(name: "Hook", voice: Fix.deeper), Track(name: "Harmony")],
            recordings: [recording]
        )
        let made = voices.standIns(for: clip, on: project.tracks[0])
        #expect(made == [recording.id: now])
        project.moveClips([clip.id], bySamples: 0, trackSteps: 1, voices: .none)
        let moved = project.tracks[1]
        #expect(moved.clips.map(\.id) == [clip.id])
        // The other track has a Voice and no voice yet: the clip starts with the recording there.
        #expect(!voices.mayBeHeardOn(madeFrom: VoiceSources(made, onTrack: track.id), for: clip, on: moved))
        #expect(voices.standIns(for: clip, on: moved).isEmpty)
        #expect(project.clipPlaybackPlan(from: 0, voices: voices).map(\.recordingID) == [recording.id])
        // When that track's own voice is there, the clip follows it, and the old result still may not play.
        let theirs = UUID()
        var both = voices
        both.set(heard: theirs, before: nil, forRecording: recording.id, onTrack: moved.id)
        #expect(project.clipPlaybackPlan(from: 0, voices: both).map(\.recordingID) == [theirs])
        #expect(!both.mayBeHeardOn(madeFrom: VoiceSources(made, onTrack: track.id), for: clip, on: moved))
        // Moved on to a track without a Voice: the recording, at once.
        project.moveClips([clip.id], bySamples: 0, trackSteps: 1, voices: .none)
        #expect(!both.mayBeHeardOn(madeFrom: VoiceSources(made, onTrack: track.id), for: clip, on: project.tracks[2]))
        #expect(project.clipPlaybackPlan(from: 0, voices: both).map(\.recordingID) == [recording.id])
    }

    @Test("What stood in just before counts only on the track the result was made for")
    func theSoundBeforeBelongsToItsTrack() {
        // Another track, whose voice for the recording was `before` until its knob was turned.
        var other = Track(name: "Hook", voice: Fix.darker, clips: [clip])
        other.id = UUID()
        var both = voices
        both.set(heard: UUID(), before: before, forRecording: recording.id, onTrack: other.id)
        // Made on this track from `before`, and the clip moved to the other one: not heard there, though
        // `before` is that track's sound before too.
        #expect(!both.mayBeHeardOn(
            madeFrom: VoiceSources([recording.id: before], onTrack: track.id), for: clip, on: other
        ))
        // Made on the other track itself from its sound before: heard while its newer one is made.
        #expect(both.mayBeHeardOn(
            madeFrom: VoiceSources([recording.id: before], onTrack: other.id), for: clip, on: other
        ))
        // The sound that stands in now is the same sound wherever the result was made: it may be heard.
        var same = voices
        same.set(heard: now, before: nil, forRecording: recording.id, onTrack: other.id)
        #expect(same.mayBeHeardOn(madeFrom: VoiceSources([recording.id: now], onTrack: track.id), for: clip, on: other))
    }

    @Test("A clip moved onto a track whose sound before is the voice its tightened sound was made from plays that track's voice")
    func aMovedClipDoesNotTakeTheTrackBefore() {
        var project = Project(
            songLengthSamples: 480_000,
            tracks: [track, Track(name: "Hook", voice: Fix.darker)],
            recordings: [recording]
        )
        project.tracks[0].clips[0].tighten = .lines
        let corrected = project.tracks[0].clips[0]
        let tightenedID = UUID()
        var tightened = TightenedSounds()
        tightened.set(
            tightenedID, for: corrected.segments[0], at: 0, of: corrected.id,
            madeFrom: VoiceSources([recording.id: before], onTrack: track.id)
        )
        let theirs = UUID()
        var both = voices
        both.set(heard: theirs, before: before, forRecording: recording.id, onTrack: project.tracks[1].id)
        project.moveClips([clip.id], bySamples: 0, trackSteps: 1, voices: .none)
        #expect(project.clipPlaybackPlan(from: 0, tightened: tightened, voices: both).map(\.recordingID) == [theirs])
    }

    @Test("Only the recordings the clip still plays are asked about")
    func recordingsTheClipNoLongerPlays() {
        let cutAway = UUID()
        #expect(voices.mayBeHeardOn(madeFrom: VoiceSources([recording.id: now, cutAway: UUID()], onTrack: track.id), for: clip, on: track))
        var joined = clip
        joined.segments.append(Segment(recordingID: cutAway, inSample: 0, outSample: 100))
        #expect(!voices.mayBeHeardOn(madeFrom: VoiceSources([recording.id: now, cutAway: UUID()], onTrack: track.id), for: joined, on: track))
    }
}

/// The safe limit asks about the sound a clip is read from on its own track.
///
/// One recording is on three tracks: one without a Voice, one whose voice peaks higher than the recording, and
/// one whose voice peaks lower. The recording is loud in its first half and quiet in its second, so a part cut
/// from the second half would be let louder if the limit forgot what held the whole clip back.
@Suite("The safe limit on tracks with a Voice")
struct VoiceSafeLimitTests {
    typealias Dry = ClipExporterTests
    typealias Fix = VoiceFixture

    let recording = Dry.recording()
    var project: Project
    let loud = UUID()
    let quiet = UUID()
    var sounds: [UUID: [Float]]
    var voices = TrackVoices.none

    init() {
        let recording = recording
        func clip() -> Clip {
            var clip = Dry.clip(recording, 0..<96_000)
            clip.normalizeGainDb = 4
            return clip
        }
        project = Dry.project(recording, [clip()])
        project.tracks.append(Track(name: "Ad-libs", voice: Fix.darker, clips: [clip()]))
        project.tracks.append(Track(name: "Hook", voice: Fix.deeper, clips: [clip()]))
        // About -6 dBFS at its highest in the first half, and a quarter of that in the second.
        var sound = Dry.voice(96_000)
        for index in 48_000..<96_000 { sound[index] *= 0.25 }
        sounds = [
            recording.id: sound,
            loud: Fix.voice(of: sound, times: 1.9),
            quiet: Fix.voice(of: sound, times: 0.5),
        ]
        voices.set(heard: loud, before: nil, forRecording: recording.id, onTrack: project.tracks[1].id)
        voices.set(heard: quiet, before: nil, forRecording: recording.id, onTrack: project.tracks[2].id)
    }

    var peaks: RecordingPeak { Dry.peaks(of: sounds) }

    /// The project with only the track at `index`, so its clip can be heard alone.
    func only(_ index: Int, of project: Project) -> Project {
        var one = project
        one.tracks = [project.tracks[index]]
        return one
    }

    /// What is heard of one track, without fades, so a cut changes no sample by itself.
    func row(_ index: Int, of project: Project) -> [Float] {
        OfflineMix.render(only(index, of: project), recordings: sounds, peaks: peaks, edgeFadeMs: 0, voices: voices)
    }

    @Test("A voice that peaks higher than its recording holds back only the clip on its own track")
    func eachTrackIsHeldBackByItsOwnSound() throws {
        let recordingPeak = try #require(sounds[recording.id]).reduce(0) { max($0, abs($1)) }
        let pieces = project.clipPlaybackPlan(from: 0, peaks: peaks, voices: voices)
        #expect(pieces.map(\.recordingID) == [recording.id, loud, quiet])
        // Normalize's 4 dB fit under the limit for the recording and for the quiet voice.
        #expect(pieces[0].gainDb == 4)
        #expect(pieces[2].gainDb == 4)
        // The loud voice is held back to where its own highest sample sits at -1 dBFS.
        let room = Clip.safeLimitDb - 20 * log10(Double(recordingPeak * 1.9))
        #expect(room < 4)
        #expect(abs(pieces[1].gainDb - room) < 1e-9)

        for (index, track) in project.tracks.enumerated() {
            let applied = track.clips[0].appliedGain(peaks: peaks, voices: voices, on: track)
            #expect(applied.isHeldBack == (index == 1))
            // The form the app uses, with a closure it may keep, gives the same answer.
            #expect(track.clips[0].appliedGain(peaks: voices.peaks(Dry.peaks(of: sounds), on: track)) == applied)
        }
        // Asked without voices, no clip is held back: the recording alone decides, as before this phase.
        #expect(project.clipPlaybackPlan(from: 0, peaks: peaks, voices: .none).map(\.gainDb) == [4, 4, 4])
    }

    @Test("A split and a join on each track keep each part as loud as it was heard there")
    func splitAndJoinKeepTheLoudness() throws {
        for index in project.tracks.indices {
            let before = row(index, of: project)
            var edited = project
            let clipID = edited.tracks[index].clips[0].id
            let split = edited.splitClip(clipID, at: 1.5, peaks: peaks, voices: voices)
            let pieces = try #require(split)
            #expect(edited.tracks[index].clips.count == 2)
            #expect(row(index, of: edited) == before)
            // Only the clip that was held back got the lowering as its own.
            let own = edited.tracks[index].clips.flatMap(\.segments).map(\.gainDb)
            #expect(own.allSatisfy { index == 1 ? $0 < 0 : $0 == 0 })

            let joined = edited.joinClips([pieces.first, pieces.second], peaks: peaks, voices: voices)
            #expect(joined == pieces.first)
            #expect(edited.tracks[index].clips.count == 1)
            #expect(row(index, of: edited) == before)
        }
    }

    @Test("Asked about the recording alone, a split on the track with the loud voice would change what is heard")
    func whyTheEditsAreHandedVoices() {
        let before = row(1, of: project)
        var edited = project
        let split = edited.splitClip(edited.tracks[1].clips[0].id, at: 1.5, peaks: peaks, voices: .none)
        #expect(split != nil)
        // The quiet second half is no longer held back by the first half's peak, and comes out louder.
        #expect(row(1, of: edited) != before)
    }

    @Test("A trim, a cut and a clip that gives way keep what is left as loud as it was heard")
    func trimCutAndGivingWay() {
        let track = project.tracks[1]
        let clipID = track.clips[0].id
        let before = row(1, of: project)
        let start = Dry.recordingPlace

        var trimmed = project
        let edge = trimmed.trimClip(clipID, edge: .start, toSongSample: start + 60_000, peaks: peaks, voices: voices)
        #expect(edge == start + 60_000)
        #expect(row(1, of: trimmed)[(start + 60_000)...] == before[(start + 60_000)...])

        var cut = project
        let left = cut.cut(range: 0.5..<1.5, onTrack: track.id, peaks: peaks, voices: voices)
        #expect(left?.count == 2)
        #expect(row(1, of: cut)[72_000...] == before[72_000...])

        // A copy pasted over the loud first half: what is left of the clip under it sounds as it did.
        var covered = project
        let copies = CopiedClips(items: [CopiedClips.Item(clip: Dry.clip(recording, 0..<30_000), trackStep: 0)])
        let pasted = covered.paste(copies, onTrack: track.id, atSample: start, peaks: peaks, voices: voices)
        #expect(pasted.count == 1)
        #expect(covered.tracks[1].clips.count == 2)
        #expect(row(1, of: covered)[(start + 60_000)...] == before[(start + 60_000)...])
    }

    /// What is heard of the track with this id, without fades, wherever it lies in the project's list.
    func row(of trackID: UUID, in project: Project) -> [Float] {
        row(project.tracks.firstIndex { $0.id == trackID } ?? 0, of: project)
    }

    /// The song samples of the quiet end of the clip on the loud voice's track that no clip below covers:
    /// from 60,000 samples into the clip to its end.
    var quietEnd: Range<Int> { Dry.recordingPlace + 60_000..<Dry.recordingPlace + 96_000 }

    /// The project with track 0 holding only a short clip of the recording's loud first half and the start of
    /// its quiet half, which lies over the middle of the clip on the loud voice's track, not at its start, so
    /// that clip gives way to it when it comes there.
    var withAShortClipAbove: (project: Project, shortID: UUID) {
        var edited = project
        let short = Dry.clip(recording, 20_000..<50_000)
        edited.tracks[0].clips = [short]
        return (edited, short.id)
    }

    @Test("A clip moved, duplicated or merged onto the track with the loud voice leaves what gives way as loud as it was")
    func whatGivesWayToAClipThatCameKeepsItsLoudness() throws {
        let (above, shortID) = withAShortClipAbove
        let loudTrack = project.tracks[1].id
        let before = row(of: loudTrack, in: above)
        /// The quiet end on the loud voice's track after an edit, and the same edit asked about the recording
        /// alone, which must have come out otherwise for the test to say anything.
        func check(_ edit: (inout Project, TrackVoices) -> Void) {
            var edited = above
            edit(&edited, voices)
            #expect(edited.tracks.first { $0.id == loudTrack }?.clips.count == 3)
            #expect(row(of: loudTrack, in: edited)[quietEnd] == before[quietEnd])
            var unasked = above
            edit(&unasked, .none)
            #expect(row(of: loudTrack, in: unasked)[quietEnd] != before[quietEnd])
        }
        check { project, voices in
            let move = project.moveClips([shortID], bySamples: 0, trackSteps: 1, peaks: peaks, voices: voices)
            #expect(!move.isNothing)
        }
        check { project, voices in
            let move = project.allowedMove(of: [shortID], bySamples: 0, trackSteps: 1)
            let copies = project.duplicateClips([shortID], by: move, newIDs: [:], peaks: peaks, voices: voices)
            #expect(copies.count == 1)
        }
        check { project, voices in
            let from = project.tracks[0].id
            let merged = project.mergeTrack(from, into: loudTrack, peaks: peaks, voices: voices)
            #expect(merged)
        }
    }

    @Test("A take chosen over the clip of another line on the track with the loud voice leaves it as loud as it was")
    func whatGivesWayToAChosenTakeKeepsItsLoudness() throws {
        var edited = project
        // A line whose shown take lies after the long clip, and whose take that waits lies over its middle.
        let line = UUID()
        let shown = Clip(
            segments: [Segment(recordingID: recording.id, inSample: 0, outSample: 10_000, offsetSamples: 150_000)],
            line: line
        )
        let waiting = Clip(
            segments: [Segment(recordingID: recording.id, inSample: 20_000, outSample: 50_000)],
            isActiveTake: false,
            line: line
        )
        edited.tracks[1].clips += [shown, waiting]
        let before = row(1, of: edited)
        var chosen = edited
        let cut = chosen.chooseTake(waiting.id, peaks: peaks, voices: voices)
        #expect(cut)
        #expect(chosen.tracks[1].clips.filter(\.isActiveTake).count == 3)
        #expect(row(1, of: chosen)[quietEnd] == before[quietEnd])
        var unasked = edited
        let cutUnasked = unasked.chooseTake(waiting.id, peaks: peaks, voices: .none)
        #expect(cutUnasked)
        #expect(row(1, of: unasked)[quietEnd] != before[quietEnd])
    }

    @Test("The dry export of each clip is the bytes of the same project with the Voices taken off")
    func theDryExportIsUntouched() throws {
        var edited = project
        let split = edited.splitClip(edited.tracks[1].clips[0].id, at: 1.5, peaks: peaks, voices: voices)
        #expect(split != nil)
        for project in [project, edited] {
            var plain = project
            for index in plain.tracks.indices { plain.tracks[index].voice = nil }
            for clip in project.tracks.flatMap(\.clips) {
                let own = try #require(ClipExporter.export(
                    clip.id, in: plain, recordings: sounds, peaks: peaks, edgeFadeMs: 5, voices: .none
                ))
                #expect(ClipExporter.export(clip.id, in: project, recordings: sounds, peaks: peaks, edgeFadeMs: 5, voices: .none) == own)
                #expect(ClipExporter.export(
                    clip.id, in: project, recordings: sounds, peaks: peaks, edgeFadeMs: 5, voices: .none
                ) == own)
            }
        }
        // With voices, the clip on the track with the loud voice is that voice, held back by its own peak.
        let loudClip = project.tracks[1].clips[0]
        let voiced = try #require(ClipExporter.export(
            loudClip.id, in: project, recordings: sounds, peaks: peaks, edgeFadeMs: 0, voices: voices
        ))
        let highest = voiced.samples.reduce(0) { max($0, abs($1)) }
        #expect(abs(20 * log10(Double(highest)) - Clip.safeLimitDb) < 1e-3)
    }
}

/// The edit that gives a track a Voice, and what the other edits do with one.
@Suite("A track's Voice and the edits")
struct ProjectVoicesTests {
    typealias Fix = VoiceFixture

    @Test("setTrack gives, changes and takes away a Voice, and says whether anything changed")
    func setTrackVoice() {
        var project = Project(tracks: [Track(name: "Track 1"), Track(name: "Track 2")])
        let id = project.tracks[1].id
        /// What the edit answers, asked outside the check so the project can be changed.
        func set(_ id: UUID, _ voice: TrackVoice?) -> Bool {
            project.setTrack(id, voice: voice)
        }
        #expect(set(id, nil) == false)
        #expect(set(id, Fix.darker))
        #expect(project.tracks[1].voice == Fix.darker)
        #expect(project.tracks[0].voice == nil)
        #expect(set(id, Fix.darker) == false)

        var off = Fix.darker
        off.isOn = false
        #expect(set(id, off))
        #expect(project.tracks[1].voice?.knobs == Fix.darker.knobs)
        #expect(project.tracks[1].voice?.isHeard == false)

        #expect(set(id, TrackVoice(knobs: VoiceKnobs(depth: 40, pitch: 0.3))))
        #expect(project.tracks[1].voice == TrackVoice(name: "Custom", knobs: VoiceKnobs(depth: 15, pitch: 0.5)))
        #expect(set(id, nil))
        #expect(project.tracks[1].voice == nil)
        #expect(set(UUID(), Fix.darker) == false)
    }

    @Test("Duplicate Track keeps the Voice, with everything else the track has")
    func duplicateKeepsTheVoice() throws {
        let recording = Recording(lengthSamples: 96_000, rawStart: 1)
        let clip = Clip(segments: [Segment(recordingID: recording.id, inSample: 0, outSample: 48_000)])
        var off = Fix.deeper
        off.isOn = false
        let original = Track(
            name: "Ad-libs", muted: true, gainDb: -3, sound: SoundPreset.builtIn[0].sound,
            effects: [ClipEffect(kind: .thick, levelDb: -6)], voice: off, clips: [clip]
        )
        var project = Project(tracks: [original], recordings: [recording])
        let made = project.duplicateTrack(original.id, withClips: true)
        let copyID = try #require(made)
        let copy = try #require(project.track(copyID))
        #expect(copy.voice == off)
        #expect(copy.id != original.id)
        #expect(copy.name == "Ad-libs copy")
        #expect(copy.muted)
        #expect(copy.gainDb == -3)
        #expect(copy.sound == original.sound)
        #expect(copy.effects == original.effects)
        #expect(copy.clips.count == 1)
        #expect(copy.clips[0].id != clip.id)
        #expect(copy.clips[0].segments == clip.segments)
        #expect(project.tracks[0] == original)

        let bare = project.duplicateTrack(original.id, withClips: false)
        let empty = try #require(bare)
        #expect(project.track(empty)?.voice == off)
        #expect(project.track(empty)?.clips.isEmpty == true)
    }

    @Test("After Merge Into the target keeps its own Voice, and the clips that came follow it")
    func mergeLeavesTheTargetsVoice() {
        let recording = Recording(lengthSamples: 96_000, rawStart: 1)
        let came = Clip(segments: [Segment(recordingID: recording.id, inSample: 0, outSample: 48_000)])
        let source = Track(name: "Ad-libs", voice: Fix.darker, clips: [came])
        let target = Track(name: "Hook", voice: Fix.deeper)
        let plain = Track(name: "Harmony")
        var project = Project(songLengthSamples: 480_000, tracks: [source, target, plain], recordings: [recording])
        let (darker, deeper) = (UUID(), UUID())
        var voices = TrackVoices.none
        voices.set(heard: darker, before: nil, forRecording: recording.id, onTrack: source.id)
        voices.set(heard: deeper, before: nil, forRecording: recording.id, onTrack: target.id)
        #expect(project.clipPlaybackPlan(from: 0, voices: voices).map(\.recordingID) == [darker])

        let merged = project.mergeTrack(source.id, into: target.id, voices: voices)
        #expect(merged)
        #expect(project.tracks.map(\.id) == [target.id, plain.id])
        #expect(project.tracks[0].voice == Fix.deeper)
        #expect(project.clipPlaybackPlan(from: 0, voices: voices).map(\.recordingID) == [deeper])

        // Merged into a track without a Voice: Max's own recording, and the track still has none.
        let mergedAgain = project.mergeTrack(target.id, into: plain.id, voices: voices)
        #expect(mergedAgain)
        #expect(project.tracks[0].voice == nil)
        #expect(project.clipPlaybackPlan(from: 0, voices: voices).map(\.recordingID) == [recording.id])
    }

    @Test("A copy pasted on another track, and a take recorded there, follow that track's Voice")
    func pastedAndRecordedClipsFollowTheirTrack() {
        let recording = Recording(lengthSamples: 96_000, rawStart: 1)
        let clip = Clip(segments: [Segment(recordingID: recording.id, inSample: 0, outSample: 48_000)])
        var project = Project(
            songLengthSamples: 960_000,
            tracks: [Track(name: "Double", clips: [clip]), Track(name: "Ad-libs", voice: Fix.darker)],
            recordings: [recording]
        )
        let voiced = project.tracks[1]
        let darker = UUID()
        var voices = TrackVoices.none
        voices.set(heard: darker, before: nil, forRecording: recording.id, onTrack: voiced.id)
        project.paste(project.copyClips([clip.id]), onTrack: voiced.id, atSample: 240_000, voices: voices)
        #expect(project.clipPlaybackPlan(from: 0, voices: voices).map(\.recordingID) == [recording.id, darker])

        // A new take on the track with the Voice plays its recording until its own voice is made.
        let take = Recording(lengthSamples: 48_000, rawStart: 10)
        let added = project.addRecording(take, samples: 0..<48_000, asClipOn: voiced.id, voices: voices)
        #expect(added != nil)
        #expect(project.clipPlaybackPlan(from: 0, voices: voices).map(\.recordingID) == [recording.id, darker, take.id])
        let takeVoice = UUID()
        voices.set(heard: takeVoice, before: nil, forRecording: take.id, onTrack: voiced.id)
        #expect(project.clipPlaybackPlan(from: 0, voices: voices).last?.recordingID == takeVoice)
    }
}

/// The order voices are made in and the count the panel shows.
@Suite("The queue of voices to make")
struct VoiceQueueTests {
    typealias Fix = VoiceFixture

    /// A recording of two seconds that starts at `seconds` of the song.
    static func recording(at seconds: Double) -> Recording {
        Recording(lengthSamples: 96_000, rawStart: seconds)
    }

    static func clip(_ recording: Recording, waits: Bool = false, line: UUID = UUID()) -> Clip {
        Clip(
            segments: [Segment(recordingID: recording.id, inSample: 0, outSample: recording.lengthSamples)],
            isActiveTake: !waits,
            line: line
        )
    }

    static func key(_ recording: Recording, _ voice: TrackVoice = Fix.darker) -> VoiceKey {
        VoiceKey(recordingID: recording.id, knobs: voice.knobs, way: .fast)
    }

    @Test("Heard clips come before waiting takes, and after the playhead before behind it")
    func theOrder() {
        // Clips at 2, 10, 20 and 30 seconds, each two seconds long, with a waiting take behind the one at 20.
        let early = Self.recording(at: 2)
        let under = Self.recording(at: 10)
        let next = Self.recording(at: 20)
        let waiting = Self.recording(at: 20)
        let late = Self.recording(at: 30)
        let line = UUID()
        let track = Track(name: "Ad-libs", voice: Fix.darker, clips: [
            Self.clip(late), Self.clip(waiting, waits: true, line: line), Self.clip(early),
            Self.clip(next, line: line), Self.clip(under),
        ])
        let project = Project(
            songLengthSamples: 48_000 * 60, tracks: [track], recordings: [early, under, next, waiting, late]
        )

        // The playhead is inside the clip at 10: it first, then what comes after, then what lies behind.
        #expect(VoiceQueue.order(project, playhead: 11) == [under, next, late, early, waiting].map { Self.key($0) })
        // From the start of the song, the order of the song.
        #expect(VoiceQueue.order(project, playhead: 0) == [early, under, next, late, waiting].map { Self.key($0) })
        // Past everything: the nearest behind first.
        #expect(VoiceQueue.order(project, playhead: 50) == [late, next, under, early, waiting].map { Self.key($0) })
        // A clip that ends exactly at the playhead is behind it.
        #expect(VoiceQueue.order(project, playhead: 12).first == Self.key(next))
    }

    @Test("A voice is in the order once, however many clips play its recording")
    func aRecordingOnce() {
        let recording = Self.recording(at: 2)
        // A split line: two clips of one recording, and a copy further on.
        var first = Self.clip(recording)
        first.segments[0].outSample = 40_000
        var second = Self.clip(recording)
        second.segments[0].inSample = 40_000
        var copy = Self.clip(recording)
        copy.segments[0].offsetSamples = 480_000
        let other = Self.recording(at: 6)
        // A joined clip that plays both recordings.
        var joined = Self.clip(other)
        joined.segments.append(Segment(recordingID: recording.id, inSample: 0, outSample: 9_600, offsetSamples: 960_000))
        let darker = Track(name: "Ad-libs", voice: Fix.darker, clips: [first, second, copy, joined])
        // The same recording on a track with the same setting, and on one with another.
        var same = Track(name: "Hook", voice: Fix.darker, clips: [Self.clip(recording)])
        same.voice?.name = "Custom"
        let deeper = Track(name: "Harmony", voice: Fix.deeper, clips: [Self.clip(recording)])
        let project = Project(
            songLengthSamples: 48_000 * 60, tracks: [darker, same, deeper], recordings: [recording, other]
        )
        #expect(VoiceQueue.order(project, playhead: 0) == [
            Self.key(recording), Self.key(recording, Fix.deeper), Self.key(other),
        ])
    }

    @Test("Nothing is asked for a track without a Voice, one that is off or in the middle, or a voice that is there")
    func whatIsNotWanted() {
        let recording = Self.recording(at: 2)
        let other = Self.recording(at: 6)
        var off = Fix.darker
        off.isOn = false
        var project = Project(
            songLengthSamples: 48_000 * 60,
            tracks: [
                Track(name: "Double", clips: [Self.clip(recording)]),
                Track(name: "Ad-libs", voice: off, clips: [Self.clip(recording)]),
                Track(name: "Hook", voice: TrackVoice(knobs: .neutral), clips: [Self.clip(recording)]),
            ],
            recordings: [recording, other]
        )
        #expect(VoiceQueue.order(project, playhead: 0).isEmpty)

        project.tracks[1].voice?.isOn = true
        project.tracks[1].clips.append(Self.clip(other))
        // A segment of a recording the project does not have asks for nothing.
        project.tracks[1].clips[0].segments.append(Segment(recordingID: UUID(), inSample: 0, outSample: 10))
        #expect(VoiceQueue.order(project, playhead: 0) == [Self.key(recording), Self.key(other)])
        #expect(VoiceQueue.order(project, playhead: 0, isThere: { $0 == Self.key(recording) }) == [Self.key(other)])
        #expect(VoiceQueue.order(project, playhead: 0, isThere: { _ in true }).isEmpty)
    }

    @Test("Another way asks for the same recordings in the same order, on the tracks that want it")
    func anotherWay() {
        let (first, second) = (Self.recording(at: 2), Self.recording(at: 6))
        var natural = Fix.darker
        natural.natural = true
        let project = Project(
            songLengthSamples: 48_000 * 60,
            tracks: [
                Track(name: "Ad-libs", voice: natural, clips: [Self.clip(second), Self.clip(first)]),
                Track(name: "Hook", voice: Fix.deeper, clips: [Self.clip(first)]),
            ],
            recordings: [first, second]
        )
        let model = VoiceWay(method: "seed-vc", revision: 1, sampleID: UUID())
        let order = VoiceQueue.order(project, playhead: 0, way: { $0.natural ? model : nil })
        #expect(order == [first, second].map { VoiceKey(recordingID: $0.id, knobs: natural.knobs, way: model) })
        #expect(VoiceQueue.progress(of: project.tracks[1].id, in: project, way: { $0.natural ? model : nil }) { _ in
            false
        } == VoiceQueue.Progress(done: 0, clips: 0))
    }

    @Test("The progress of a track counts its shown clips, and a split line is two clips of one recording")
    func theProgress() {
        let recording = Self.recording(at: 2)
        var first = Self.clip(recording)
        first.segments[0].outSample = 40_000
        var second = Self.clip(recording)
        second.segments[0].inSample = 40_000
        let other = Self.recording(at: 10)
        let waiting = Self.recording(at: 10)
        let line = UUID()
        var muted = Self.clip(other, line: line)
        muted.muted = true
        let track = Track(name: "Ad-libs", voice: Fix.darker, clips: [
            first, second, muted, Self.clip(waiting, waits: true, line: line),
        ])
        var project = Project(
            songLengthSamples: 48_000 * 60,
            tracks: [Track(name: "Double", clips: [Self.clip(recording)]), track],
            recordings: [recording, other, waiting]
        )
        func progress(_ there: Set<UUID>, of id: UUID = track.id) -> VoiceQueue.Progress {
            var asked: [UUID] = []
            let progress = VoiceQueue.progress(of: id, in: project) { key in
                asked.append(key.recordingID)
                return key.knobs == Fix.darker.knobs && key.way == .fast && there.contains(key.recordingID)
            }
            // Each voice is asked about once.
            #expect(Set(asked).count == asked.count)
            return progress
        }
        #expect(progress([]) == VoiceQueue.Progress(done: 0, clips: 3))
        #expect(!progress([]).isComplete)
        // The one recording of the split line makes both of its clips done.
        #expect(progress([recording.id]) == VoiceQueue.Progress(done: 2, clips: 3))
        // The take that waits is not counted, made or not.
        #expect(progress([recording.id, waiting.id]) == VoiceQueue.Progress(done: 2, clips: 3))
        #expect(progress([recording.id, other.id]) == VoiceQueue.Progress(done: 3, clips: 3))
        #expect(progress([recording.id, other.id]).isComplete)
        // A track without a Voice, one the project does not have, and a Voice that is off: nothing of nothing.
        #expect(progress([], of: project.tracks[0].id) == VoiceQueue.Progress(done: 0, clips: 0))
        #expect(progress([], of: UUID()) == VoiceQueue.Progress(done: 0, clips: 0))
        project.tracks[1].voice?.isOn = false
        #expect(progress([recording.id]) == VoiceQueue.Progress(done: 0, clips: 0))
    }
}

/// What is removed from a project's voices folder when the project closes.
@Suite("Which voice files are stale")
struct VoiceFilesTests {
    typealias Fix = VoiceFixture

    static let fast = VoiceWay(method: "world", revision: 3)
    let kept = Recording(lengthSamples: 96_000, rawStart: 1)
    let other = Recording(lengthSamples: 96_000, rawStart: 5)
    let gone = UUID()
    var project: Project

    init() {
        var off = Fix.deeper
        off.isOn = false
        project = Project(
            tracks: [Track(name: "Double"), Track(name: "Ad-libs", voice: Fix.darker), Track(name: "Hook", voice: off)],
            recordings: [kept, other]
        )
    }

    /// The path of a voice inside the voices folder, as `ProjectPackage.voiceFile(for:)` lays it out.
    static func path(_ recordingID: UUID, _ knobs: VoiceKnobs, _ way: VoiceWay = fast) -> String {
        let package = ProjectPackage(url: URL(fileURLWithPath: "/tmp/Song.lockstep"))
        let file = package.voiceFile(for: VoiceKey(recordingID: recordingID, knobs: knobs, way: way))
        return String(file.path.dropFirst(package.voicesFolder.path.count + 1))
    }

    func stale(_ listing: [String], ways: [VoiceWay] = [fast]) -> [String] {
        VoiceFiles.stale(in: listing, of: project, ways: ways)
    }

    @Test("Nothing of a track's setting is removed, whether its Voice is on or off")
    func whatIsKept() {
        #expect(Self.path(kept.id, Fix.darker.knobs) == "world-r3/d+06p-1.0/\(kept.id.uuidString).wav")
        let listing = [
            "world-r3", "world-r3/d+06p-1.0", "world-r3/d+10p-2.0",
            Self.path(kept.id, Fix.darker.knobs), Self.path(other.id, Fix.darker.knobs),
            Self.path(kept.id, Fix.deeper.knobs), Self.path(other.id, Fix.deeper.knobs),
        ]
        #expect(stale(listing).isEmpty)
        #expect(stale([]).isEmpty)
        // A file that is none of Lockstep's is left alone in a folder that is kept.
        #expect(stale(listing + ["world-r3/d+06p-1.0/.DS_Store", "world-r3/d+06p-1.0/notes/readme.txt"]).isEmpty)
    }

    @Test("A setting no track has, a way that is not current, a partial file and a recording that is gone go")
    func whatIsRemoved() {
        let tried = VoiceKnobs(depth: 8, pitch: -1.5)
        let partial = "world-r3/d+06p-1.0/\(other.id.uuidString).\(UUID().uuidString).partial"
        let listing = [
            Self.path(kept.id, Fix.darker.knobs),
            // A setting that was tried and left.
            Self.path(kept.id, tried), Self.path(other.id, tried),
            // Made by an older revision of the method, and by another method.
            Self.path(kept.id, Fix.darker.knobs, VoiceWay(method: "world", revision: 2)),
            Self.path(kept.id, Fix.darker.knobs, VoiceWay(method: "rubberband", revision: 1)),
            partial,
            Self.path(gone, Fix.darker.knobs),
            Self.path(gone, Fix.deeper.knobs),
        ]
        #expect(stale(listing) == [
            "rubberband-r1",
            "world-r2",
            "world-r3/d+06p-1.0/\(gone.uuidString).wav",
            partial,
            "world-r3/d+08p-1.5",
            "world-r3/d+10p-2.0/\(gone.uuidString).wav",
        ].sorted())
        // A folder that goes is named once, without what is in it, and a listing with the folders in it
        // gives the same answer.
        #expect(stale(listing + ["world-r2", "world-r2/d+06p-1.0", "world-r3/d+08p-1.5"]) == stale(listing))
    }

    @Test("The folder of both knobs in the middle is never kept, and a recording's id is read in any case")
    mutating func theMiddleAndTheCase() {
        project.tracks[0].voice = TrackVoice(knobs: .neutral)
        #expect(stale([Self.path(kept.id, .neutral)]) == ["world-r3/d+00p+0.0"])
        let lowercase = "world-r3/d+06p-1.0/\(kept.id.uuidString.lowercased()).wav"
        #expect(stale([lowercase]).isEmpty)
    }

    @Test("With a second way that is current, its folder is kept by the same rules")
    func aNaturalWay() {
        let natural = VoiceWay(method: "seed-vc", revision: 1, sampleID: UUID())
        let older = VoiceWay(method: "seed-vc", revision: 1, sampleID: UUID())
        let listing = [
            Self.path(kept.id, Fix.darker.knobs, natural), Self.path(gone, Fix.darker.knobs, natural),
            Self.path(kept.id, Fix.darker.knobs, older), Self.path(kept.id, Fix.darker.knobs),
        ]
        #expect(stale(listing, ways: [Self.fast, natural]) == [
            older.folderName, "\(natural.folderName)/d+06p-1.0/\(gone.uuidString).wav",
        ].sorted())
        // Without the second way handed in, everything made that way goes.
        #expect(stale(listing) == [natural.folderName, older.folderName].sorted())
    }
}
