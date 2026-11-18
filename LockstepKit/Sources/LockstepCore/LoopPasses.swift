import Foundation

// A loop recording is one long capture: the microphone stays open while the loop goes round. When it is
// stopped, the capture is divided into passes, one for each time round, and each pass becomes a take of the
// same line. Everything here is plain arithmetic on sample positions, so it can be tested with made-up numbers.
//
//     // `capture` is the recording as it lies in the project: moved back by the delay of its devices.
//     let split = LoopPasses.split(capture, voicedStretches: stretches, loop: region, grid: project.grid,
//                                  clickLeak: leak)
//     for pass in split.passes {
//         pass.samples                // the part of the capture that becomes this pass's own recording file
//         pass.clip                   // the part of it that becomes the clip, in samples of the capture
//         LoopPasses.rawStart(of: pass, loopStart: region.start, delay: capture.delay)
//     }
//     split.active                    // which of them is the active take
//
// Where one pass ends and the next begins. By the plain rule, pass `k` is the capture from
// `origin + k * loopLength` to the next such sample (`ranges`), where `origin` is the sample at which what
// was performed on the loop's start arrives in the capture. A word said just before the loop's start
// belongs to the pass that follows it, as a word said just before the place belongs to any take. So the
// cut between two passes is moved back from the loop's start into the pause before such a word (`cut`).
// The first pass is cut by the very rule of every take (`RecordingPlacement.clipSamples`), with the count-in
// and its clicks. Every later pass is its voice, with the same 50 ms before it and 150 ms after it.

/// One time round of a loop recording.
public struct LoopPass: Sendable, Equatable {
    /// Which time round this was, counted from 0.
    public var index: Int
    /// The sample of the capture at which what was performed on the loop's start arrives, for this pass.
    public var boundary: Int
    /// The part of the capture that belongs to this pass and becomes its own recording, in samples of the
    /// capture. The passes share the capture between them without a gap and without an overlap.
    public var samples: Range<Int>
    /// The part that becomes the pass's clip, in samples of the capture. It lies inside `samples`.
    public var clip: Range<Int>
    /// True when the loop came round after this pass. False for the pass that was stopped on its way.
    public var isComplete: Bool

    public init(index: Int, boundary: Int, samples: Range<Int>, clip: Range<Int>, isComplete: Bool) {
        self.index = index
        self.boundary = boundary
        self.samples = samples
        self.clip = clip
        self.isComplete = isComplete
    }
}

/// A loop recording divided into the passes that are kept.
public struct LoopSplit: Sendable, Equatable {
    /// The passes that become takes, in the order they were recorded.
    public var passes: [LoopPass]
    /// Which of `passes` is the active take: the last one that ran its full length. The general rule for
    /// takes would pick the pass recorded last, and that is the one that was stopped on its way. Nil when
    /// there are no passes.
    public var active: Int?

    public init(passes: [LoopPass] = [], active: Int? = nil) {
        self.passes = passes
        self.active = active
    }
}

public enum LoopPasses {
    // MARK: The plain rule

    /// The capture divided at every loop boundary: pass `k` covers the samples from
    /// `originSample + k * loopLength` to the next boundary, and the last one ends where the capture does.
    /// What lies before `originSample`, the count-in, is in no pass. Empty when the capture ends before the
    /// loop's start was reached.
    ///
    /// - Parameters:
    ///   - captureLength: the length of the capture in samples.
    ///   - originSample: the sample of the capture at which what was performed on the loop's start arrives:
    ///     the loop's start by the arithmetic that places every recording, the measured delay included
    ///     (`originSample(of:loopStart:)`). Without the delay, the end of each pass would land in the next take.
    ///   - loopLength: the length of the loop in samples.
    public static func ranges(captureLength: Int, originSample: Int, loopLength: Int) -> [Range<Int>] {
        guard loopLength > 0, originSample < captureLength else { return [] }
        var ranges: [Range<Int>] = []
        var first = originSample
        while first < captureLength {
            ranges.append(first..<min(first + loopLength, captureLength))
            first += loopLength
        }
        return ranges
    }

    /// The sample of a capture at which what was performed on the loop's start arrives, the first time round.
    ///
    /// - Parameter capture: the capture as it lies in the project: with the delay measured for its devices
    ///   (`Recording.movedBack`). Sound arrives in a recording later than it was played, by that delay.
    public static func originSample(of capture: Recording, loopStart: Double) -> Int {
        Int(((loopStart - capture.songTime(ofSample: 0)) * Lockstep.sampleRate).rounded())
    }

    /// The `rawStart` of the recording a pass becomes, so that its first loop sample lies exactly on the
    /// loop's start once the delay is taken off: the one position rule then puts every pass at the same
    /// place, whichever time round it was.
    ///
    /// - Parameter delay: the delay the pass's recording gets, in seconds: that of the capture.
    public static func rawStart(of pass: LoopPass, loopStart: Double, delay: Double) -> Double {
        loopStart + delay - Double(pass.boundary - pass.samples.lowerBound) / Lockstep.sampleRate
    }

    // MARK: Where one pass ends and the next begins

    /// The sample of the capture where the pass that ends at `boundary` is cut off and the next one begins.
    ///
    /// - A word that leads into the loop's start belongs to the pass that follows. Walking back from the
    ///   boundary over the stretches of voice, each one leads in as long as the pause after it is at most
    ///   `TakeTrim.longestPauseSeconds`. Where the walk meets a longer pause inside `window`, the cut is in
    ///   that pause.
    /// - Where the voice goes on all the way back through `window` without such a pause, the line before is
    ///   still going. The cut is then in the longest pause whose end lies within one beat of the boundary,
    ///   and at the boundary itself when there is none.
    /// - With no voice just before the boundary, the cut is at the boundary, or up to 50 ms before it when
    ///   the voice starts right on it.
    ///
    /// The cut is put 50 ms before the voice that follows it (`TakeTrim.marginBeforeSeconds`), or in the
    /// middle of the pause when the pause is shorter than twice that. It is never after the boundary and
    /// never further back than `window`.
    ///
    /// - Parameters:
    ///   - voice: the stretches of voice in the capture, in order.
    ///   - window: how far back from the boundary a pass may begin, in samples.
    ///   - beat: the length of one beat, in samples.
    public static func cut(before boundary: Int, voice: [Range<Int>], window: Int, beat: Int) -> Int {
        let rate = Lockstep.sampleRate
        func samples(_ seconds: Double) -> Int { Int((seconds * rate).rounded()) }
        let earliest = boundary - max(window, 0)
        // Sound shorter than a word is a pop or a tick, as before the place of any take.
        let words = voice.filter { $0.count >= samples(TakeTrim.shortestVoiceSeconds) }
        // The cut for a pause that ends where voice begins at `voiceStart`, after silence from `silenceStart`.
        func cut(inPauseFrom silenceStart: Int, to voiceStart: Int) -> Int {
            let middle = silenceStart + (voiceStart - silenceStart) / 2
            return min(max(voiceStart - samples(TakeTrim.marginBeforeSeconds), middle, earliest), boundary)
        }

        // The voice that follows the boundary, for a pass that starts right on it. With none, any place well
        // after the boundary does.
        let nextVoice = words.first { $0.upperBound > boundary }?.lowerBound ?? boundary + samples(1)
        // A word that is being said on the boundary has been walked over already.
        var front = min(nextVoice, boundary)
        // Where the voice begins again after a pause that ends at `front`.
        func voiceStart(after front: Int) -> Int { front == boundary ? nextVoice : front }
        // The pauses the walk passes over: each from the end of a word to the start of what follows it.
        var pauses: [(from: Int, to: Int)] = []
        if front > earliest {
            for word in words.reversed() where word.lowerBound < front {
                let pause = front - word.upperBound
                if word.upperBound <= earliest || pause > samples(TakeTrim.longestPauseSeconds) {
                    // A real pause: what was walked over leads into the loop's start.
                    return cut(inPauseFrom: max(word.upperBound, earliest), to: voiceStart(after: front))
                }
                if pause > 0 { pauses.append((word.upperBound, voiceStart(after: front))) }
                front = word.lowerBound
                if front <= earliest { break }
            }
            if front > earliest {
                // The walk ran out of words: nothing was said before what leads in.
                return cut(inPauseFrom: earliest, to: voiceStart(after: front))
            }
        }
        // The voice never paused for long. Only a pause close to the boundary divides the passes.
        let close = pauses.filter { $0.to >= boundary - beat }
        guard let longest = close.max(by: { $0.to - $0.from < $1.to - $1.from }) else { return boundary }
        return cut(inPauseFrom: longest.from, to: longest.to)
    }

    // MARK: All of it

    /// Divides a loop recording into the passes that become takes.
    ///
    /// - The first pass is cut like every take: its clip starts at the loop's start, or earlier where a word
    ///   during the count-in leads into it, and the count-in's clicks are not taken for words.
    /// - Every later pass is the voice in its share of the capture, with 50 ms before and 150 ms after.
    /// - A pass with no voice in it is left out. If no pass has any, every pass that ran its full length is
    ///   kept whole, as a take without a voice is: the voice may only have been too quiet to find.
    /// - The last pass, stopped on its way, is kept if it has voice in it and is at least one beat long.
    /// - The active take is the last kept pass that ran its full length.
    ///
    /// A capture in which the loop never came round is not a loop recording but a take like any other, and
    /// gives no passes: cut it with `RecordingPlacement.clipSamples`.
    ///
    /// - Parameters:
    ///   - capture: the whole capture as it lies in the project, moved back by the delay of its devices.
    ///   - stretches: where the voice is in the capture, as `VoiceEnvelope.voicedStretches()` found it.
    ///   - loop: the loop the recording went round in.
    ///   - grid: the song's beats, for the length of a bar and of a beat. Nil when they are not known.
    ///   - clickLeak: the clicks of the count-in. Left out, no sound is taken for a click.
    public static func split(
        _ capture: Recording,
        voicedStretches stretches: [Range<Int>],
        loop: LoopRegion,
        grid: Grid?,
        clickLeak: ClickLeak = .none
    ) -> LoopSplit {
        let rate = Lockstep.sampleRate
        let length = capture.lengthSamples
        let origin = originSample(of: capture, loopStart: loop.start)
        let plain = ranges(captureLength: length, originSample: origin, loopLength: loop.lengthSamples)
        // The loop came round at least once: the first pass ran its full length.
        guard origin >= 0, let firstPass = plain.first, firstPass.count == loop.lengthSamples else {
            return LoopSplit()
        }
        let bar = Int((RecordingPlacement.barSeconds(before: loop.start, grid: grid) * rate).rounded())
        let beat = max(bar / Grid.beatsPerBar, 1)
        // A pass may begin a bar before the loop's start at most, and never in the first half of the pass before.
        let window = min(Int(Double(bar) * TakeTrim.longestLeadInBars), loop.lengthSamples / 2)

        // Where each pass begins: the first with the capture, the others at their cuts.
        var cuts = [0]
        for boundary in plain.dropFirst().map(\.lowerBound) {
            cuts.append(cut(before: boundary, voice: stretches, window: window, beat: beat))
        }
        cuts.append(length)

        var passes: [LoopPass] = []
        var voiced: [Bool] = []
        for (index, range) in plain.enumerated() {
            let share = cuts[index]..<cuts[index + 1]
            // The voice of this pass: what sounds in its share, kept inside the share.
            let voice = stretches.map { $0.clamped(to: share) }.filter { !$0.isEmpty }
            var clip: Range<Int>?
            var hasVoice = !voice.isEmpty
            if index == 0 {
                // The rule of every take, on the part of the capture that is the first pass's.
                var first = capture
                first.lengthSamples = share.upperBound
                clip = RecordingPlacement.clipSamples(
                    of: first, voicedStretches: voice, origin: loop.start, grid: grid, clickLeak: clickLeak
                )
                // Before the loop's start only a word that leads into it counts, and on the start itself the
                // click to start on is heard leaking in. So the pass has a voice when the clip begins before
                // the start, or something sounds after that click has rung out.
                let clickRings = Int(
                    ((clickLeak.soundSeconds + TakeTrim.clickLeakLateSeconds + TakeTrim.clickLeakTailSeconds) * rate).rounded()
                )
                hasVoice = voice.contains { $0.upperBound > origin + clickRings } || (clip?.lowerBound ?? origin) < origin
            } else if let firstVoice = voice.first, let lastVoice = voice.last {
                let start = max(firstVoice.lowerBound - Int(TakeTrim.marginBeforeSeconds * rate), share.lowerBound)
                let end = min(lastVoice.upperBound + Int(TakeTrim.marginAfterSeconds * rate), share.upperBound)
                clip = start..<end
            } else {
                // Without a voice the pass is its plain stretch, like a take in which nothing counts as sound.
                clip = max(range.lowerBound, share.lowerBound)..<share.upperBound
            }
            guard let clip, !clip.isEmpty else { continue }
            passes.append(LoopPass(
                index: index,
                boundary: range.lowerBound,
                samples: share,
                clip: clip,
                isComplete: range.count == loop.lengthSamples
            ))
            voiced.append(hasVoice)
        }

        // The pass that was stopped on its way stays only with a voice in it and a beat of length.
        // A pass that ran its full length stays with a voice in it, or when no pass has one.
        let anyVoice = voiced.contains(true)
        var kept: [LoopPass] = []
        for (pass, hasVoice) in zip(passes, voiced) {
            if pass.isComplete {
                if hasVoice || !anyVoice { kept.append(pass) }
            } else if hasVoice, length - pass.boundary >= beat {
                kept.append(pass)
            }
        }
        let active = kept.lastIndex(where: \.isComplete) ?? (kept.isEmpty ? nil : kept.count - 1)
        return LoopSplit(passes: kept, active: active)
    }
}
