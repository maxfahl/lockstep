import SwiftUI

// The Send to DaVinci panel: a sheet that says where the sent clips go on the
// DaVinci Resolve timeline, how Resolve places them, and hands over the
// exported files.

/// What the Send to DaVinci panel shows. All texts are ready to show.
public struct SendContent: Sendable, Equatable {
    /// The frame rates a Resolve project can have here.
    public static let frameRates = ["23.976", "24", "25", "30", "50", "60"]

    /// One clip that was exported.
    public struct Clip: Sendable, Equatable, Identifiable {
        public var id: UUID
        /// The clip's name.
        public var name: String
        /// The name of the clip's track. Resolve puts the clip on the audio track with this name.
        public var trackName: String
        /// Where the clip starts on the Resolve timeline, such as "01:00:16:00".
        public var timecode: String
        /// The name of the exported file.
        public var fileName: String
        /// The file holds the clip as it sounds in Lockstep, with its Sound and its effects, in stereo.
        /// False for a clip that was sent dry: with "With sound" switched off, or because it has no Sound
        /// and no effect. The clip's row then says nothing more. Set it after making the clip.
        public var isSentWithSound = false
        /// What the clip's row says about the Voice of its track. Set it after making the clip.
        public var voice: Voice = .none

        /// What became of the Voice of a clip's track when the clip was sent.
        public enum Voice: Sendable, Equatable {
            /// Nothing to say: the clip's track has no Voice that is heard, or the clip was sent without it,
            /// with "With sound" switched off.
            case none
            /// The clip's voice is still being made, so the clip has no file yet (`fileName` is empty): a
            /// small ring stands where the file's symbol is, and the row reads "Making the voice…". The ring
            /// fills to `progress`, from 0 to 1, or turns by itself when that is nil.
            case making(progress: Double?)
            /// The file holds the clip in its track's Voice.
            case sent
            /// The clip's voice could not be made, so the file holds Max's own voice.
            case failed

            /// Whether the clip has no file yet.
            var isBeingMade: Bool {
                if case .making = self { true } else { false }
            }
        }

        public init(id: UUID = UUID(), name: String, trackName: String, timecode: String, fileName: String) {
            self.id = id
            self.name = name
            self.trackName = trackName
            self.timecode = timecode
            self.fileName = fileName
        }
    }

    /// What the panel says about the Lockstep script in DaVinci Resolve, which
    /// places the sent clips there with one menu choice. The sentences for
    /// every case are made here (`ready`, `notInstalled`, `outdated`,
    /// `listNotWritten`), so the app and the design lab show the same words.
    public struct ScriptStep: Sendable, Equatable {
        /// What to do, or what is in the way.
        public var title: String
        /// One or two sentences more.
        public var detail: String
        /// True when choosing the script in Resolve will place the clips. False
        /// shows the step as a notice: the clips are then placed by hand.
        public var isReady: Bool

        public init(title: String, detail: String, isReady: Bool) {
            self.title = title
            self.detail = detail
            self.isReady = isReady
        }

        /// The script is in Resolve and the clips are handed to it.
        public static func ready(for clips: [Clip]) -> ScriptStep {
            let detail = if clips.count == 1, let clip = clips.first {
                "It puts the clip on the audio track \u{201C}\(clip.trackName)\u{201D}, at this timecode. "
                    + "A track with that name is added when there is none."
            } else {
                "It puts each clip on the audio track with the name of its track here, at its timecode. "
                    + "Tracks that are missing are added."
            }
            return ScriptStep(
                title: "In DaVinci Resolve, choose Workspace > Scripts > Lockstep",
                detail: detail,
                isReady: true
            )
        }

        /// The script has not been put into Resolve.
        public static func notInstalled(for clips: [Clip]) -> ScriptStep {
            ScriptStep(
                title: "The Lockstep script is not in DaVinci Resolve yet",
                detail: "Install it in Settings, under DaVinci. Resolve then places what you send with one "
                    + "menu choice. Until then, place \(clips.count == 1 ? "the clip" : "the clips") by hand.",
                isReady: false
            )
        }

        /// The script in Resolve is not the one this Lockstep has.
        public static func outdated(for clips: [Clip]) -> ScriptStep {
            ScriptStep(
                title: "The Lockstep script in DaVinci Resolve is an older one",
                detail: "Update it in Settings, under DaVinci, before you choose it in Resolve. Until then, "
                    + "place \(clips.count == 1 ? "the clip" : "the clips") by hand.",
                isReady: false
            )
        }

        /// Some of the clips have no file yet, because their voice is still being made. The list for the
        /// script is written when every clip has its file, so the script would place nothing new until then.
        public static func waitingForVoices(for clips: [Clip]) -> ScriptStep {
            ScriptStep(
                title: "Wait until the voice is made",
                detail: clips.count == 1
                    ? "The script in DaVinci Resolve gets the clip when its file is made. "
                        + "Then choose Workspace > Scripts > Lockstep there."
                    : "The script in DaVinci Resolve gets the clips when every one of them has its file. "
                        + "Then choose Workspace > Scripts > Lockstep there.",
                isReady: false
            )
        }

        /// The list the script reads could not be written into `folder`.
        public static func listNotWritten(for clips: [Clip], folder: String) -> ScriptStep {
            ScriptStep(
                title: "Lockstep could not hand \(clips.count == 1 ? "the clip" : "the clips") to its script in Resolve",
                detail: "The list of sent clips could not be written to \(folder). "
                    + "Place \(clips.count == 1 ? "the clip" : "the clips") by hand.",
                isReady: false
            )
        }
    }

    /// The clips that were exported, in the order they are shown. One clip is
    /// shown large, several as a list.
    public var clips: [Clip]
    /// What the panel says about placing them with the script in Resolve.
    public var script: ScriptStep
    /// Whether the switch "With sound" is on: the clips are sent as they sound in Lockstep. Nil, which it
    /// is until it is set, leaves the switch out.
    public var withSound: Bool?

    // The values of this project's Resolve timeline.

    /// The timecode the Resolve timeline starts at.
    public var timelineStart: String
    /// One of `frameRates`.
    public var frameRate: String
    /// Where on the Resolve timeline the song starts, as a timecode.
    public var songStart: String

    /// - Parameter script: Left out, the panel says the script is ready (`ScriptStep.ready`).
    public init(
        clips: [Clip],
        script: ScriptStep? = nil,
        timelineStart: String = "01:00:00:00",
        frameRate: String = "25",
        songStart: String = "01:00:00:00"
    ) {
        self.clips = clips
        self.script = script ?? .ready(for: clips)
        self.timelineStart = timelineStart
        self.frameRate = frameRate
        self.songStart = songStart
    }
}

/// The content of the Send to DaVinci panel. Show it with the system's `sheet`:
///
///     .sheet(isPresented: $showsSend) {
///         SendSheet(content: send) { showsSend = false }
///     }
///
/// With one clip, from the top: the title with the clip's name, the timecode
/// as the largest text in the app with Copy beside it, the step to take in
/// DaVinci Resolve (`SendContent.ScriptStep`), the exported file as something
/// to drag into Resolve by hand with "Show in Finder", the three values of
/// the Resolve project as small fields, and Done, which calls `onClose`. In
/// Done's line, at the left, stands the switch "With sound", when the content
/// has it (`SendContent.withSound`). A clip that was sent with its sound says
/// "stereo, with sound": under its file's name, or after its track in the list.
/// What became of its track's Voice stands in the same place
/// (`SendContent.Clip.voice`): "with the track's Voice", or "sent in your own
/// voice: its voice could not be made". A clip whose voice is still being made
/// has no file yet: a small ring stands where the file's symbol is, and the row
/// reads "Making the voice…".
///
/// With several clips the title says how many, the step in Resolve comes
/// first, and the clips are a list: each row has the clip's name, its track,
/// its timecode and a small Copy, and can be dragged out as its file. More
/// than `Sizes.sendClipRowsShown` rows scroll.
///
/// Without `actions` only Done does anything, and the fields can be typed in,
/// which changes nothing else. That is how the design lab shows the panel.
/// With `actions` (`SendActions`) the panel is live: Copy and Show in Finder
/// report, a file can be dragged out, and a value of the Resolve project
/// that was changed is reported when Return is pressed, the field is left or
/// Done is pressed. The fields then show what `content` says, so a value the
/// owner did not take goes back to what it was. While a field holds text that is
/// not a timecode, a line under the fields says how one is written, when the owner
/// gives that sentence (`SendActions.timecodeHint`).
public struct SendSheet: View {
    /// The two fields that are typed in.
    private enum Field {
        case timelineStart
        case songStart
    }

    private let content: SendContent
    private let actions: SendActions?
    private let onClose: () -> Void

    @State private var timelineStart: String
    @State private var frameRate: String
    @State private var songStart: String
    /// What the switch "With sound" stands at while the panel has no owner that listens to it.
    @State private var keptWithSound: Bool
    /// The field that is being typed in, to know when it is left.
    @FocusState private var typing: Field?

    public init(content: SendContent, actions: SendActions? = nil, onClose: @escaping () -> Void = {}) {
        self.content = content
        self.actions = actions
        self.onClose = onClose
        _timelineStart = State(initialValue: content.timelineStart)
        _frameRate = State(initialValue: content.frameRate)
        _songStart = State(initialValue: content.songStart)
        _keptWithSound = State(initialValue: content.withSound ?? false)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xLarge) {
            if content.clips.count == 1, let clip = content.clips.first {
                SheetTitle(title: "Send to DaVinci", detail: clip.name)
                timecode(of: clip)
                scriptStep
                file(of: clip)
            } else {
                SheetTitle(title: "Send to DaVinci", detail: "\(content.clips.count) clips")
                scriptStep
                clipList
            }
            project
            HStack {
                if content.withSound != nil {
                    LabelledSwitch(
                        title: "With sound",
                        isOn: withSound,
                        help: "Sends each clip as it sounds in Lockstep, with its Sound and effects, in stereo and "
                            + "a little longer so reverb and echo ring out. Off sends it without them."
                    )
                }
                Spacer(minLength: 0)
                Button("Done") {
                    // A press on a button does not take the keyboard away from a
                    // field, so what was typed last is reported here. The panel
                    // then stays, because the timecode and the file may be new
                    // ones that have not been seen yet. The next press closes it.
                    let reportedStart = report(.timelineStart)
                    let reportedSong = report(.songStart)
                    if !reportedStart, !reportedSong {
                        onClose()
                    }
                }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .sheetFrame()
        // The owner decides what the Resolve project's values are. The fields
        // follow it: after a change it took, after one it did not, and after Undo.
        .onChange(of: content.timelineStart) { _, value in timelineStart = value }
        .onChange(of: content.frameRate) { _, value in frameRate = value }
        .onChange(of: content.songStart) { _, value in songStart = value }
        .onChange(of: typing) { left, _ in
            if let left {
                report(left)
            }
        }
    }

    /// Tells the owner what stands in a field, when it is not what the content
    /// says, and answers whether there was anything to tell. Until the owner
    /// answers, the field shows the content's value again, so text that is no
    /// timecode does not stay. Without an owner the field keeps what was typed.
    @discardableResult
    private func report(_ field: Field) -> Bool {
        let typed: String
        let shown: String
        let changed: (@MainActor (String) -> Void)?
        switch field {
        case .timelineStart:
            (typed, shown, changed) = (timelineStart, content.timelineStart, actions?.timelineStartChanged)
        case .songStart:
            (typed, shown, changed) = (songStart, content.songStart, actions?.songStartChanged)
        }
        guard let changed else { return false }
        switch field {
        case .timelineStart: timelineStart = shown
        case .songStart: songStart = shown
        }
        guard typed != shown else { return false }
        changed(typed)
        return true
    }

    // MARK: With sound

    /// The switch "With sound". An owner that listens is told what it was switched to and answers with new
    /// content. Without one the switch keeps what it shows itself.
    private var withSound: Binding<Bool> {
        Binding(
            get: { actions?.withSoundChanged == nil ? keptWithSound : content.withSound ?? false },
            set: { isOn in
                if let changed = actions?.withSoundChanged { changed(isOn) } else { keptWithSound = isOn }
            }
        )
    }

    /// Whether the rows say what the content says about sound and Voice. An owner that listens answers the
    /// switch with new content. Without one the rows follow the switch as it is flipped, so the panel shows
    /// both in the design lab: switched off, every clip is sent in Max's own voice and has its file.
    private var rowsSayHowSent: Bool {
        actions?.withSoundChanged != nil || content.withSound == nil || keptWithSound
    }

    /// What a clip's row says about its track's Voice.
    private func voice(of clip: SendContent.Clip) -> SendContent.Clip.Voice {
        rowsSayHowSent ? clip.voice : .none
    }

    /// How a clip was sent, after its track's name in a row and under its file's name for one clip:
    /// "stereo, with sound", and what became of its track's Voice. Nil when there is nothing to say.
    ///
    /// A clip that has both its Sound and its track's Voice says so in few words, "stereo, with sound and
    /// Voice", because that is what most clips of such a track say and a row has one short line for it.
    private func howSent(_ clip: SendContent.Clip) -> String? {
        guard rowsSayHowSent else { return nil }
        let withSound = "stereo, with sound"
        let ownVoice = "sent in your own voice: its voice could not be made"
        switch (clip.voice, clip.isSentWithSound) {
        case (.making, _): return Self.makingVoice
        case (.sent, true): return "\(withSound) and Voice"
        case (.sent, false): return "with the track's Voice"
        case (.failed, true): return "\(withSound) \u{00B7} \(ownVoice)"
        case (.failed, false): return ownVoice
        case (.none, true): return withSound
        case (.none, false): return nil
        }
    }

    /// What the row of a clip without a file yet reads.
    private static let makingVoice = "Making the voice\u{2026}"

    /// The symbol of a clip's file, or, while its voice is being made, the small ring in its place. The
    /// ring takes exactly the symbol's room, so a row keeps its layout when its file arrives.
    private func fileSymbol(of clip: SendContent.Clip, font: Font) -> some View {
        let making = voice(of: clip)
        return Image(systemName: "waveform")
            .font(font)
            .foregroundStyle(DesignTokens.Colors.accent)
            .opacity(making.isBeingMade ? 0 : 1)
            .overlay {
                if case .making(let progress) = making {
                    if let progress {
                        MakingRing(progress: progress, name: "Making the voice of this clip")
                    } else {
                        ProgressView()
                            .controlSize(.mini)
                            .help("Making the voice of this clip")
                            .accessibilityLabel("Making the voice of this clip")
                    }
                }
            }
    }

    // MARK: The timecode of one clip

    private func timecode(of clip: SendContent.Clip) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.tight) {
            Text("Place the clip at")
                .font(DesignTokens.Fonts.label)
                .foregroundStyle(DesignTokens.Colors.textSecondary)
            HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.large) {
                Text(clip.timecode)
                    .font(DesignTokens.Fonts.timecodeLarge)
                    .foregroundStyle(DesignTokens.Colors.textPrimary)
                    .lineLimit(1)
                    .fixedSize()
                    .textSelection(.enabled)
                    .accessibilityLabel("Resolve start time")
                    .accessibilityValue(clip.timecode)
                Spacer(minLength: 0)
                Button {
                    actions?.copyPressed?(clip.id)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .help("Copy the timecode")
            }
        }
    }

    // MARK: The step in DaVinci Resolve

    /// What to do in Resolve so the script there places the clips, or, as a
    /// notice, why it cannot yet.
    private var scriptStep: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.large) {
            Image(systemName: content.script.isReady ? "film" : "exclamationmark.triangle")
                .font(DesignTokens.Fonts.symbolLarge)
                .foregroundStyle(
                    content.script.isReady ? DesignTokens.Colors.accent : DesignTokens.Colors.textSecondary
                )
                .frame(
                    width: DesignTokens.Sizes.transportButton,
                    height: DesignTokens.Sizes.transportButton
                )
                .background(
                    content.script.isReady ? DesignTokens.Colors.controlFillOn : .clear,
                    in: DesignTokens.Shapes.control
                )
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.tight) {
                Text(content.script.title)
                    .font(DesignTokens.Fonts.label)
                    .foregroundStyle(DesignTokens.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(content.script.detail)
                    .font(DesignTokens.Fonts.caption)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .sheetBox()
        .accessibilityElement(children: .combine)
    }

    // MARK: The exported file of one clip

    /// The file as an item that can be dragged out, with "Show in Finder". While the clip's voice is
    /// being made there is no file: the box says so, with the ring where the file's symbol is, and there is
    /// nothing to drag or to show.
    private func file(of clip: SendContent.Clip) -> some View {
        let isBeingMade = voice(of: clip).isBeingMade
        return HStack(spacing: DesignTokens.Spacing.large) {
            fileSymbol(of: clip, font: DesignTokens.Fonts.symbolLarge)
                .frame(
                    width: DesignTokens.Sizes.transportButton,
                    height: DesignTokens.Sizes.transportButton
                )
                .background(DesignTokens.Colors.controlFillOn, in: DesignTokens.Shapes.control)
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.tight) {
                Text(isBeingMade ? Self.makingVoice : clip.fileName)
                    .font(DesignTokens.Fonts.label)
                    .foregroundStyle(DesignTokens.Colors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Group {
                    if isBeingMade {
                        Text("The file is here when the voice is made.")
                    } else {
                        if let howSent = howSent(clip) {
                            // The first letter is a capital here, where the words stand alone.
                            Text(howSent.prefix(1).uppercased() + howSent.dropFirst())
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Text("Or drag it into DaVinci Resolve yourself")
                    }
                }
                    .font(DesignTokens.Fonts.caption)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
            }
            Spacer(minLength: 0)
            showInFinder
                .disabled(isBeingMade)
        }
        .sheetBox()
        .draggable(as: isBeingMade ? nil : clip, with: actions)
        .help(isBeingMade ? "The file is here when the voice is made." : "Drag the file into DaVinci Resolve")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Exported file")
    }

    private var showInFinder: some View {
        Button("Show in Finder") { actions?.showInFinderPressed?() }
            .controlSize(.small)
            .fixedSize()
    }

    // MARK: Several clips

    /// The clips as a list, and under it how they are placed by hand.
    private var clipList: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.medium) {
            Group {
                if content.clips.count > DesignTokens.Sizes.sendClipRowsShown {
                    ScrollView {
                        clipRows
                    }
                    .frame(
                        height: CGFloat(DesignTokens.Sizes.sendClipRowsShown) * DesignTokens.Sizes.sendClipRowHeight
                    )
                } else {
                    clipRows
                }
            }
            .padding(.horizontal, DesignTokens.Spacing.large)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DesignTokens.Colors.controlFill, in: DesignTokens.Shapes.lane)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Exported clips")
            HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.large) {
                Text("Or drag each clip into DaVinci Resolve yourself, to its timecode.")
                    .font(DesignTokens.Fonts.caption)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                showInFinder
            }
        }
    }

    private var clipRows: some View {
        VStack(spacing: 0) {
            ForEach(Array(content.clips.enumerated()), id: \.element.id) { index, clip in
                if index > 0 {
                    DesignTokens.Colors.separator.frame(height: 1)
                }
                clipRow(clip)
            }
        }
    }

    /// One clip of the list: its name over its track, its timecode and a small
    /// Copy. The row is dragged out as the clip's file. A clip whose voice is
    /// still being made has the ring where the file's symbol is, and no file
    /// to drag. Its timecode is there already: it is the same with and
    /// without a Voice.
    private func clipRow(_ clip: SendContent.Clip) -> some View {
        let isBeingMade = voice(of: clip).isBeingMade
        return HStack(spacing: DesignTokens.Spacing.large) {
            fileSymbol(of: clip, font: DesignTokens.Fonts.symbol)
                .accessibilityHidden(!isBeingMade)
            VStack(alignment: .leading, spacing: 0) {
                Text(clip.name)
                    .font(DesignTokens.Fonts.label)
                    .foregroundStyle(DesignTokens.Colors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(howSent(clip).map { "\(clip.trackName) \u{00B7} \($0)" } ?? clip.trackName)
                    .font(DesignTokens.Fonts.caption)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                    // A second line for the one sentence that is longer than the row is wide: a voice
                    // that could not be made. The row is then a line taller.
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Text(clip.timecode)
                .font(DesignTokens.Fonts.readout)
                .foregroundStyle(DesignTokens.Colors.textPrimary)
                .lineLimit(1)
                .fixedSize()
                .textSelection(.enabled)
                .accessibilityLabel("Resolve start time")
                .accessibilityValue(clip.timecode)
            Button {
                actions?.copyPressed?(clip.id)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(DesignTokens.Fonts.symbolSmall)
            }
            .buttonStyle(.borderless)
            .help("Copy the timecode")
            .accessibilityLabel("Copy the timecode")
        }
        .padding(.vertical, DesignTokens.Spacing.tight)
        .frame(minHeight: DesignTokens.Sizes.sendClipRowHeight)
        .contentShape(Rectangle())
        .draggable(as: isBeingMade ? nil : clip, with: actions)
        .help(
            isBeingMade
                ? "The file is here when the voice is made."
                : "Drag the file \(clip.fileName) into DaVinci Resolve"
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(clip.name)
    }

    // MARK: The Resolve project

    private var project: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.medium) {
            Text("Resolve project")
                .font(DesignTokens.Fonts.panelTitle)
                .foregroundStyle(DesignTokens.Colors.textPrimary)
            HStack(alignment: .top, spacing: DesignTokens.Spacing.xLarge) {
                value("Timeline start") {
                    timecodeField("Timeline start", text: $timelineStart, field: .timelineStart)
                }
                value("Frame rate") {
                    // A frame rate is one of six, so it is chosen, not typed.
                    Picker("Frame rate", selection: chosenFrameRate) {
                        ForEach(SendContent.frameRates, id: \.self) { rate in
                            Text(rate).tag(rate)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                }
                value("Song starts at") {
                    timecodeField("Song starts at", text: $songStart, field: .songStart)
                }
            }
            if let hint = typedTimecodeHint {
                Text(hint)
                    .font(DesignTokens.Fonts.caption)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The sentence under the fields while the field being typed in holds text that is
    /// not a timecode (`SendActions.timecodeHint`). Only the field being typed in is
    /// asked: a field that is not shows the project's value, which is always a timecode.
    private var typedTimecodeHint: String? {
        guard let hint = actions?.timecodeHint else { return nil }
        switch typing {
        case .timelineStart: return hint(timelineStart)
        case .songStart: return hint(songStart)
        case nil: return nil
        }
    }

    /// The frame rate the picker shows. Choosing another one is reported.
    private var chosenFrameRate: Binding<String> {
        Binding(
            get: { frameRate },
            set: { rate in
                frameRate = rate
                if rate != content.frameRate {
                    actions?.frameRateChosen?(rate)
                }
            }
        )
    }

    /// One value of the Resolve project: what it is, and its field under that.
    private func value(_ title: String, @ViewBuilder field: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
            Text(title)
                .font(DesignTokens.Fonts.caption)
                .foregroundStyle(DesignTokens.Colors.textSecondary)
            field()
        }
    }

    private func timecodeField(_ name: String, text: Binding<String>, field: Field) -> some View {
        TextField(name, text: text)
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            .font(DesignTokens.Fonts.readout)
            .frame(width: DesignTokens.Sizes.timecodeFieldWidth)
            .accessibilityLabel(name)
            .focused($typing, equals: field)
            .onSubmit { report(field) }
    }
}

private extension View {
    /// Lets a clip's box or row be dragged out as the clip's exported file. It
    /// can be dragged only when the owner hands over the file
    /// (`SendActions.fileToDrag`), which is asked as the drag begins. Nil for
    /// the clip leaves it lying: a clip without a file yet.
    @ViewBuilder
    func draggable(as clip: SendContent.Clip?, with actions: SendActions?) -> some View {
        if let clip, let fileToDrag = actions?.fileToDrag {
            onDrag {
                // The file's place on disk, which Finder and DaVinci Resolve
                // both take. Nothing is handed over when there is no file.
                guard let url = fileToDrag(clip.id) else { return NSItemProvider() }
                return NSItemProvider(object: url as NSURL)
            }
        } else {
            self
        }
    }
}

extension SampleContent {
    /// Made-up content for the Send to DaVinci panel. With one clip it is the
    /// selected clip of `makeMainLayout()`, with its name and its Resolve
    /// start time. With more, the clips of that window follow, each a few
    /// seconds after the one before.
    ///
    /// - Parameters:
    ///   - script: What the panel says about the script in Resolve, made from
    ///     the clips. Left out, the script is ready.
    ///   - withSound: What the switch "With sound" stands at. On, every clip
    ///     was sent with its sound, except the fourth of a list, which stands
    ///     for a clip that has no Sound and no effect.
    public static func makeSend(
        clipCount: Int = 1,
        script: (([SendContent.Clip]) -> SendContent.ScriptStep)? = nil,
        withSound: Bool = true
    ) -> SendContent {
        let window = makeMainLayout()
        let song = window.timeline.songName
        let rows = window.timeline.trackRows
        let all = rows.flatMap { row in row.clips.map { (clip: $0, track: row.name) } }
        let selected = all.first(where: \.clip.isSelected)
        let others = all.filter { !$0.clip.isSelected }
        func twoDigits(_ value: Int) -> String { value < 10 ? "0\(value)" : "\(value)" }
        var clips: [SendContent.Clip] = []
        for index in 0..<max(clipCount, 1) {
            let source = index == 0 ? selected : (others.isEmpty ? selected : others[(index - 1) % others.count])
            // The first clip has the start time the window shows, 16 seconds into a timeline that starts at
            // 01:00:00:00 with 25 frames to the second. Each of the others starts 5 seconds and 12 frames later.
            let frames = 16 * 25 + index * 137
            let timecode = index == 0
                ? window.selectedClipResolveStart
                : "01:\(twoDigits(frames / 25 / 60)):\(twoDigits(frames / 25 % 60)):\(twoDigits(frames % 25))"
            let track = source?.track ?? "Track 1"
            clips.append(SendContent.Clip(
                // The same on every call, so the list keeps its rows when the panel is drawn again.
                id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0x5E, UInt8(index & 0xFF))),
                name: source?.clip.displayName ?? "",
                trackName: track,
                timecode: timecode,
                fileName: "\(song) - \(track) - \(timecode.replacingOccurrences(of: ":", with: ".")).wav"
            ))
        }
        for index in clips.indices {
            clips[index].isSentWithSound = withSound && index != 3
        }
        var content = SendContent(clips: clips, script: script?(clips))
        content.withSound = withSound
        return content
    }
}
