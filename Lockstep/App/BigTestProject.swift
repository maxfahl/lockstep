import Foundation
import LockstepCore

/// A made-up project about as big as Max's own, for measuring how fast edits are: twenty tracks, four
/// hundred lines, and about two hundred and fifty more takes waiting behind them. `-bigProject` builds it
/// (`ClipEditingModel+BigProject.swift`). It is in every build, release builds included, because both are
/// measured. Nothing in the window makes it.
///
/// On 15 November 2026 Max's Deletes took 205 to 516 ms until the window was drawn, and the same Delete in a
/// scratch run with two clips took 26 to 42 ms. Nobody knows how big his project is, because agents may not
/// read it, so this size was chosen for him: large enough that what grows with the number of clips,
/// recordings and tightened sounds is felt.
///
/// What it holds, the same in every run (a seeded generator, and ids made from it):
/// - 20 tracks, 20 lines on each, spread over the song with gaps between them. Each track starts a little
///   later than the one above it, so the clips do not stand in columns.
/// - A third of the lines have 2 to 4 takes, of which the last is the one shown.
/// - One recording for every take, as real takes have, 1.5 to 4 seconds long. There are twelve different
///   made-up voices, and the recordings share their twelve files.
/// - Words on every clip. Half the lines are on Lines, a quarter on All at 80 % with Stretch on, the rest
///   Off, and the takes of a line have the same choice, as real takes do.
/// - A few clips cut in two and joined again, a few with a volume of their own, and two muted tracks.
///
///     let voices = BigTestProject.voices()
///     let plan = BigTestProject.plan(for: store.project, voiceLengths: voices.map(\.count))
///     // write the voices, load the sound of `plan.recordings`, then:
///     store.edit("Add Big Test Project") { BigTestProject.add(plan, to: &$0, peaks: peaks) }
enum BigTestProject {
    static let trackCount = 20
    static let linesPerTrack = 20
    static let voiceCount = 12

    /// The file one of the made-up voices is kept in, inside the project. Many recordings name the same file.
    static func voiceFile(_ voice: Int) -> String {
        "takes/big-test-voice-\(voice + 1).wav"
    }

    // MARK: The generator

    /// Numbers that look random and are the same in every run (SplitMix64).
    struct Seeded: RandomNumberGenerator {
        private var state: UInt64

        init(seed: UInt64) {
            state = seed
        }

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var mixed = state
            mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
            mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
            return mixed ^ (mixed >> 31)
        }

        /// An id made from the generator, so the project has the same ids in every run.
        mutating func id() -> UUID {
            var bytes: uuid_t = UUID().uuid
            withUnsafeMutableBytes(of: &bytes) { raw in
                raw.storeBytes(of: next(), toByteOffset: 0, as: UInt64.self)
                raw.storeBytes(of: next(), toByteOffset: 8, as: UInt64.self)
            }
            return UUID(uuid: bytes)
        }
    }

    // MARK: The voices

    /// The twelve made-up voices: mono at 48,000 Hz, from 1.5 to 4 seconds long.
    static func voices() -> [[Float]] {
        var generator = Seeded(seed: 0x10C5_7E90)
        return (0..<voiceCount).map { voice in
            // Evenly from the shortest to the longest, so the clips differ in length.
            let seconds = 1.5 + 2.5 * Double(voice) / Double(voiceCount - 1)
            return Self.voice(
                seconds: seconds,
                syllablesPerSecond: 4 + Double(voice % 3),
                pitch: 110 + 12 * Double(voice),
                generator: &generator
            )
        }
    }

    /// One made-up voice: bursts with a sharp start and a short gap after each, 4 to 6 a second, which is
    /// what the syllable search looks for. A voice of 2.5 seconds or more has a pause of 0.45 seconds in its
    /// middle, so it is two lines.
    ///
    /// Each burst is a low tone with its overtones, which lie in the band the voice's loudness is measured
    /// in (300 to 3,000 Hz). Under it all is a faint hiss, as a room has.
    private static func voice(
        seconds: Double,
        syllablesPerSecond: Double,
        pitch: Double,
        generator: inout Seeded
    ) -> [Float] {
        let rate = Lockstep.sampleRate
        let count = Int(seconds * rate)
        var samples = [Float](repeating: 0, count: count)
        let period = rate / syllablesPerSecond
        let pause = seconds >= 2.5 ? (seconds / 2 - 0.225)...(seconds / 2 + 0.225) : nil
        // A tenth of a second of the room alone at both ends, as a take has.
        var start = 0.1 * rate
        while start + period * 0.7 < Double(count) - 0.1 * rate {
            let middle = (start + period / 2) / rate
            if let pause, pause.contains(middle) {
                start += period
                continue
            }
            let voiced = Int(period * 0.7)
            let attack = Int(0.004 * rate)
            let loudness = 0.16 + 0.08 * Double(generator.next() % 100) / 100
            let tone = pitch * (0.94 + 0.12 * Double(generator.next() % 100) / 100)
            let first = Int(start)
            for offset in 0..<voiced where first + offset < count {
                let time = Double(offset) / rate
                let shape = offset < attack
                    ? Double(offset) / Double(attack)
                    : exp(-3.5 * Double(offset - attack) / Double(voiced))
                var wave = 0.0
                for overtone in 1...8 {
                    wave += sin(2 * .pi * tone * Double(overtone) * time) / Double(overtone)
                }
                samples[first + offset] = Float(loudness * shape * wave / 2)
            }
            start += period
        }
        for index in samples.indices {
            samples[index] += Float(Double(generator.next() % 2_001) / 1_000 - 1) * 0.000_3
        }
        return samples
    }

    // MARK: The plan

    /// One take of the plan: its recording, the clip that plays it and the track it goes on.
    struct Take {
        var recording: Recording
        /// Which of the made-up voices the recording is, counted from 0.
        var voice: Int
        var clip: Clip
        var track: Int
    }

    /// Everything that is added to a project, worked out before any of it is.
    struct Plan {
        /// The takes, in the order they are added: track by track, line by line, the take shown last.
        var takes: [Take]
        /// The clips that are cut in two and joined again, each with its track, counted from 0 at the top.
        var cutAndJoined: [(clip: UUID, track: Int)]
        /// The ids the tracks that are added get, from the top.
        var trackIDs: [UUID]
        /// The tracks that are muted, counted from 0 at the top.
        var mutedTracks: [Int]

        var recordings: [Recording] { takes.map(\.recording) }
    }

    private static let words = [
        "every", "beat", "has", "its", "place", "I", "stay", "here", "when", "the", "night", "falls",
        "words", "that", "land", "right", "on", "time", "nobody", "waits", "lights", "come", "up", "again",
    ]

    /// Works out the takes of the big project for the song of a project.
    ///
    /// - Parameter voiceLengths: how many samples each of the made-up voices is.
    static func plan(for project: Project, voiceLengths: [Int]) -> Plan {
        var generator = Seeded(seed: 0xB16_7E57)
        // The room each line has on its track, and the longest a clip may be in it. In a short song the
        // clips are cut shorter to fit.
        let room = max(project.songLengthSamples / linesPerTrack, 1)
        let longest = max(min(room * 4 / 5, voiceLengths.max() ?? 1), 1)
        var takes: [Take] = []
        var cutAndJoined: [(clip: UUID, track: Int)] = []
        for track in 0..<trackCount {
            let stagger = (room - longest) * track / trackCount
            for line in 0..<linesPerTrack {
                let place = line * room + stagger
                let lineID = generator.id()
                let takeCount = generator.next() % 3 == 0 ? 2 + Int(generator.next() % 3) : 1
                let choice = generator.next() % 4
                let text = (0..<(4 + Int(generator.next() % 5)))
                    .map { _ in words[Int(generator.next() % UInt64(words.count))] }
                    .joined(separator: " ")
                // A few clips are a little quieter or louder than they were recorded.
                let gainDb: Double = generator.next() % 40 == 0 ? [-4, -2, 2][Int(generator.next() % 3)] : 0
                for take in 0..<takeCount {
                    let voice = Int(generator.next() % UInt64(voiceLengths.count))
                    let recording = Recording(
                        id: generator.id(),
                        file: voiceFile(voice),
                        lengthSamples: voiceLengths[voice],
                        rawStart: Double(place) / Lockstep.sampleRate
                    )
                    let clip = Clip(
                        id: generator.id(),
                        text: text,
                        segments: [Segment(
                            recordingID: recording.id, inSample: 0, outSample: min(voiceLengths[voice], longest)
                        )],
                        gainDb: gainDb,
                        tighten: choice < 2 ? .lines : choice == 2 ? .all : .off,
                        strength: choice == 2 ? 0.8 : Clip.startingStrength,
                        stretch: choice == 2,
                        isActiveTake: take == takeCount - 1,
                        line: lineID,
                        recordPlace: recording.rawStart
                    )
                    takes.append(Take(recording: recording, voice: voice, clip: clip, track: track))
                }
                // Every fiftieth line that has one take is cut in two and joined again.
                if takeCount == 1, (track * linesPerTrack + line) % 50 == 7, let clip = takes.last?.clip {
                    cutAndJoined.append((clip.id, track))
                }
            }
        }
        return Plan(
            takes: takes,
            cutAndJoined: cutAndJoined,
            trackIDs: (0..<trackCount).map { _ in generator.id() },
            mutedTracks: [7, 15]
        )
    }

    /// Adds the plan to a project: tracks until there are twenty, the recordings and their clips, the cuts
    /// and joins, and the two muted tracks. The sound of the recordings must be loaded already.
    ///
    /// - Parameter peaks: the highest sample of a stretch of a recording, which a cut and a join ask for.
    static func add(_ plan: Plan, to project: inout Project, peaks: RecordingPeak) {
        var trackIDs = plan.trackIDs[...]
        while project.tracks.count < trackCount, let id = trackIDs.popFirst() {
            project.tracks.append(Track(id: id, name: project.nextTrackName()))
        }
        project.recordings.append(contentsOf: plan.recordings)
        for take in plan.takes where project.tracks.indices.contains(take.track) {
            project.tracks[take.track].clips.append(take.clip)
        }
        // A tenth of a second is cut out of the middle of the clip, and what is left is joined: one clip of
        // two pieces with a gap between them. A clip that is only split and joined is one piece again.
        for cut in plan.cutAndJoined where project.tracks.indices.contains(cut.track) {
            guard let clip = project.clip(cut.clip), let start = project.start(of: clip), let end = project.end(of: clip)
            else { continue }
            let middle = (start + end) / 2
            let gap = (middle - 0.05)..<(middle + 0.05)
            guard let pieces = project.cut(range: gap, onTrack: project.tracks[cut.track].id, peaks: peaks, voices: .none),
                  let joined = project.joinClips(Set(pieces), peaks: peaks, voices: .none),
                  let index = project.tracks[cut.track].clips.firstIndex(where: { $0.id == joined })
            else { continue }
            // The joined clip has the words the uncut clip had.
            project.tracks[cut.track].clips[index].text = clip.text
        }
        for track in plan.mutedTracks where project.tracks.indices.contains(track) {
            project.tracks[track].muted = true
        }
    }
}
