import CRubberBand
import Foundation
import LockstepCore

/// Stretches and squeezes a piece of voice along a time map without changing its pitch, with Rubber Band.
///
/// This is the only Swift file that knows which library does the stretching. It uses the library's finer
/// engine ("R3") in its offline mode: mono, 48,000 Hz, the whole piece in and the whole result out. The pitch
/// is left alone, and so is the character of the voice (the formant setting stays at the library's default).
///
/// A stretcher holds nothing between calls. Every call makes an engine of its own and frees it, so the same
/// value can be used from several background tasks at once, and the same call always gives the same answer.
///
///     let stretched = RubberBandStretcher().stretch(run, keyFrames: [(source: 4_800, target: 5_280)],
///                                                   outputLength: run.count)
///     // sample 4,800 of `run` is now heard on sample 5,280, and the piece is as long as it was
///
/// How the time map is followed. The engine works in steps: it takes a window of the sound, moves on by about
/// 256 samples (5 ms) and writes the next bit of the result. It can change how much it stretches only between
/// two steps, and it reads its own key-frame map only at the start of each call that hands it sound. So:
///
/// 1. `StretchPlan` works out beforehand where the engine's steps will fall, and moves every key frame to a
///    step. The map the engine is given holds the true map's places at those steps. So a bend that the engine
///    takes a few milliseconds late does not push everything after it off its place.
/// 2. A part that keeps its length is given no stretch at all, and the engine is brought to it on the sample.
///    The engine then gives that part back as the samples that went in.
/// 3. The sound is handed in one step at a time, so the engine looks at its map before every step.
/// 4. The engine is given the piece mirrored before its start and after its end, and what it writes for those
///    parts is thrown away. So its first and last windows are full of sound like the piece itself, the two
///    ends come out about as loud as the rest, and a piece of a few milliseconds is still stretched.
public struct RubberBandStretcher: TimeStretcher {
    /// How far from its target a key frame can land, in seconds: 8.6 ms.
    ///
    /// It is the worst of 2,107 key frames in 600 made-up runs, measured on 13 November 2026 in two ways. A
    /// click at a key frame landed at most 1.9 ms off (99 in 100 within 1.1 ms, usual distance 0.1 ms): that is
    /// how well the map is followed. The start of a voiced syllable was found at most 8.5 ms off (99 in 100
    /// within 5.5 ms, usual distance 1 ms): the engine turns a start that takes 2 ms into a rise of about 20 ms
    /// around the right place, and the measure picks the steepest bit of that rise. The measurement is the
    /// test `keyFramesOfSixHundredMadeUpRunsLandWithinTheTolerance`.
    public static let toleranceSeconds = 0.0086

    public init() {}

    /// The sound of `samples`, made exactly `outputLength` samples long.
    ///
    /// Sample 0 stays at 0 and the end of the sound lands on the end of the result. Each key frame says that the
    /// sample `source` of the sound belongs at the sample `target` of the result, and between two key frames the
    /// stretch is even. A key frame that does not lie after the one before it, in the sound and in the result, is
    /// left out.
    ///
    /// What comes back, as measured:
    /// - With no stretch at all, the samples that went in (largest difference 0.00007).
    /// - A part that keeps its length comes back as the samples that went in, in the place the map gives, also
    ///   after a part that was stretched: from about 25 ms after such a part, and up to about 30 ms before the
    ///   next. In between the engine goes over from the one to the other. A part shorter than that keeps its
    ///   place and its loudness but is not the same samples.
    /// - Where a stretch starts at the first sample, the first 10 ms still lie on the sound that went in
    ///   (likeness 0.92 or more). Where a stretch runs to the last sample, the last 10 ms do not: there it is
    ///   the same sound with its waves shifted, as with any stretcher.
    /// - The loudness of the whole stays within 1.5 percent. The outermost 10 ms of a stretch that starts at the
    ///   first sample or runs to the last come out between 0.78 and 1.18 of the right loudness.
    /// - A piece of a few milliseconds comes out with the right length and nearly as loud: 1 ms made a quarter
    ///   longer is 1.7 dB quieter, 5 ms 0.4 dB. The worst measured was 5 ms made a fifth shorter, 3.9 dB.
    /// - The start of a syllable is softened: see `toleranceSeconds`.
    public func stretch(_ samples: [Float], keyFrames: [(source: Int, target: Int)], outputLength: Int) -> [Float] {
        run(samples, keyFrames: keyFrames, outputLength: outputLength).result
    }

    /// The stretch, with what the engine was told and what it did: the length of each step it took through the
    /// sound, and how much of the result it had written after it.
    func run(
        _ samples: [Float], keyFrames: [(source: Int, target: Int)], outputLength: Int
    ) -> (result: [Float], plan: StretchPlan?, steps: [(length: Int, written: Int)]) {
        guard outputLength > 0 else { return ([], nil, []) }
        guard !samples.isEmpty, Self.engineIsSetUp else { return ([Float](repeating: 0, count: outputLength), nil, []) }

        let plan = StretchPlan(sourceLength: samples.count, keyFrames: keyFrames, targetLength: outputLength)
        let leadIn = StretchPlan.leadIn

        // The sound as the engine gets it: the piece, with itself mirrored before its start and after its end.
        var sound = [Float](repeating: 0, count: plan.studyLength)
        for index in sound.indices { sound[index] = samples[Self.mirrored(index - leadIn, in: samples.count)] }

        guard let engine = rubberband_new(UInt32(StretchPlan.rate), 1, Self.options, plan.timeRatio, 1.0) else {
            return ([Float](repeating: 0, count: outputLength), plan, [])
        }
        defer { rubberband_delete(engine) }
        rubberband_set_max_process_size(engine, UInt32(StretchPlan.window))
        if !plan.from.isEmpty {
            var from = plan.from
            var to = plan.to
            rubberband_set_key_frame_map(engine, UInt32(from.count), &from, &to)
        }

        let wanted = leadIn + outputLength
        var collected = [Float](repeating: 0, count: wanted + StretchPlan.window)
        var have = 0
        var steps: [(length: Int, written: Int)] = []
        sound.withUnsafeBufferPointer { input in
            collected.withUnsafeMutableBufferPointer { output in
                guard let inputBase = input.baseAddress, let outputBase = output.baseAddress else { return }
                func hand(_ from: UnsafePointer<Float>, _ count: Int, last: Bool) {
                    var channel: UnsafePointer<Float>? = from
                    rubberband_process(engine, &channel, UInt32(count), last ? 1 : 0)
                    var available = Int(rubberband_available(engine))
                    while available > 0, have < output.count {
                        var target: UnsafeMutablePointer<Float>? = outputBase + have
                        let got = Int(rubberband_retrieve(engine, &target, UInt32(min(available, output.count - have))))
                        guard got > 0 else { break }
                        have += got
                        available = Int(rubberband_available(engine))
                    }
                }

                // The offline mode takes two passes. The first only tells the engine how long the sound is.
                var whole: UnsafePointer<Float>? = inputBase
                rubberband_study(engine, &whole, UInt32(input.count), 1)

                // The engine asks for exactly as much sound as its next step needs. Handing in just that makes
                // it take one step per call, and it looks at its key-frame map before each. Its very first
                // window is centred on the first sample, with silence of its own before it, so the first call
                // hands in half of what it asks for.
                var handed = 0
                var length = Int(rubberband_get_samples_required(engine)) / 2
                while have < wanted, handed < input.count {
                    let count = min(max(length, 1), input.count - handed)
                    hand(inputBase + handed, count, last: false)
                    handed += count
                    // What it asks for now is how far it just moved on.
                    length = Int(rubberband_get_samples_required(engine))
                    steps.append((length, have))
                }
                // The plan studies more sound than this ever needs. Should it run out all the same, the engine
                // is told that this was all, and gives what it still holds.
                if have < wanted { hand(inputBase, 0, last: true) }
            }
        }
        // The result is cut out of what the engine wrote: by the plan it starts right after the mirrored start.
        // So the length is exact, and nothing is trimmed or padded, unless the engine wrote less than it was
        // asked for, which it never did when this was measured. What is missing would then be silence.
        assert(have >= wanted, "Rubber Band wrote \(wanted - have) samples too few")
        return (Array(collected[leadIn..<wanted]), plan, steps)
    }

    /// The finer engine, not live. Everything else is the library's default.
    private static let options = RubberBandOptions(
        RubberBandOptionProcessOffline.rawValue | RubberBandOptionEngineFiner.rawValue)

    /// The place in a piece of `count` samples that lies at `index` when the piece is mirrored at both ends
    /// again and again: ... 2 1 0 1 2 ... n-2 n-1 n-2 ...
    static func mirrored(_ index: Int, in count: Int) -> Int {
        guard count > 1 else { return 0 }
        let period = 2 * (count - 1)
        let place = ((index % period) + period) % period
        return place < count ? place : period - place
    }

    /// The library sets a few things up for the whole program the first time an engine is made, and does not
    /// guard that against two threads doing it at once. Making one engine here, once, gets it done before any
    /// stretch starts. `VoiceShifter` makes engines of the same library and waits for this too.
    static let engineIsSetUp: Bool = {
        guard let engine = rubberband_new(UInt32(StretchPlan.rate), 1, options, 1.0, 1.0) else { return false }
        rubberband_delete(engine)
        return true
    }()
}

/// What the engine is told for one stretch: its key-frame map and the two lengths.
///
/// Everything here is counted in the engine's own samples: the sound it is given starts `leadIn` samples
/// before the piece, and so does what it writes.
///
/// The plan is made by doing the engine's own sums beforehand: how long its steps are at a stretch
/// (`step(ratio:)`), and where it counts its result to be after each step (`StepCount`). Both are the engine's
/// rules as they are in Rubber Band 4.0.0. If they were wrong, a stretch would still come out, with its key
/// frames a few milliseconds less exact: the tests compare both with what the engine really does.
struct StretchPlan {
    static let rate = 48_000
    /// The engine's longest window at 48,000 Hz, in samples. Its first window is centred on the first sample.
    static let window = 4096
    /// How much mirrored sound the engine gets before the piece: 16 of its steps at no stretch, so that a step
    /// falls exactly on the first sample of the piece and the stretch can start there.
    static let leadIn = 4096

    /// The key-frame map for the engine: places in the sound, and where each belongs in the result.
    let from: [UInt32]
    let to: [UInt32]
    /// How much sound the engine is told it will get, and how long it is told the result will be.
    let studyLength: Int
    let targetLength: Int
    /// The stretch the engine is made with. With `studyLength` it gives `targetLength`.
    let timeRatio: Double
    /// Where the engine changes its stretch, with the stretch and the length of its steps from there on. The
    /// first is its start.
    let changes: [(place: Int, ratio: Double, step: Int)]

    init(sourceLength: Int, keyFrames: [(source: Int, target: Int)], targetLength: Int) {
        // The true map, with the start of the mirrored sound first and the end of the piece last.
        let leadIn = Self.leadIn
        var points: [(source: Int, target: Int)] = [(0, 0), (leadIn, leadIn)]
        for frame in keyFrames.sorted(by: { $0.source < $1.source }) {
            guard let last = points.last, frame.source + leadIn > last.source, frame.target + leadIn > last.target,
                frame.source < sourceLength, frame.target < targetLength
            else { continue }
            points.append((frame.source + leadIn, frame.target + leadIn))
        }
        points.append((sourceLength + leadIn, targetLength + leadIn))
        let end = points[points.count - 1]

        // The engine's count up to its last change, where that change is, where its result is taken to be
        // there, and the last entry of the map it is given.
        var count = StepCount()
        var changedAt = 0
        var position = 0
        var given = (source: 0, target: 0)
        var from: [UInt32] = []
        var to: [UInt32] = []
        var changes: [(place: Int, ratio: Double, step: Int)] = []

        // One more entry for the engine's map: from its last change it takes steps of one length at one
        // stretch, and changes again at the first of them at or after `place`.
        func change(at place: Int, target: Int) {
            let ratio = Double(target - given.target) / Double(place - given.source)
            let step = Self.step(ratio: ratio)
            from.append(UInt32(place))
            to.append(UInt32(target))
            changes.append((changedAt, ratio, step))
            while count.taken < place { count.take(step, ratio: ratio) }
            given = (place, target)
            changedAt = count.taken
            position = count.written
        }

        // How far the result is from its place, in samples, once the sound has kept its length for a while
        // from where `count` stands. `offset` is how much later than in the sound that part lies in the result.
        func error(after count: StepCount, offset: Int) -> Int {
            var settled = count
            for _ in 0..<8 { settled.take(256, ratio: 1) }
            return settled.written - settled.taken - offset
        }

        // A bend after which the sound keeps its length. That part can come back as the very samples that went
        // in, if the result is in exactly the right place when it starts. The engine counts in whole samples
        // and lets an error of a few samples stand, so an entry on the true map is not enough. Instead the
        // engine is taken along the true map to a step shortly before the bend, and from there with one step
        // of its own to the place: a step that takes a whole number of samples and gives a whole number, picked
        // so that the two differ by exactly what is still missing. The engine does such sums without rounding.
        // False when no such step is found: the bend is then followed like any other.
        func land(on bend: (source: Int, target: Int), after part: Part) -> Bool {
            let offset = bend.target - bend.source
            let usual = Self.step(ratio: Self.ratio(part.0, part.1))
            var best: (distance: Int, approach: (place: Int, target: Int)?, place: Int, target: Int)?
            // The stretch on the way there is not quite that of the true map when the engine's last change
            // lies a little off it, so steps a few samples longer and shorter are tried as well.
            for step in max(1, usual - 6)...(usual + 6) {
                let nearest = Int((Double(bend.source - changedAt) / Double(step)).rounded())
                for steps in (nearest - 2)...(nearest + 1) where steps >= 0 {
                    var trial = count
                    var last = given
                    var approach: (place: Int, target: Int)?
                    if steps > 0 {
                        let place = changedAt + steps * step
                        let wanted = Int(Self.value(at: place, on: points).rounded())
                        let slope = Double(wanted - position) / Double(place - changedAt)
                        let target = max(given.target + 1, given.target + Int((slope * Double(place - given.source)).rounded()))
                        let ratio = Double(target - given.target) / Double(place - given.source)
                        guard Self.step(ratio: ratio) == step else { continue }
                        for _ in 0..<steps { trial.take(step, ratio: ratio) }
                        last = (place, target)
                        approach = (place, target)
                    } else if changedAt != given.source {
                        continue
                    }
                    // The step must give `missing` samples more than it takes. Where the engine is off its own
                    // count by a few samples it gives one more or one less than it is asked for, so asking
                    // for one less or one more is tried too.
                    let missing = offset - (trial.written - trial.taken)
                    for length in max(1, step - 64)...(step + 64) {
                        for asked in [length + missing, length + missing - 1, length + missing + 1] where asked > 0 {
                            let ratio = Double(asked) / Double(length)
                            guard Self.step(ratio: ratio) == length else { continue }
                            var landed = trial
                            landed.take(length, ratio: ratio)
                            guard landed.written - landed.taken == offset, error(after: landed, offset: offset) == 0
                            else { continue }
                            let distance = abs(landed.taken - bend.source)
                            if distance < (best?.distance ?? Int.max) {
                                best = (distance, approach, landed.taken, last.target + asked)
                            }
                        }
                    }
                }
            }
            guard let best else { return false }
            if let approach = best.approach { change(at: approach.place, target: approach.target) }
            change(at: best.place, target: best.target)
            return true
        }

        for index in 1..<(points.count - 1) {
            let bend = points[index]
            let before = (points[index - 1], bend)
            let after = (bend, points[index + 1])
            // No bend here if the stretch is the same on both sides, and none that can be followed if the
            // engine's last change already lies past it.
            guard !Self.isSameStretch(before, after), bend.source > changedAt else { continue }

            // The engine can only change between two steps. Which step takes this bend: where the sound keeps
            // its length on one side, a step on that side, so that part gets no stretch at all and comes back
            // as the samples that went in. Else the nearest step.
            let side: Side = Self.keepsLength(before) ? .before : Self.keepsLength(after) ? .after : .nearest
            if side == .after, land(on: bend, after: before) { continue }

            var step = Self.step(ratio: Self.ratio(before.0, before.1))
            var tried: Set<Int> = []
            while true {
                tried.insert(step)
                let distance = Double(bend.source - changedAt) / Double(step)
                let steps: Int
                switch side {
                case .before: steps = Int(distance.rounded(.down))
                case .after: steps = max(1, Int(distance.rounded(.up)))
                case .nearest: steps = max(1, Int(distance.rounded()))
                }
                // Less than one step of the part that keeps its length is left: the engine changes where it is.
                guard steps > 0 else { break }
                let place = changedAt + steps * step
                // The true map's place there, and the map entry that takes the engine to it from where it is.
                // Up to a bend after a part that keeps its length there is no stretch at all, and that comes
                // first: with any stretch, however small, the part would not come back as the samples it was.
                let wanted = Int(Self.value(at: place, on: points).rounded())
                let slope = side == .before ? 1 : Double(wanted - position) / Double(place - changedAt)
                let target = max(given.target + 1, given.target + Int((slope * Double(place - given.source)).rounded()))
                // The engine picks the length of its steps from the stretch. If that is not the length this was
                // worked out with, its steps do not fall on `place`, and it is worked out again with the
                // engine's length. Should that go in circles, the entry is given as it is: the engine then
                // changes at its first step after `place`, and the next entry starts from where that leaves it.
                let engineStep = Self.step(ratio: Double(target - given.target) / Double(place - given.source))
                if engineStep == step || tried.contains(engineStep) {
                    change(at: place, target: target)
                    break
                }
                step = engineStep
            }
        }

        // After its last change the engine stretches evenly up to the two lengths it was told. They are set so
        // that the end of the piece lands on the end of the result. More sound is studied than the piece holds:
        // the engine needs sound after the end to finish the last windows.
        // A last part that keeps its length gets no stretch at all, and a short one its own stretch.
        var slope = Self.ratio(points[points.count - 2], end)
        if end.source - changedAt >= 2 * Self.window, !Self.keepsLength((points[points.count - 2], end)) {
            slope = Double(end.target - position) / Double(end.source - changedAt)
        }
        let study = end.source + Int((Double(Self.window / 2) / slope).rounded(.up)) + 2 * Self.window
        let target = given.target + Int((slope * Double(study - given.source)).rounded())
        studyLength = study
        self.targetLength = target
        // The engine works its target length out from the stretch it is made with, so that must give it back.
        var ratio = Double(target) / Double(study)
        if Int((Double(study) * ratio).rounded()) < target { ratio = ratio.nextUp }
        if Int((Double(study) * ratio).rounded()) > target { ratio = ratio.nextDown }
        timeRatio = ratio
        let last = from.isEmpty ? ratio : Double(target - given.target) / Double(study - given.source)
        changes.append((changedAt, last, Self.step(ratio: last)))
        self.from = from
        self.to = to
        self.changes = changes
    }

    private enum Side { case before, after, nearest }

    /// The length of the engine's steps through the sound at a stretch, in samples. This is the engine's own
    /// rule (`R3Stretcher::calculateHop` in Rubber Band 4.0.0), which aims at 256 samples of the result a step.
    static func step(ratio: Double) -> Int {
        var out = 256.0
        if ratio > 1.5 {
            out = pow(2.0, 8.0 + 2.0 * log10(ratio - 0.5))
        } else if ratio < 1.0 {
            out = pow(2.0, 8.0 + 2.0 * log10(ratio))
        }
        out = min(max(out, 128), 512)
        return Int(min(max(out / ratio, 1), 2048).rounded(.down))
    }

    /// The place in the result that belongs to a place in the sound, by the true map. After the end of the
    /// piece the map goes on in a straight line.
    private static func value(at source: Int, on points: [(source: Int, target: Int)]) -> Double {
        var index = 0
        while index < points.count - 2, points[index + 1].source <= source { index += 1 }
        let from = points[index]
        let to = points[index + 1]
        return Double(from.target) + Double(source - from.source) * ratio(from, to)
    }

    private static func ratio(_ from: (source: Int, target: Int), _ to: (source: Int, target: Int)) -> Double {
        Double(to.target - from.target) / Double(to.source - from.source)
    }

    private typealias Part = ((source: Int, target: Int), (source: Int, target: Int))

    private static func keepsLength(_ part: Part) -> Bool {
        part.1.target - part.0.target == part.1.source - part.0.source
    }

    private static func isSameStretch(_ first: Part, _ second: Part) -> Bool {
        (first.1.target - first.0.target) * (second.1.source - second.0.source)
            == (second.1.target - second.0.target) * (first.1.source - first.0.source)
    }
}

/// The engine's own count of how much sound it has taken and how much of the result it has written.
///
/// The engine writes a whole number of samples at every step, and steers that number so that the result stays
/// near where the stretch says it should be: it makes up a quarter of what it is off by at each step, which
/// leaves an error of up to two samples standing. This is `StretchCalculator::calculateSingle` in Rubber Band
/// 4.0.0, with the same rounding.
struct StepCount {
    private(set) var taken = 0
    private(set) var written = 0
    /// Where the count stood when the stretch last changed.
    private var mark = (taken: 0, written: 0)
    private var lastRatio = 1.0
    private var isFirst = true

    /// One step of the engine: `length` samples of the sound at a stretch of `ratio`.
    mutating func take(_ length: Int, ratio: Double) {
        if !isFirst, ratio != lastRatio { mark = (taken, expected(ratio: lastRatio)) }
        isFirst = false
        lastRatio = ratio
        let even = (Double(length) * ratio).rounded(.toNearestOrEven)
        let off = written - expected(ratio: ratio)
        let recovery: Double
        if abs(off) > 1000 {
            recovery = Double(off) / ((Double(StretchPlan.rate) / 10) / Double(length))
        } else if abs(off) > 100 {
            recovery = Double(off) / ((Double(StretchPlan.rate) / 20) / Double(length))
        } else {
            recovery = Double(off) / 4
        }
        let lowest = (Double(length) * ratio * 0.3).rounded(.toNearestOrEven)
        let highest = (Double(length) * ratio * 2).rounded(.toNearestOrEven)
        let out = max(0, min(max((even - recovery).rounded(.toNearestOrEven), lowest), highest))
        taken += length
        written += Int(out)
    }

    /// Where the result should be by now, at a stretch of `ratio` since the last change.
    private func expected(ratio: Double) -> Int {
        Int((Double(mark.written) + Double(taken - mark.taken) * ratio).rounded())
    }
}
