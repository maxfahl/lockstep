import LockstepCore

/// Everything the click's samples depend on: the song's beats, the sound, how
/// often it clicks and in which sub-beats, the song's length, what is left of the song after cutting, and whether the first beat of a bar is
/// accented (a setting, not part of the project). Two that are equal give the
/// same click, so the click is laid out again only when this changes.
///
///     let layout = ClickLayout(project, accentBeatOne: settings[.accentBeatOne])
///     let click = await layout.samples()
///
/// Whether the click is on, and its volume, are not part of it: the player
/// applies those without a new click.
struct ClickLayout: Equatable, Sendable {
    private let grid: Grid?
    private let sound: ClickSound
    private let division: ClickDivision
    private let subBeats: SubBeatGrid
    private let lengthSamples: Int
    /// The samples of the song that are left after cutting. Outside them there is no click.
    private let kept: Range<Int>
    private let accentBeatOne: Bool

    init(_ project: Project, accentBeatOne: Bool) {
        // A grid without beats gives the same click as no grid at all: none.
        grid = project.grid.flatMap { $0.beats.isEmpty ? nil : $0 }
        sound = project.click.sound
        division = project.click.division
        subBeats = project.click.subBeats
        lengthSamples = project.songLengthSamples
        kept = project.keptSamples
        self.accentBeatOne = accentBeatOne
    }

    /// The click of the whole song, laid out on a background thread: mono at
    /// 48,000 Hz and as long as the song. Empty when the song has no beats.
    @concurrent
    func samples() async -> [Float] {
        guard let grid else { return [] }
        return ClickRenderer.render(
            grid: grid,
            settings: ClickSettings(sound: sound, division: division, subBeats: subBeats),
            lengthSamples: lengthSamples,
            accentBeatOne: accentBeatOne,
            keeping: kept
        )
    }
}
