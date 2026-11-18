/// The start of one syllable in a recording: the moment its vowel arrives, which is
/// what the ear hears as the beat of the syllable.
///
/// A marker belongs to its recording, not to a clip, so it stays the same when clips
/// are split, joined or moved. Its sample position is also its identity: the syllables
/// Max excludes are remembered by that position (`Recording.excludedMarkers`).
public struct SyllableMarker: Codable, Sendable, Equatable {
    /// Where the syllable starts, as a sample of the recording at 48,000 Hz.
    public var sample: Int
    /// How sharply the voice rises there: the climb of the loudness over 15 ms, in
    /// decibels. When two markers are too close to be two syllables, the stronger stays.
    public var strength: Double

    public init(sample: Int, strength: Double) {
        self.sample = sample
        self.strength = strength
    }
}
