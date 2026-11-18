import Foundation

/// Lays out the click of a whole song as one row of samples, each click
/// starting on the exact sample of its beat.
///
///     let click = ClickRenderer.render(
///         grid: project.grid,
///         settings: project.click,
///         lengthSamples: project.songLengthSamples
///     )
///
/// The result is mono at 48,000 Hz, exactly as long as the song, and starts at
/// song time zero. The player plays it beside the song and Create Click Track
/// writes it to a file, so what is exported is what was heard.
///
/// - Clicks are placed from the beat list, beat by beat, never from a tempo.
///   A click starts at `round(time * 48000)`.
/// - Where the grid has no beats there is no click: before the first beat,
///   after the last one, and inside a stretch that was left empty.
/// - The first beat of each bar gets the accent version of the sound.
/// - The clicks between two beats (half-beats and sub-beats) are 6 dB quieter
///   than the beat's own click, so the beat stays clear.
/// - The volume is not in the samples, and neither is "click on". Multiply by
///   `settings.gain` when playing or writing.
public enum ClickRenderer {
    /// The loudest a sample of the finished click may be: 1 dB below full scale.
    public static let peakLimit: Float = 0.8913
    /// What a click between two beats is multiplied by: 6 dB quieter.
    public static let betweenBeatsGain: Float = 0.5012

    /// - Parameters:
    ///   - grid: the song's beats. Nil, or without beats, gives silence.
    ///   - settings: the sound and how often it clicks. Whether the click is
    ///     on and its volume are not used here.
    ///   - lengthSamples: the song's length. The result is this long.
    ///   - accentBeatOne: false gives the first beat of a bar the plain sound
    ///     (setting `click.accentBeatOne`).
    public static func render(
        grid: Grid?,
        settings: ClickSettings,
        lengthSamples: Int,
        accentBeatOne: Bool = SettingKey<Bool>.accentBeatOne.defaultValue,
        keeping kept: Range<Int>? = nil
    ) -> [Float] {
        var click = [Float](repeating: 0, count: max(lengthSamples, 0))
        guard let grid, !grid.beats.isEmpty, !click.isEmpty else { return click }
        // Where the song is cut away there is no click: one that would start there is left out, and one
        // that rings over the end of what is left stops there.
        let kept = (kept ?? 0..<click.count).clamped(to: 0..<click.count)

        let plain = settings.sound.samples(accent: false)
        let accent = accentBeatOne ? settings.sound.samples(accent: true) : plain
        let perBeat = settings.clicksPerBeat

        click.withUnsafeMutableBufferPointer { buffer in
            for (index, beat) in grid.beats.enumerated() {
                add(grid.isBarStart(beat.number) ? accent : plain, at: beat.time, gain: 1, to: buffer, keeping: kept)
                // The stretch to the next beat is cut into equal parts, as
                // `Grid.subBeats` cuts it. A beat with an empty stretch after
                // it, and the last beat, stand alone.
                guard perBeat > 1, index + 1 < grid.beats.count, grid.follows(index) else { continue }
                let step = (grid.beats[index + 1].time - beat.time) / Double(perBeat)
                for part in 1..<perBeat {
                    add(plain, at: beat.time + step * Double(part), gain: betweenBeatsGain, to: buffer, keeping: kept)
                }
            }
            keepUnderPeakLimit(buffer)
        }
        return click
    }

    /// Adds one click to the song's row of samples, starting on the whole
    /// sample nearest to `seconds`. Where it lies over the tail of an earlier
    /// click the two add up. What would fall outside what is kept of the song is left out.
    private static func add(
        _ sound: [Float],
        at seconds: Double,
        gain: Float,
        to buffer: UnsafeMutableBufferPointer<Float>,
        keeping kept: Range<Int>
    ) {
        let position = (seconds * Lockstep.sampleRate).rounded()
        guard position >= Double(kept.lowerBound), position < Double(kept.upperBound) else { return }
        let start = Int(position)
        for offset in 0..<min(sound.count, kept.upperBound - start) {
            buffer[start + offset] += sound[offset] * gain
        }
    }

    /// Where tails have added up to more than the limit, the whole click is
    /// turned down by one factor, so every click keeps its loudness relative
    /// to the others. A click whose tails never meet is left untouched.
    private static func keepUnderPeakLimit(_ buffer: UnsafeMutableBufferPointer<Float>) {
        var loudest: Float = 0
        for sample in buffer {
            loudest = max(loudest, abs(sample))
        }
        guard loudest > peakLimit else { return }
        let gain = peakLimit / loudest
        for index in buffer.indices {
            buffer[index] *= gain
        }
    }
}

// MARK: - The count-in

/// The clicks of a take's count-in as sound. A count-in is played beside the song's own click, never as part
/// of it, so nothing here changes what `render` gives or what the click file holds.
extension ClickRenderer {
    /// How much louder than the first beat of a bar the click to start on is: 6 dB, where the click's volume
    /// leaves room for it. A starting value.
    public static let startClickGain: Float = 1.9953

    /// The loudest sample of the click to start on, for a click played at `volume`: 6 dB above the click on
    /// the first beat of a bar, and never above `peakLimit`, 1 dB below full scale. At a volume above about a
    /// half the limit decides, and the click to start on is less than 6 dB louder.
    public static func startClickPeak(volume: Float, accentBeatOne: Bool) -> Float {
        let barPeak = accentBeatOne ? ClickSound.accentPeak : ClickSound.peak
        return min(barPeak * startClickGain * min(max(volume, 0), 1), peakLimit)
    }

    /// The clicks of a count-in as one row of samples, mono at 48,000 Hz. Sample 0 is the first sample of
    /// the count-in (`CountIn.sample(at:)`), and the row goes on past the place until its last click has
    /// rung out.
    ///
    /// - A beat gets the plain sound and the first beat of a bar the accent, as in the song's click. With a
    ///   click that sounds more often than every beat, the clicks between two beats are there too, 6 dB
    ///   quieter.
    /// - The place itself gets the click to start on (`ClickSound.startSamples`).
    /// - The volume is in the samples, unlike in `render`: the click to start on is measured against it, so
    ///   that it never comes out above full scale. Play the row as it is.
    /// - A count-in without clicks (off) gives an empty row.
    ///
    /// - Parameters:
    ///   - settings: the click's sound and how often it clicks. Whether the click is on is not used: the
    ///     count-in always clicks. Its volume is not used either.
    ///   - volume: how loud the click is played, from 0 to 1.
    ///   - accentBeatOne: false gives the first beat of a bar the plain sound (setting `click.accentBeatOne`).
    public static func renderCountIn(
        _ countIn: CountIn,
        settings: ClickSettings,
        volume: Float,
        accentBeatOne: Bool = SettingKey<Bool>.accentBeatOne.defaultValue
    ) -> [Float] {
        guard !countIn.clicks.isEmpty else { return [] }
        let volume = min(max(volume, 0), 1)
        let plain = settings.sound.samples(accent: false)
        let accent = accentBeatOne ? settings.sound.samples(accent: true) : plain
        let start = ClickSound.startSamples(peak: startClickPeak(volume: volume, accentBeatOne: accentBeatOne))
        let perBeat = settings.clicksPerBeat

        var row = [Float](repeating: 0, count: countIn.lengthSamples + max(plain.count, accent.count, start.count))
        row.withUnsafeMutableBufferPointer { buffer in
            for (index, click) in countIn.clicks.enumerated() {
                let sample = countIn.sample(at: click.time)
                switch click.kind {
                case .start: add(start, atSample: sample, gain: 1, to: buffer)
                case .barStart: add(accent, atSample: sample, gain: volume, to: buffer)
                case .beat: add(plain, atSample: sample, gain: volume, to: buffer)
                }
                guard perBeat > 1, index + 1 < countIn.clicks.count else { continue }
                for time in timesBetween(click.time, countIn.clicks[index + 1].time, perBeat: perBeat) {
                    add(plain, atSample: countIn.sample(at: time), gain: betweenBeatsGain * volume, to: buffer)
                }
            }
            keepUnderPeakLimit(buffer)
        }
        return row
    }

    /// When every click of a count-in sounds, and how long the longest of them lasts: what is needed to tell
    /// the click leaking from the headphones into the microphone from a voice
    /// (`RecordingPlacement.clipSamples(of:voicedStretches:origin:grid:clickLeak:)`).
    public static func leak(of countIn: CountIn, settings: ClickSettings) -> ClickLeak {
        guard !countIn.clicks.isEmpty else { return .none }
        let perBeat = settings.clicksPerBeat
        var times: [Double] = []
        for (index, click) in countIn.clicks.enumerated() {
            times.append(click.time)
            guard perBeat > 1, index + 1 < countIn.clicks.count else { continue }
            times.append(contentsOf: timesBetween(click.time, countIn.clicks[index + 1].time, perBeat: perBeat))
        }
        let longest = max(
            settings.sound.samples(accent: false).count,
            settings.sound.samples(accent: true).count,
            ClickSound.startLengthSamples
        )
        return ClickLeak(times: times, soundSeconds: Double(longest) / Lockstep.sampleRate)
    }

    /// The times of the clicks between two beats, for a click that sounds `perBeat` times a beat.
    private static func timesBetween(_ beat: Double, _ next: Double, perBeat: Int) -> [Double] {
        guard perBeat > 1 else { return [] }
        let step = (next - beat) / Double(perBeat)
        return (1..<perBeat).map { beat + step * Double($0) }
    }

    /// Adds one click to a row of samples, starting on the given sample. What would fall outside the row is
    /// left out.
    private static func add(
        _ sound: [Float],
        atSample start: Int,
        gain: Float,
        to buffer: UnsafeMutableBufferPointer<Float>
    ) {
        guard start >= 0, start < buffer.count else { return }
        for offset in 0..<min(sound.count, buffer.count - start) {
            buffer[start + offset] += sound[offset] * gain
        }
    }
}
