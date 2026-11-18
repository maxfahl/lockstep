import LockstepUI
import SwiftUI

extension LabState {
    /// The Send to DaVinci panel for the selected clip: the timecode large,
    /// Copy, the step to take in DaVinci Resolve, the exported file, "Show in
    /// Finder", the three values of the Resolve project and the switch "With
    /// sound", which is on: the file is the clip as it sounds in Lockstep, and
    /// says so under its name.
    static let send = LabState("Send") {
        SendStateView(content: SampleContent.makeSend())
    }

    /// The panel for three selected clips: the step in Resolve, then the clips
    /// as a list with a timecode and a small Copy each. Each was sent with its
    /// sound, and says so after its track.
    static let sendSeveralClips = LabState("Send several clips") {
        SendStateView(content: SampleContent.makeSend(clipCount: 3))
    }

    /// The panel for fourteen clips: the list scrolls after six rows, so the
    /// panel stays the same height however many clips are sent. The fourth
    /// clip has no Sound and no effect, so it was sent dry and says nothing more.
    static let sendManyClips = LabState("Send many clips") {
        SendStateView(content: SampleContent.makeSend(clipCount: 14))
    }

    /// The panel while the Lockstep script is not in DaVinci Resolve: the step
    /// is a notice that says where to install it. The clip is placed by hand.
    static let sendWithoutScript = LabState("Send without the script") {
        SendStateView(content: SampleContent.makeSend(script: SendContent.ScriptStep.notInstalled))
    }

    /// The panel while the script in DaVinci Resolve is an older one: the same
    /// notice with other words. A list that could not be written looks the same.
    static let sendWithOldScript = LabState("Send with an old script") {
        SendStateView(content: SampleContent.makeSend(script: SendContent.ScriptStep.outdated))
    }

    /// The panel for the selected clip with "With sound" switched off: the
    /// clip is sent dry, as before there were Sounds, and its file says
    /// nothing about sound.
    static let sendWithoutSound = LabState("Send without sound") {
        SendStateView(content: SampleContent.makeSend(withSound: false))
    }

    // The three states a clip's row has since a track can have a Voice.

    /// Four clips, one in each state of a row about its track's Voice. The
    /// voice of the first is still being made: it has the ring and no file,
    /// and the step for Resolve says to wait. The second was sent in its
    /// track's Voice with a Sound, the third in its track's Voice alone, and
    /// the voice of the fourth could not be made, so it was sent in Max's own.
    static let sendWithVoices = LabState("Send with voices") {
        var content = SampleContent.makeSend(clipCount: 4)
        content.clips[0].voice = .making(progress: nil)
        content.clips[0].fileName = ""
        content.clips[1].voice = .sent
        content.clips[2].voice = .sent
        content.clips[2].isSentWithSound = false
        content.clips[3].voice = .failed
        content.script = .waitingForVoices(for: content.clips)
        return SendStateView(content: content)
    }

    /// The panel for one clip whose voice is still being made, a little
    /// under half done: the ring where the file's symbol is, no file to drag
    /// or to show, and the step for Resolve says to wait. The timecode is
    /// there already.
    static let sendVoiceBeingMade = LabState("Send while the voice is made") {
        var content = SampleContent.makeSend()
        content.clips[0].voice = .making(progress: 0.4)
        content.clips[0].fileName = ""
        content.script = .waitingForVoices(for: content.clips)
        return SendStateView(content: content)
    }

    /// The panel for one clip that was sent in its track's Voice, with its
    /// Sound: the file says both under its name.
    static let sendWithVoice = LabState("Send with the track's Voice") {
        var content = SampleContent.makeSend()
        content.clips[0].voice = .sent
        return SendStateView(content: content)
    }

    /// The panel for one clip whose voice could not be made: the file holds
    /// Max's own voice, and says so under its name.
    static let sendVoiceFailed = LabState("Send, the voice could not be made") {
        var content = SampleContent.makeSend()
        content.clips[0].voice = .failed
        return SendStateView(content: content)
    }
}

/// The whole window with the Send to DaVinci panel opened over it as soon as
/// it is shown. Done closes it; the state is opened again by stepping away
/// and back.
private struct SendStateView: View {
    let content: SendContent
    @State private var showsSheet = false

    /// The window behind the panel. Where the clips are sent with their sound, the selected track has
    /// one, so the window and the panel say the same.
    private var window: MainLayoutContent {
        var window = SampleContent.makeMainLayout()
        if content.withSound == true {
            for trackIndex in window.timeline.trackRows.indices where window.timeline.trackRows[trackIndex].isSelected {
                window.timeline.trackRows[trackIndex].sound = SoundValues.builtIn("Rap lead")
            }
        }
        return window
    }

    var body: some View {
        LabMainLayout(content: window, showsInspector: true)
            .sheet(isPresented: $showsSheet) {
                SendSheet(content: content) {
                    showsSheet = false
                }
            }
            .task { showsSheet = true }
    }
}
