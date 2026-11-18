import Foundation
import LockstepCore
import LockstepUI
import Observation

/// Copy Sound and Paste Sound: a part of the app's model.
///
/// It holds the copied sound: how one clip, or one track, sounded when Copy Sound was chosen (its
/// Sound with the four knobs as they were heard, and the kind and level of every effect on the whole
/// clip). It is kept for as long as Lockstep runs, beside the copied clips and apart from them, and
/// names nothing of the project it came from, so it can be pasted in another project.
///
/// What it acts on is what is selected: one clip, or else the selected track, for Copy Sound; the
/// selected clips, or else the selected track, for Paste Sound. A paste is one step that can be
/// undone, "Paste Sound". The rules are in `ProjectSoundCopy.swift` in LockstepCore, where they are
/// tested.
///
/// What the commands call: `canCopySound`, `copySound()`, `canPasteSound`, `pasteSound()`. A clip's
/// right-click menu copies from the clip that was right-clicked (`copySound(ofClip:)`). In an agent's
/// run, `-pasteSound clips` or `-pasteSound track` comes through `pasteLaunchSound()`.
@MainActor
@Observable
final class SoundCopyModel {
    // The ground it is handed.
    @ObservationIgnored private let windowState: WindowState
    @ObservationIgnored private let selection: Selection
    @ObservationIgnored private let loadedSounds: LoadedSounds
    @ObservationIgnored private let takeStatus: TakeStatus
    @ObservationIgnored private let store: ProjectStore

    // What it asks of code that holds it. `wireSoundCopy` sets it.
    /// Lets the player and the window follow the clips of a project (`followClips(of:)`, the clips'
    /// part).
    @ObservationIgnored var followClips: (Project) -> Void = { _ in }

    /// The copied sound, or nil until Copy Sound was chosen once. The menus read it to know whether
    /// Paste Sound can act.
    private(set) var copied: CopiedSound?

    /// The note this part put in the window's message banner, and what takes it away again.
    @ObservationIgnored private var note: String?
    @ObservationIgnored private var noteLeaves: Task<Void, Never>?
    /// How long the note stays, in seconds.
    private static let noteSeconds = 8.0

    init(
        windowState: WindowState,
        selection: Selection,
        loadedSounds: LoadedSounds,
        takeStatus: TakeStatus,
        store: ProjectStore
    ) {
        self.windowState = windowState
        self.selection = selection
        self.loadedSounds = loadedSounds
        self.takeStatus = takeStatus
        self.store = store
    }
}

extension SoundCopyModel {
    // MARK: What is selected

    /// What a command acts on.
    private enum Target {
        case clips(Set<UUID>)
        case track(UUID)
    }

    /// What is selected: the selected clips, or with none the selected track. Nil without a song, and
    /// while the song is selected, whose panel shows neither.
    private var target: Target? {
        guard loadedSounds.song != nil, !loadedSounds.isOpening else { return nil }
        let clips = Set(store.project.clips(selection.clipIDs).map(\.id))
        if !clips.isEmpty { return .clips(clips) }
        guard !selection.songIsSelected, let trackID = selection.recordingTrackID else { return nil }
        return .track(trackID)
    }

    // MARK: Copy Sound

    /// Whether Copy Sound has a sound to copy: one clip is selected, or no clip and a track.
    var canCopySound: Bool {
        switch target {
        case .clips(let ids): ids.count == 1
        case .track: true
        case nil: false
        }
    }

    /// Copy Sound: how the selected clip sounds is kept for Paste Sound, or, with no clip selected, the
    /// selected track's Sound and effects. Nothing in the project changes.
    func copySound() {
        switch target {
        case .clips(let ids):
            guard ids.count == 1, let id = ids.first else { return }
            copySound(ofClip: id)
        case .track(let id):
            guard let sound = store.project.copiedSound(ofTrack: id) else { return }
            copied = sound
        case nil:
            break
        }
    }

    /// Copy Sound in a clip's right-click menu: how that clip sounds is kept, also when it is one of
    /// several selected clips.
    func copySound(ofClip clipID: UUID) {
        guard loadedSounds.song != nil, let sound = store.project.copiedSound(ofClip: clipID) else { return }
        copied = sound
    }

    // MARK: Paste Sound

    /// Whether Paste Sound can act: a sound was copied, and clips or a track are selected.
    var canPasteSound: Bool {
        copied != nil && target != nil
    }

    /// Paste Sound: the selected clips are made to sound like the copied sound, or, with no clip
    /// selected, the selected track gets it and every clip of the track follows the track. One step that
    /// can be undone. Nothing happens during a take.
    ///
    /// A clip cannot have another Sound than its track. Where a selected clip's track has another Sound
    /// than the copied one, or none, the knobs and effects are pasted all the same and the window's
    /// message banner says that the track's Sound is still its own.
    func pasteSound() {
        guard takeStatus.phase == nil, let copied, let target else { return }
        var changed = store.project
        switch target {
        case .clips(let ids):
            let keepsItsSound = changed.hasAnotherSound(than: copied, onTracksOf: ids)
            if changed.pasteSound(copied, onClips: ids) {
                // An effect that was added has a new id, so the project that was tried is the one kept.
                store.edit("Paste Sound") { $0 = changed }
            }
            followClips(store.project)
            if keepsItsSound {
                say(Self.trackKeepsItsSound(clips: ids.count, copied: copied))
            }
        case .track(let id):
            if changed.pasteSound(copied, onTrack: id) {
                store.edit("Paste Sound") { $0 = changed }
            }
            followClips(store.project)
        }
    }

    /// What the banner says after a paste on clips whose track has another Sound than the copied one.
    private static func trackKeepsItsSound(clips count: Int, copied: CopiedSound) -> String {
        let got = copied.sound == nil
            ? (count == 1 ? "The clip got the effects." : "The clips got the effects.")
            : (count == 1 ? "The clip got the knobs and the effects." : "The clips got the knobs and the effects.")
        return got + " The track's Sound is still its own: to change it, select the track and choose Paste Sound."
    }

    /// Shows a note in the window's message banner and takes it away again some seconds later, unless
    /// something else is said there by then. Another message that is showing is left alone: it is
    /// about something that matters more.
    private func say(_ text: String) {
        guard windowState.content.message == nil || windowState.content.message == note else { return }
        note = text
        windowState.content.message = text
        noteLeaves?.cancel()
        noteLeaves = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.noteSeconds))
            guard !Task.isCancelled, let self, self.windowState.content.message == text else { return }
            self.windowState.content.message = nil
        }
    }
}

extension SoundCopyModel {
    // MARK: For an agent's run

    /// Does what `-pasteSound` asks and says on standard error how it went. The Sound's part calls it
    /// as the last step of what an agent's run asked of a clip's sound (`SoundModel.soundLaunchTrack`),
    /// so the sound that is copied has the Sound, the knob and the effects of that run.
    func pasteLaunchSound() async {
        guard let asked = LaunchOptions.current.pasteSound else { return }
        Agent.tell(pasteSoundForAgent(on: asked))
    }

    /// Copies the sound of the first clip of the first track and pastes it on every other shown clip
    /// of that track, or on the track itself, by selecting what the commands act on and calling what
    /// they call. Gives the line that says how it went.
    private func pasteSoundForAgent(on asked: LaunchOptions.PasteSoundTarget) -> String {
        let refusal = "could not paste the sound of the first clip: "
        guard loadedSounds.song != nil, !loadedSounds.isOpening, takeStatus.phase == nil,
              let track = store.project.tracks.first
        else { return refusal + "the song is not ready" }
        let shown = track.clips.filter(\.isActiveTake)
        guard let first = shown.first else { return refusal + "the first track has no clip" }
        let others = Set(shown.dropFirst().map(\.id))
        if asked == .clips, others.isEmpty { return refusal + "the first track has no other clip" }

        selection.trackID = track.id
        selection.clipIDs = [first.id]
        guard canCopySound else { return refusal + "Copy Sound cannot act" }
        copySound()
        guard let copied else { return refusal + "Copy Sound copied nothing" }
        selection.clipIDs = asked == .clips ? others : []
        guard canPasteSound else { return refusal + "Paste Sound cannot act" }
        let before = store.project
        pasteSound()

        let after = store.project.track(track.id)
        let was = Dictionary(uniqueKeysWithValues: (before.track(track.id)?.clips ?? []).map { ($0.id, $0) })
        let changed = (after?.clips ?? []).filter { $0.isActiveTake && was[$0.id] != $0 }.count
        func percent(_ value: Double) -> Int { Int((value * 100).rounded()) }
        var line = "copied the sound of the first clip of the track \"\(track.name)\": "
        if let sound = copied.sound {
            line += "the Sound \"\(sound.name)\" with squeeze \(percent(sound.knobs.squeeze)) %, "
                + "tone \(percent(sound.knobs.tone)) %, warmth \(percent(sound.knobs.warmth)) %, "
                + "space \(percent(sound.knobs.space)) %"
        } else {
            line += "no Sound"
        }
        let effects = copied.effects.map { effect in
            effect.kind.isLayer ? String(format: "%@ at %.1f dB", effect.kind.menuName, effect.levelDb) : effect.kind.menuName
        }
        line += effects.isEmpty ? ", no effect" : ", \(effects.count == 1 ? "the effect" : "the effects") "
            + effects.joined(separator: ", ")
        switch asked {
        case .clips:
            line += ", and pasted it on the \(others.count) other \(others.count == 1 ? "clip" : "clips") of the track: "
        case .track:
            let effectCount = after?.effects.count ?? 0
            line += ", and pasted it on the track, which has "
                + (after?.sound.map { "the Sound \"\($0.name)\"" } ?? "no Sound")
                + " and \(effectCount) \(effectCount == 1 ? "effect" : "effects"): "
        }
        return line + "\(changed) \(changed == 1 ? "clip was" : "clips were") changed, undo step: \(store.undoTitle ?? "none")"
    }
}

extension AppModel {
    /// Gives `soundCopy` its closure. `wire()` calls it once, when every part is made.
    func wireSoundCopy() {
        soundCopy.followClips = { [weak self] project in self?.clips.followClips(of: project) }
    }
}
