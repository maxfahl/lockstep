/// The beats of a song, one by one, with the corrections Max made to them.
///
/// `beats` and `barStartNumber` are derived: every refit rebuilds them from the
/// cached model output. `anchors`, `tempoLevel` and `beatOne` are the inputs of
/// that refit, so a correction is never stored as a change to the beat list.
public struct Grid: Codable, Sendable, Equatable {
    /// Sorted by time. Derived: rebuilt by every refit.
    public var beats: [Beat]
    /// The number of one beat that is beat 1 of a bar. Derived.
    public var barStartNumber: Int
    /// Input: beats Max dragged.
    public var anchors: [Anchor]
    /// Input: halved, normal or doubled.
    public var tempoLevel: TempoLevel
    /// Input: song time of the beat Max chose as beat 1, if he did.
    public var beatOne: Double?

    public init(
        beats: [Beat] = [],
        barStartNumber: Int = 0,
        anchors: [Anchor] = [],
        tempoLevel: TempoLevel = .normal,
        beatOne: Double? = nil
    ) {
        self.beats = beats
        self.barStartNumber = barStartNumber
        self.anchors = anchors
        self.tempoLevel = tempoLevel
        self.beatOne = beatOne
    }

    /// Reads saved beats. A field that is missing, because the project was saved before
    /// the field existed, gets its default.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fresh = Grid()
        beats = try container.decodeIfPresent([Beat].self, forKey: .beats) ?? fresh.beats
        barStartNumber = try container.decodeIfPresent(Int.self, forKey: .barStartNumber) ?? fresh.barStartNumber
        anchors = try container.decodeIfPresent([Anchor].self, forKey: .anchors) ?? fresh.anchors
        tempoLevel = try container.decodeIfPresent(TempoLevel.self, forKey: .tempoLevel) ?? fresh.tempoLevel
        beatOne = try container.decodeIfPresent(Double.self, forKey: .beatOne)
    }
}

/// One beat line.
public struct Beat: Codable, Sendable, Equatable {
    /// Counts beats. Skips numbers across a gap that was left empty.
    public var number: Int
    /// Song seconds.
    public var time: Double
    /// True when no clean drum hit backed it.
    public var estimated: Bool

    public init(number: Int, time: Double, estimated: Bool = false) {
        self.number = number
        self.time = time
        self.estimated = estimated
    }

    /// Reads a saved beat. Its number and time must be there; without `estimated` it
    /// counts as a beat backed by a drum hit.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        number = try container.decode(Int.self, forKey: .number)
        time = try container.decode(Double.self, forKey: .time)
        estimated = try container.decodeIfPresent(Bool.self, forKey: .estimated) ?? false
    }
}

/// A beat Max dragged. Kept by time, not by beat number, so it survives a
/// change of tempo level.
public struct Anchor: Codable, Sendable, Equatable {
    /// Where the fitted curve put the beat, song seconds.
    public var from: Double
    /// Where Max dragged it.
    public var to: Double

    public init(from: Double, to: Double) {
        self.from = from
        self.to = to
    }
}

/// Whether the grid shows every second beat, every beat, or twice as many.
public enum TempoLevel: String, Codable, Sendable, CaseIterable {
    case halved
    case normal
    case doubled
}
