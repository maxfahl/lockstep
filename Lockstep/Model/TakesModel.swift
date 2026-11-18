import Foundation
import LockstepAudio
import LockstepCore
import LockstepUI

/// Choosing takes: a part of the app's model.
///
/// It holds choosing among the takes of a line: the list of takes in the panel on the right,
/// Next Take, Previous Take and Delete Other Takes.
///
/// Of the clips of one line on a track (`Clip.line`) only the active take is shown, with a count
/// such as 3/5 in its bar, and only it can be selected. The selection follows the line when
/// another take becomes the active one. The takes of the selected clip are listed in the panel on
/// the right, one row each, with the same playhead as the main timeline (`showTakes`). A press on
/// the count in a clip's bar selects that clip, so its takes are the ones listed
/// (`selectClip(withTakeCount:)`). A click on a row makes that take the active one
/// (`takeRowPressed`, the edit "Choose Take"), also while the song plays. Next Take and Previous
/// Take step the selected clip through its takes (`stepTake`), and Delete Other Takes keeps only
/// the one that is shown. Each row has a Play button, which is the transport's (`playOrStopTake`).
@MainActor
final class TakesModel {
    // The ground it is handed.
    private let windowState: WindowState
    private let selection: Selection
    private let loadedSounds: LoadedSounds
    private let takeStatus: TakeStatus
    private let store: ProjectStore

    // The parts it is handed, and calls directly.
    private let words: WordsModel
    /// A track's Voice: an edit keeps a part as loud as it was heard, in the voice of its track.
    private let voice: VoiceModel
    private let clipEditing: ClipEditingModel

    // What it asks of code that holds it, or of the model's routing. `wireTakes` sets them.
    /// Lets the player and the window follow the clips of a project (`followClips(of:)`, the clips'
    /// part).
    var followClips: (Project) -> Void = { _ in }

    /// Shows the clips of a project in the window, without telling the player (`showClips(of:)`,
    /// the clips' part).
    var showClips: (Project) -> Void = { _ in }

    /// Lets a take's Play button go on with the take that was just chosen for its line
    /// (`hearChosenTakes(_:)`, the transport, which holds this part).
    var hearChosenTakes: ([UUID]) -> Void = { _ in }

    init(
        windowState: WindowState,
        selection: Selection,
        loadedSounds: LoadedSounds,
        takeStatus: TakeStatus,
        store: ProjectStore,
        words: WordsModel,
        voice: VoiceModel,
        clipEditing: ClipEditingModel
    ) {
        self.windowState = windowState
        self.selection = selection
        self.loadedSounds = loadedSounds
        self.takeStatus = takeStatus
        self.store = store
        self.words = words
        self.voice = voice
        self.clipEditing = clipEditing
    }
}

extension TakesModel {
    // MARK: The takes of a line

    /// Gives the window the takes of the selected clip, for the list in the panel on the
    /// right: one row each, the one that a Play button is playing marked. With no clip
    /// selected, or several, or one that has no other takes, there are no rows.
    func showTakes(of project: Project, playing: UUID?) {
        var takeRows: [TakeRow] = []
        if selection.clipIDs.count == 1, let clipID = selection.clipIDs.first {
            takeRows = ShownClips.takeRows(
                ofLineWith: clipID, in: project, waveforms: loadedSounds.waveforms, playing: playing
            )
        }
        if windowState.content.timeline.takeRows != takeRows {
            windowState.content.timeline.takeRows = takeRows
        }
    }

    /// The take count in a clip's bar was pressed: the clip is selected, so its takes are
    /// the ones listed in the panel on the right. The window opens that panel if it is hidden.
    func selectClip(withTakeCount clipID: UUID) {
        guard let trackID = store.project.tracks.first(where: { $0.clips.contains { $0.id == clipID } })?.id,
            selection.clipIDs != [clipID] || selection.trackID != trackID
        else { return }
        selection.clipIDs = [clipID]
        selection.trackID = trackID
        showClips(store.project)
        clipEditing.clearMarkedStretch()
    }

    /// The take of the selected clip's line with this number, counted from 1 in the order
    /// they were recorded: what a row of the takes list stands for. Nil when not exactly one
    /// clip is selected, or its line has no such take.
    func take(numbered number: Int) -> Clip? {
        guard selection.clipIDs.count == 1, let shownID = selection.clipIDs.first else { return nil }
        let takes = store.project.takes(of: shownID)
        return takes.indices.contains(number - 1) ? takes[number - 1] : nil
    }

    /// A take's row in the takes list was clicked: that take becomes the active one, as one
    /// step that can be undone. It is the one shown on the track, selected, and heard. While
    /// the song plays, the player is handed the new take and the song plays on.
    func takeRowPressed(_ number: Int) {
        guard takeStatus.phase == nil, let chosen = take(numbered: number), !chosen.isActiveTake else { return }
        chooseTakes([chosen.id], named: "Choose Take")
        selection.clipIDs = [chosen.id]
        hearChosenTakes([chosen.id])
        followClips(store.project)
    }

    /// Makes these takes the ones shown for their lines, as one step that can be undone.
    ///
    /// A chosen take wins like a clip that was just recorded: what it covers of other lines
    /// on its track gives way in the same step (`Project.chooseTake`). The words of a clip
    /// that gave way are for more sound than it now plays, so they are taken away in the
    /// step and written out again after it.
    ///
    /// The takes are chosen in the order they start in the song. Two chosen takes that
    /// cover each other's lines then always come out the same way: the later one wins.
    private func chooseTakes(_ takes: [UUID], named title: String) {
        var changed = store.project
        func start(_ take: UUID) -> Double {
            store.project.clip(take).flatMap { store.project.start(of: $0) } ?? 0
        }
        for take in takes.sorted(by: { (start($0), $0.uuidString) < (start($1), $1.uuidString) }) {
            changed.chooseTake(take, peaks: voice.peaks, voices: voice.heard)
        }
        let cut = words.clearWordsOfCutClips(in: &changed)
        store.edit(title) { $0 = changed }
        words.writeOutWords(ofCutClips: cut)
    }

    /// Next Take (`step` 1) and Previous Take (`step` -1): the take recorded after, or
    /// before, the one that is shown becomes the active take of every selected clip that
    /// has other takes, going round at the ends, as one step that can be undone. What a
    /// take covers of other lines gives way in that step (`chooseTakes`). The
    /// selection moves with it. While the song plays, the player is handed the new take
    /// and the song plays on, so the takes can be compared by ear with the keys alone.
    func stepTake(by step: Int, _ command: AppCommand) {
        var chosen: [UUID: UUID] = [:]
        for id in selection.clipIDs {
            chosen[id] = step > 0 ? store.project.nextTake(of: id) : store.project.previousTake(of: id)
        }
        guard !chosen.isEmpty else { return }
        chooseTakes(Array(chosen.values), named: command.title)
        selection.clipIDs = Set(selection.clipIDs.map { chosen[$0] ?? $0 })
        hearChosenTakes(Array(chosen.values))
        followClips(store.project)
    }

    /// Delete Other Takes: of every selected clip that has other takes, only the take
    /// that is shown stays, as one step that can be undone. The recordings of the
    /// others stay in the project until it is closed, so Undo can bring them back.
    func deleteOtherTakes() {
        let ids = selection.clipIDs.filter { store.project.takeCount(of: $0) > 1 }
        guard takeStatus.phase == nil, !ids.isEmpty else { return }
        store.edit("Delete Other Takes") { project in
            for id in ids {
                project.deleteOtherTakes(of: id)
            }
        }
        followClips(store.project)
    }
}

extension AppModel {
    /// Gives `takes` its closures. `wire()` calls it once, when every part is made.
    func wireTakes() {
        takes.followClips = { [weak self] project in self?.clips.followClips(of: project) }
        takes.showClips = { [weak self] project in self?.clips.showClips(of: project) }
        takes.hearChosenTakes = { [weak self] chosen in self?.transport.hearChosenTakes(chosen) }
    }
}
