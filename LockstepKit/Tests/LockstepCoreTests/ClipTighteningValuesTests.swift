import Foundation
import Testing
@testable import LockstepCore

/// A twenty-second song with one empty track, "Track 1".
private func emptySong() -> Project {
    Project(songLengthSamples: 960_000)
}

/// Records a clip the way the app does: a new recording that begins `start` seconds into the song and is
/// `seconds` long, with all of it as the clip, on the first track. Returns the id of the clip.
@discardableResult
private func record(_ start: Double, _ seconds: Double = 1, in project: inout Project, aimedAt aim: Double? = nil) -> UUID {
    let recording = Recording(lengthSamples: Int((seconds * Lockstep.sampleRate).rounded()), rawStart: start)
    return project.addRecording(
        recording,
        samples: 0..<recording.lengthSamples,
        asClipOn: project.tracks[0].id,
        aim: aim.map { RecordAim(place: $0) }, voices: .none
    )!
}

/// Gives one clip its correction, the way the panel does for a selected clip.
private func correct(
    _ id: UUID,
    _ tighten: ClipTighten,
    strength: Double,
    stretch: Bool = false,
    feel: ClipFeel = .sixteenths,
    in project: inout Project
) {
    project.setClips([id], tighten: tighten)
    project.setClips([id], strength: strength)
    project.setClips([id], stretch: stretch)
    project.setClips([id], feel: feel)
}

/// The correction of timing is kept for each clip: the choice of Off, Lines or All, the strength and
/// Stretch. What a project saved before that opens as, and what a new take, the pieces of a split and a
/// joined clip start with.
@Suite("Correction, kept for each clip")
struct ClipTighteningValuesTests {
    // MARK: A project saved before

    /// A project file with one track and these clips, each given as the fields it was saved with.
    private func project(clips fields: [String], track: String = "") throws -> Project {
        let id = UUID()
        let clips = fields.enumerated().map { index, fields in
            let segment = #"{ "recordingID": "\#(id.uuidString)", "inSample": \#(index * 200), "outSample": \#(index * 200 + 100) }"#
            return #"{ \#(fields.isEmpty ? "" : fields + ",") "segments": [ \#(segment) ] }"#
        }
        let text = """
            {
              "tracks": [ { "name": "Lead", \(track.isEmpty ? "" : track + ",") "clips": [ \(clips.joined(separator: ", ")) ] } ],
              "recordings": [ { "id": "\(id.uuidString)", "lengthSamples": 1000, "rawStart": 1.5 } ]
            }
            """
        return try JSONDecoder().decode(Project.self, from: Data(text.utf8))
    }

    @Test func aClipSavedWithLinesOnAndSyllablesAtZeroIsLinesAtFullStrength() throws {
        let clip = try #require(try project(clips: [#""tightenLines": true, "strength": 0"#]).tracks[0].clips.first)
        #expect(clip.tighten == .lines)
        // Its lines slid the whole way when it was saved, and still do.
        #expect(clip.strength == 1)
        #expect(!clip.stretch)
        #expect(clip.tightenWhenOn == .lines)
    }

    @Test func aClipSavedWithSyllablesAboveZeroIsAllWithThatStrength() throws {
        let saved = try project(clips: [
            #""tightenLines": true, "strength": 0.6"#,
            // Syllables moved without the lines sliding: All too, since that is where syllables move.
            #""tightenLines": false, "strength": 0.25"#,
        ])
        #expect(saved.tracks[0].clips.map(\.tighten) == [.all, .all])
        #expect(saved.tracks[0].clips.map(\.strength) == [0.6, 0.25])
        #expect(saved.tracks[0].clips.map(\.stretch) == [false, false])
    }

    @Test func everyOtherClipSavedBeforeIsOffWithTheStartingStrength() throws {
        let saved = try project(clips: [#""tightenLines": false, "strength": 0"#, ""])
        for clip in saved.tracks[0].clips {
            #expect(clip.tighten == .off)
            #expect(clip.strength == 1)
            #expect(!clip.stretch)
            // Correction On or Off gives a clip that never had a choice All.
            #expect(clip.tightenWhenOn == .all)
            #expect(!clip.hasTimingFix)
        }
    }

    @Test func everyClipOfATrackSavedBeforePhase27GetsWhatItsTrackStoodFor() throws {
        let lines = try project(clips: ["", ""], track: #""tightenLines": true, "strength": 0"#)
        #expect(lines.tracks[0].clips.map(\.tighten) == [.lines, .lines])
        #expect(lines.tracks[0].clips.map(\.strength) == [1, 1])
        let all = try project(clips: ["", ""], track: #""tightenLines": true, "strength": 0.6"#)
        #expect(all.tracks[0].clips.map(\.tighten) == [.all, .all])
        #expect(all.tracks[0].clips.map(\.strength) == [0.6, 0.6])
        let syllablesOnly = try project(clips: [""], track: #""strength": 0.25"#)
        #expect(syllablesOnly.tracks[0].clips.map(\.tighten) == [.all])
        let plain = try project(clips: [""])
        #expect(plain.tracks[0].clips.map(\.tighten) == [.off])
        #expect(plain.tracks[0].clips.map(\.stretch) == [false])
    }

    @Test func aProjectSavedNowKeepsTheValuesOnItsClipsAndNotOnItsTracks() throws {
        var project = emptySong()
        let tight = record(2, in: &project)
        let plain = record(6, in: &project)
        correct(tight, .all, strength: 0.4, stretch: true, in: &project)
        // Lines, then Off: the clip remembers Lines as what to switch back to.
        let compared = record(10, in: &project)
        correct(compared, .lines, strength: 0, in: &project)
        project.setClips([compared], corrected: false)

        let saved = try JSONEncoder().encode(project)
        let read = try JSONDecoder().decode(Project.self, from: saved)
        #expect(read == project)
        #expect(read.clip(tight)?.tighten == .all)
        #expect(read.clip(tight)?.strength == 0.4)
        #expect(read.clip(tight)?.stretch == true)
        #expect(read.clip(plain)?.tighten == .off)
        #expect(read.clip(plain)?.strength == 1)
        #expect(read.clip(plain)?.stretch == false)
        // A strength of 0 that was chosen is kept as 0: it is not taken for a clip saved before.
        #expect(read.clip(compared)?.tighten == .off)
        #expect(read.clip(compared)?.tightenWhenOn == .lines)
        #expect(read.clip(compared)?.strength == 0)

        // The track itself says nothing about the correction, and no clip is written the old way.
        let json = try #require(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        let track = try #require((json["tracks"] as? [[String: Any]])?.first)
        #expect(track["tightenLines"] == nil)
        #expect(track["strength"] == nil)
        let clips = try #require(track["clips"] as? [[String: Any]])
        #expect(clips.allSatisfy { $0["tighten"] != nil && $0["strength"] != nil && $0["stretch"] != nil })
        #expect(clips.allSatisfy { $0["tightenLines"] == nil })
        #expect(clips.map { $0["tighten"] as? String } == ["all", "off", "off"])
    }

    // MARK: A new take

    @Test func aNewTakeOfALineStartsWithWhatTheActiveTakeHas() throws {
        var project = emptySong()
        let first = record(2, in: &project)
        project.normalizeTakes()
        correct(first, .lines, strength: 0.7, stretch: true, feel: .triplets, in: &project)

        let second = record(2.1, in: &project, aimedAt: 2)
        project.normalizeTakes()

        let take = try #require(project.clip(second))
        #expect(project.takes(of: second).map(\.id) == [first, second])
        #expect(take.isActiveTake)
        #expect(take.tighten == .lines)
        #expect(take.tightenWhenOn == .lines)
        #expect(take.strength == 0.7)
        #expect(take.stretch)
        #expect(take.feel == .triplets)
    }

    @Test func aNewTakeOfALineThatIsOffSwitchesBackToWhatTheLineHadLast() throws {
        var project = emptySong()
        let first = record(2, in: &project)
        project.normalizeTakes()
        correct(first, .lines, strength: 0.7, in: &project)
        project.setClips([first], corrected: false)

        let second = record(2.1, in: &project, aimedAt: 2)
        project.normalizeTakes()

        #expect(project.clip(second)?.tighten == .off)
        #expect(project.clip(second)?.tightenWhenOn == .lines)
    }

    @Test func aNewTakeFollowsTheTakeThatIsHeardNotTheOneRecordedLast() throws {
        var project = emptySong()
        let first = record(2, in: &project)
        let second = record(2.1, in: &project, aimedAt: 2)
        project.normalizeTakes()
        // The older take is chosen, and the two are set differently, as after a clip was moved onto a line.
        project.setActiveTake(first)
        project.tracks[0].clips[0].tighten = .lines
        project.tracks[0].clips[0].strength = 0.3
        project.tracks[0].clips[1].tighten = .all
        project.tracks[0].clips[1].strength = 0.9
        project.tracks[0].clips[1].stretch = true

        let third = record(2.2, in: &project, aimedAt: 2)
        project.normalizeTakes()

        #expect(project.takes(of: third).map(\.id) == [first, second, third])
        #expect(project.clip(third)?.tighten == .lines)
        #expect(project.clip(third)?.strength == 0.3)
        #expect(project.clip(third)?.stretch == false)
    }

    @Test func aClipOnANewLineStartsWithEverythingOff() throws {
        var project = emptySong()
        let first = record(2, in: &project)
        project.normalizeTakes()
        correct(first, .all, strength: 0.7, stretch: true, feel: .triplets, in: &project)

        // Right after the first line, and far too little on top of it to be a take of it.
        let next = record(2.9, in: &project)
        project.normalizeTakes()

        let clip = try #require(project.clip(next))
        #expect(project.takeCount(of: next) == 1)
        #expect(clip.tighten == .off)
        #expect(clip.strength == 1)
        #expect(!clip.stretch)
        #expect(clip.feel == .sixteenths)
    }

    // MARK: Split and join

    @Test func theTwoHalvesOfASplitKeepTheClipsValues() throws {
        var project = emptySong()
        let whole = record(2, 2, in: &project)
        project.normalizeTakes()
        correct(whole, .all, strength: 0.45, stretch: true, in: &project)

        let split = project.splitClip(whole, at: 3, voices: .none)
        let pieces = try #require(split)

        for piece in [pieces.first, pieces.second] {
            #expect(project.clip(piece)?.tighten == .all)
            #expect(project.clip(piece)?.tightenWhenOn == .all)
            #expect(project.clip(piece)?.strength == 0.45)
            #expect(project.clip(piece)?.stretch == true)
        }
    }

    @Test func aJoinedClipTakesTheFirstClipsValues() throws {
        var project = emptySong()
        let first = record(2, in: &project)
        let second = record(4, in: &project)
        project.normalizeTakes()
        correct(first, .lines, strength: 0.2, in: &project)
        correct(second, .all, strength: 0.8, stretch: true, in: &project)

        let made = project.joinClips([first, second], voices: .none)
        let joined = try #require(made)

        #expect(joined == first)
        #expect(project.clip(joined)?.tighten == .lines)
        #expect(project.clip(joined)?.strength == 0.2)
        #expect(project.clip(joined)?.stretch == false)
    }

    // MARK: Setting

    @Test func settingSeveralClipsChangesThemAndTheTakesBehindThem() throws {
        var project = emptySong()
        let waiting = record(2, in: &project)
        let heard = record(2.1, in: &project, aimedAt: 2)
        let other = record(6, in: &project)
        let untouched = record(10, in: &project)
        project.normalizeTakes()

        let choiceChanged = project.setClips([heard, other], tighten: .all)
        let strengthChanged = project.setClips([heard, other], strength: 0.5)
        let stretchChanged = project.setClips([heard, other], stretch: true)

        #expect(choiceChanged)
        #expect(strengthChanged)
        #expect(stretchChanged)
        for id in [waiting, heard, other] {
            #expect(project.clip(id)?.tighten == .all)
            #expect(project.clip(id)?.strength == 0.5)
            #expect(project.clip(id)?.stretch == true)
        }
        #expect(project.clip(untouched)?.tighten == .off)
        #expect(project.clip(untouched)?.strength == 1)
        #expect(project.clip(untouched)?.stretch == false)
        // Asked for what they already have, nothing changes, so the app makes no undo step.
        let choiceChangedAgain = project.setClips([heard, other], tighten: .all)
        let strengthChangedAgain = project.setClips([heard, other], strength: 0.5)
        let stretchChangedAgain = project.setClips([heard, other], stretch: true)
        #expect(!choiceChangedAgain)
        #expect(!strengthChangedAgain)
        #expect(!stretchChangedAgain)
    }

    @Test func switchingOffAndOnGivesEachClipTheChoiceItHadLast() throws {
        var project = emptySong()
        let lines = record(2, in: &project)
        let all = record(6, in: &project)
        let never = record(10, in: &project)
        project.normalizeTakes()
        project.setClips([lines], tighten: .lines)
        project.setClips([all], tighten: .all)
        project.setClips([all], strength: 0.35)

        let switchedOff = project.setClips([lines, all, never], corrected: false)
        #expect(switchedOff)
        #expect([lines, all, never].map { project.clip($0)?.tighten } == [.off, .off, .off])
        // A clip keeps its strength while it is Off.
        #expect(project.clip(all)?.strength == 0.35)

        let switchedOn = project.setClips([lines, all, never], corrected: true)
        #expect(switchedOn)
        // Each has what it had last, and the one that never had a choice gets All.
        #expect([lines, all, never].map { project.clip($0)?.tighten } == [.lines, .all, .all])
        #expect(project.clip(all)?.strength == 0.35)
        let switchedOnAgain = project.setClips([lines, all, never], corrected: true)
        #expect(!switchedOnAgain)
    }

    @Test func theStrengthIsKeptInWholePercentBetweenZeroAndOne() throws {
        var project = emptySong()
        let clip = record(2, in: &project)

        project.setClips([clip], strength: 0.337)
        #expect(project.clip(clip)?.strength == 0.34)
        project.setClips([clip], strength: 4)
        #expect(project.clip(clip)?.strength == 1)
        project.setClips([clip], strength: -1)
        #expect(project.clip(clip)?.strength == 0)
    }

    @Test func whatIsHeardFollowsTheChoice() {
        var clip = Clip()
        clip.strength = 0.6
        clip.stretch = true
        // Off: nothing. The strength and Stretch are kept and wait.
        #expect(clip.lineStrength == 0 && clip.syllableStrength == 0 && !clip.stretchesVoice && !clip.hasTimingFix)
        // Lines: the lines slide by the strength, and no syllable moves by itself.
        clip.tighten = .lines
        #expect(clip.lineStrength == 0.6 && clip.syllableStrength == 0 && !clip.stretchesVoice && clip.hasTimingFix)
        // All: both, and the voice may be stretched because Stretch is on.
        clip.tighten = .all
        #expect(clip.lineStrength == 0.6 && clip.syllableStrength == 0.6 && clip.stretchesVoice && clip.hasTimingFix)
        clip.stretch = false
        #expect(!clip.stretchesVoice)
    }
}
