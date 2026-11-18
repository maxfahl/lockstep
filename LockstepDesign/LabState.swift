import SwiftUI

/// One design state: a name, and what the lab window shows for it.
///
/// A state only shows how something looks. Nothing in it works.
@MainActor
struct LabState: Identifiable {
    /// The name in the panel, and the name after the launch argument `-state`.
    let name: String
    private let makeView: () -> AnyView

    nonisolated var id: String { name }

    /// - Parameters:
    ///   - name: The name in the panel. No other state may have it.
    ///   - view: Makes what the window shows. It is called when the state
    ///     is opened, so the state starts the same way every time.
    init(_ name: String, view: @escaping () -> some View) {
        self.name = name
        makeView = { AnyView(view()) }
    }

    /// What the window shows for this state.
    var view: AnyView { makeView() }
}

extension LabState {
    // HOW TO ADD A STATE
    //
    // 1. Make one new file in `LockstepDesign/States/`, named after the state,
    //    for example `ClipSelectedState.swift`:
    //
    //        import LockstepUI
    //        import SwiftUI
    //
    //        extension LabState {
    //            static let clipSelected = LabState("Clip selected") {
    //                var content = SampleContent.makeMainLayout()
    //                // ...change the made-up content to what the state shows...
    //                return LabMainLayout(content: content)
    //            }
    //        }
    //
    //    `LabMainLayout` is the whole window (`MainLayout` with every feature).
    //    A state that shows something else, such as a sheet of components side
    //    by side, returns that view instead; see `ControlsState.swift`.
    //    The file needs no change to the Xcode project.
    //
    // 2. Add one line to the list below, under the heading of your task, on
    //    a line of its own. Keep the empty lines between the headings: they
    //    let several tasks add lines at the same time without colliding.
    //
    // That is all. The state is then in the panel's menu, is reached with
    // Previous and Next and the arrow keys, in the order of this list, and
    // opens at launch with `-state "Clip selected"`. Names must differ from
    // each other. Upper and lower case do not matter after `-state`.
    //
    //     Scripts/screenshot.sh --app LockstepDesign out.png -state "Clip selected"

    /// Every design state, in the order the panel steps through them.
    static let all: [LabState] = [
        .main,

        // The clip and its bar
        .clips,

        // Timing markers on a selected clip
        .clipSelected,
        .clipSelectedTriplets,
        .clipSelectedZoomedOut,

        // The height of the track rows
        .tracksLow,
        .tracksTall,

        // Controls for the selected track and the selected clip
        .nothingSelected,
        .trackSelected,
        .trackSelectedMuted,
        .trackSelectedTurnedUp,
        .songSelected,
        .oneClipSelected,
        .oneClipSelectedLines,
        .oneClipSelectedOff,
        .severalClipsSelected,

        // What a clip's correction aims at: the row in the panel, and the marks of a double against its lead
        .aimAtBeat,
        .aimAtLead,
        .menuAimAt,
        .aimAtLeadOff,
        .aimMixed,
        .doubleAgainstLead,

        // The Voice of a track: the section in the panel in its eleven states, and its menu
        .voiceNever,
        .voiceOn,
        .voiceCustom,
        .voiceOff,
        .voicesBeingMade,
        .voicesFailed,
        .voiceWhileTakeGoes,
        .voiceNatural,
        .naturalVoicesBeingMade,
        .naturalWithoutEngine,
        .naturalWithoutSample,
        .menuVoice,

        // The Sound of a track and of a clip
        .trackWithSound,
        .soundsBeingMade,
        .menuSound,
        .oneClipWithSound,
        .oneClipOwnSpace,
        .severalClipsWithSound,

        // The effects of a clip: the list in the panel and the marks on the clip
        .effectsNone,
        .effectsThickWholeClip,
        .effectsLowOnWords,
        .effectsThree,
        .effectsEchoOnLastWord,
        .effectsOnWords,
        .effectsWordsMarked,
        .effectsLowRow,
        .effectsNarrowClip,
        .effectsSeveralClips,
        .menuEffects,

        // The effects of a track, what a clip changed of them, and the effects several clips share
        .trackNoEffect,
        .trackTwoEffects,
        .menuTrackEffects,
        .trackEffectsWordsMarked,
        .clipWithTrackEffects,
        .clipOwnLevelAndOff,
        .clipTrackPhoneOff,
        .clipTrackAndOwnEffects,
        .severalClipsTrackAndOwn,
        .severalClipsNothingShared,

        // The takes list in the panel on the right
        .takesList,

        // Click popover, calibrate sheet, Send to DaVinci panel
        .click,
        .clickOnSubBeats,
        .clickRecordSlower,
        .calibrate,
        .calibrateDone,
        .calibrateFailed,
        .send,
        .sendSeveralClips,
        .sendManyClips,
        .sendWithoutScript,
        .sendWithOldScript,
        .sendWithoutSound,
        .sendWithVoices,
        .sendVoiceBeingMade,
        .sendWithVoice,
        .sendVoiceFailed,

        // Right-click menus
        .menuClip,
        .menuTrack,
        .menuBeat,
        .menuSong,
        .menuSnapTo,
        .menuSnapToSomeOff,

        // Dragging
        .draggingClip,
        .snapped,
        .snappedToPlayhead,
        .snappedToRecordedPlace,
        .snappingOff,
        .trimmingClip,
        .trimmingSnapped,
        .markedStretch,
        .selectionRectangle,
        .selectionRectangleAllTracks,
        .selectionRectangleUpwards,
        .loop,
        .loopInAndOut,
        .loopInOnly,
        .loopOutOnly,
        .reordering,

        // The song cut and moved
        .songCutAtStart,
        .songCutAtEnd,
        .songAtZero,
        .songEdgeHover,

        // Recording, the empty window and the small states
        .recordSlower,
        .runningUp,
        .recording,
        .empty,
        .findingBeats,
        .notCalibrated,
        .message,
        .trackList,
        .beatHover,
        .writingOutWords,

        // Tools of the lab. Keep these last.
        .controls,
        .stress,
    ]
}
