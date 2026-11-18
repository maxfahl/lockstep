import LockstepCore
import LockstepUI

// The click exists twice: as the project keeps it (`LockstepCore`) and as the
// click popover shows it (`LockstepUI`, which knows nothing about projects).
// The types have the same names in both, so here, where they meet, each is
// written with the name of its module. The app translates in both directions:
// what the project says is shown, and what is chosen in the popover is put
// into the project.

extension LockstepUI.ClickSettings {
    /// What the click popover shows for a project's click, with the Count-in row under it.
    ///
    /// - Parameter countInBars: how many bars are counted in before recording, the
    ///   setting `recording.runUpBars`: 0 (Off), 1, 2 or 4. It is not the project's: it
    ///   is the same for every song.
    /// - Parameter recordSpeedPercent: the speed the song plays at while a take is recorded, the
    ///   setting `recording.speedPercent`: 100, 90 or 85. It is the same for every song too.
    init(_ click: LockstepCore.ClickSettings, countInBars: Int, recordSpeedPercent: Int) {
        self.init(
            sound: LockstepUI.ClickSound(click.sound),
            volume: click.volume,
            division: LockstepUI.ClickDivision(click.division),
            subBeats: LockstepUI.ClickSubBeats(click.subBeats),
            countInBars: countInBars,
            recordSpeedPercent: recordSpeedPercent
        )
    }
}

extension LockstepUI.ClickSound {
    init(_ sound: LockstepCore.ClickSound) {
        switch sound {
        case .woodblock: self = .woodblock
        case .rimshot: self = .rimshot
        case .hiHat: self = .hiHat
        case .cowbell: self = .cowbell
        case .beep: self = .beep
        }
    }
}

extension LockstepCore.ClickSound {
    /// The sound that was chosen in the popover.
    init(_ shown: LockstepUI.ClickSound) {
        switch shown {
        case .woodblock: self = .woodblock
        case .rimshot: self = .rimshot
        case .hiHat: self = .hiHat
        case .cowbell: self = .cowbell
        case .beep: self = .beep
        }
    }
}

extension LockstepUI.ClickDivision {
    init(_ division: LockstepCore.ClickDivision) {
        switch division {
        case .beats: self = .beats
        case .halfBeats: self = .halfBeats
        case .subBeats: self = .subBeats
        }
    }
}

extension LockstepCore.ClickDivision {
    /// What was chosen under "Click on" in the popover.
    init(_ shown: LockstepUI.ClickDivision) {
        switch shown {
        case .beats: self = .beats
        case .halfBeats: self = .halfBeats
        case .subBeats: self = .subBeats
        }
    }
}

extension LockstepUI.ClickSubBeats {
    init(_ subBeats: SubBeatGrid) {
        switch subBeats {
        case .sixteenths: self = .sixteenths
        case .triplets: self = .triplets
        }
    }
}

extension SubBeatGrid {
    /// What was chosen under "Click on" in the popover for a click on sub-beats.
    init(_ shown: LockstepUI.ClickSubBeats) {
        switch shown {
        case .sixteenths: self = .sixteenths
        case .triplets: self = .triplets
        }
    }
}
