import Foundation
import LockstepAudio
import LockstepCore
import LockstepUI

/// The loop commands: a part of the app's model.
///
/// It holds the loop commands: Loop on and off, setting the in and the out, clearing them, and
/// `-loop` with `-loopTake`. The loop itself is ground (`LoopState`).
@MainActor
final class LoopModel {
    // The ground it is handed.
    private let selection: Selection
    private let loadedSounds: LoadedSounds
    private let takeStatus: TakeStatus
    private let loopState: LoopState
    private let store: ProjectStore
    private let settings: AppSettings
    private let playhead: PlayheadPosition

    /// What is kept for Loop between two calls.
    let loopWork = LoopWork()
    /// `loopWork.stretchIsNewer`, for the parts that are handed this one.
    var stretchIsNewer: Bool {
        get { loopWork.stretchIsNewer }
        set { loopWork.stretchIsNewer = newValue }
    }

    // What it asks of code that holds it, or of the model's routing. `wireLoop` sets them.
    /// Takes the marked stretch away once Loop has taken it over (`clearMarkedStretch()`, clip
    /// editing, which holds this part).
    var clearMarkedStretch: () -> Void = {}

    /// Makes the passes of a finished loop recording into takes on a track and gives their clips
    /// (`keep(_:on:)`, the transport, which holds this part). Only `-loopTake` calls it.
    var keep: (FinishedPasses, UUID) -> [UUID] = { _, _ in [] }

    init(
        selection: Selection,
        loadedSounds: LoadedSounds,
        takeStatus: TakeStatus,
        loopState: LoopState,
        store: ProjectStore,
        settings: AppSettings,
        playhead: PlayheadPosition
    ) {
        self.selection = selection
        self.loadedSounds = loadedSounds
        self.takeStatus = takeStatus
        self.loopState = loopState
        self.store = store
        self.settings = settings
        self.playhead = playhead
    }
}

// Loop: a stretch of the song that repeats. The region that plays is `LoopState.region`, and
// its in and out are `LoopState.inOut`.
//
// In and out: Set Loop In (I) puts the in at the playhead, Set Loop Out (O) the out, exactly
// where it stands, as in DaVinci Resolve. They are a thing of their own, apart from the
// marked stretch and from the selection: selecting clips, marking or deleting a stretch,
// Escape and Delete leave them alone, and only Clear Loop In and Out (Option+X) takes them
// away, switching Loop off with them. An end that is not set is the start or the end of what
// is left of the song, and so is the other end when the new one reaches or passes it
// (`LoopInOut.setting`). While Loop is off the ruler shows them, quieter than a loop that
// plays and never over the rows; while it is on, I and O move the ends of the loop that plays.
// They are not part of the project and no undo step, and they are kept in `view.json` with the
// rest of the view (the view's memory in `TimelineViewModel`), so they come back after a restart.
//
// Switching it on: Loop (the button in the bar, Transport > Loop, or L) loops the in and out
// exactly where they are. A stretch marked by dragging after the in and out were last set is
// looped instead, with its start moved back and its end moved forward to the nearest bar
// starts (`LoopRegion.snapped`); the marked stretch is then cleared, and the loop's ends become
// the in and out. While Loop is on, the in and out are the ends of the loop (`LoopState.region`'s
// `didSet`). The marked stretch and the selection have nothing to do with the loop: Delete can
// never cut the looped stretch out of the takes.
//
// Switching it off: the loop stops and its ends stay as the in and out, so Loop switches the
// same loop on again.
//
// A loop and its in and out lie in what is left of the song: bar starts are looked for there
// only, and a cut of the song made afterwards shortens them or takes them away
// (`keepLoopAndStretch`, in `SongPlaceModel`).
//
// Playing: the player loops by itself (`PlaybackEngine.setLoop`). Play inside or before the
// region goes round in it, and a click after the region plays on to the end of the song.
//
// The loop itself is not saved: Undo does not bring it back, a project opens with Loop off,
// and another song starts without one. A loop that is on keeps its length also when the beats
// are corrected afterwards: every pass is the number of samples it was switched on with.
//
// Marking: while a stretch is dragged with snapping on, each of its ends catches on a bar
// start that is near (`snappedToBarStart`), so what is marked is already whole bars.
extension LoopModel {
    /// The loop region a marked stretch becomes: whole bars where the song has beats, and
    /// never outside what is left of the song.
    private func loopRegion(for stretch: ClosedRange<Double>) -> LoopRegion? {
        LoopRegion.snapped(stretch, to: store.project.grid, keeping: store.project.keptSamples)
    }

    /// The loop region a stretch becomes exactly as it is, with no rounding to bars: what
    /// I and O gave. Nil when it is shorter than the player loops.
    private func exactLoopRegion(for stretch: ClosedRange<Double>) -> LoopRegion? {
        LoopRegion(from: stretch.lowerBound, to: stretch.upperBound, keeping: store.project.keptSamples)
    }

    /// Whether Loop, switched on now, would loop the marked stretch rather than the in and out.
    private var loopsMarkedStretch: Bool {
        selection.markedStretch != nil && (loopWork.stretchIsNewer || loopState.inOut == nil)
    }

    /// The loop region Loop would play if it were switched on now.
    private var loopRegionToSwitchOn: LoopRegion? {
        if loopsMarkedStretch, let stretch = selection.markedStretch {
            return loopRegion(for: stretch.range)
        }
        guard let range = loopState.inOut?.range(in: store.project.keptSeconds) else { return nil }
        return exactLoopRegion(for: range)
    }

    /// Whether Loop can be switched on right now: the in and out are set or a stretch is
    /// marked, and what they hold is long enough to be looped. The menu and the command ask this.
    var canTurnLoopOn: Bool {
        guard loadedSounds.song != nil, !loadedSounds.isOpening else { return false }
        return loopRegionToSwitchOn != nil
    }

    /// Loop: switches Loop on for the in and out, or for a stretch marked after them, or off
    /// when it is on. Switching it off keeps the in and out. Nothing in the project changes,
    /// so it is no undo step.
    func toggleLoop() {
        // A take is tied to the loop it was started in.
        guard takeStatus.phase == nil else { return }
        if loopState.region != nil {
            loopState.region = nil
            return
        }
        let fromStretch = loopsMarkedStretch
        guard let region = loopRegionToSwitchOn else { return }
        // Its ends become the in and out (`LoopState.region`'s `didSet`).
        loopState.region = region
        if fromStretch {
            clearMarkedStretch()
        }
    }

    /// Set Loop In and Set Loop Out: one end of the in and out goes to the playhead, exactly
    /// where it stands. While Loop is on, the loop that plays changes at once.
    func setLoopEnd(_ end: LoopInOut.End) {
        guard loadedSounds.song != nil, !loadedSounds.isOpening, takeStatus.phase == nil else { return }
        // The playhead cannot stand where the song is cut away, but a cut made after it was
        // put there can leave it outside: `setting` puts the end at the edge of what is left.
        let kept = store.project.keptSeconds
        guard let marks = (loopState.inOut ?? LoopInOut()).setting(end, at: playhead.seconds, in: kept) else { return }
        loopWork.stretchIsNewer = false
        if loopState.region != nil {
            // Too short to go round: Loop goes off, and the new ends are kept, so the other
            // end can be moved before Loop is switched on again.
            loopState.region = marks.range(in: kept).flatMap(exactLoopRegion(for:))
        }
        // Set after the loop, whose ends are whole samples, so they are where the playhead is.
        loopState.inOut = marks
    }

    /// Clear Loop In and Out: the in and out go and Loop is switched off. A marked stretch stays.
    func clearLoopInAndOut() {
        guard takeStatus.phase == nil else { return }
        loopState.region = nil
        loopState.inOut = nil
    }

    // MARK: For an agent

    /// Switches Loop on for the stretch given with `-loop`, once the beats of the first
    /// song are known and the takes given with `-addTake` are in, and says on standard
    /// error which region it became. An agent that checks the app cannot drag across a track.
    ///
    /// - Parameter beatsWereFound: false when the beats could not be found. The stretch is
    ///   then looped as it was given, and the line says so.
    func turnLaunchLoopOn(beatsWereFound: Bool = true) {
        let work = loopWork
        guard !work.launchTaken, let stretch = LaunchOptions.current.loop else { return }
        work.launchTaken = true
        work.launch = Task { [weak self] in
            // Until the takes are added nothing else may change.
            await self?.takeStatus.ended()
            guard let self else { return }
            let asked = String(format: "%.3f s to %.3f s", stretch.lowerBound, stretch.upperBound)
            guard loadedSounds.song != nil, takeStatus.phase == nil, let region = loopRegion(for: stretch) else {
                Self.tellAgentAboutLoop("could not loop \(asked): the stretch is outside what is left of the song or shorter than 0.25 s")
                return
            }
            // Its ends become the in and out, as when Loop is switched on by hand.
            loopState.region = region
            Self.tellAgentAboutLoop(
                "looping from "
                    + String(format: "%.6f s to %.6f s", region.start, region.end)
                    + ", samples \(region.startSample) to \(region.endSample), \(region.lengthSamples) samples a pass"
                    + ", asked for \(asked)"
                    + (beatsWereFound ? "" : ", used as given because the beats could not be found")
            )
            await addLaunchLoopTake(in: region)
        }
    }

    /// Adds the sound file given with `-loopTake` as a loop recording in the loop that `-loop`
    /// switched on, on the selected track, and says on standard error where each time round
    /// landed. The file is treated as what the microphone heard from the loop's start on, with
    /// the count-in off. No microphone is opened: an agent can check the takes of a loop
    /// recording from the saved project.
    private func addLaunchLoopTake(in region: LoopRegion) async {
        guard let url = LaunchOptions.current.loopTake else { return }
        guard let package = store.package, let trackID = selection.trackID ?? store.project.tracks.first?.id else {
            Self.tellAgentAboutLoop("could not add the loop take \(url.path): no project is open")
            return
        }
        let counted = TakeCountIn(
            loopingFrom: region,
            bars: 0,
            in: store.project,
            accentBeatOne: settings[.accentBeatOne],
            delays: [:]
        )
        do {
            let finished = try await FinishedPasses.make(fromFile: url, countedIn: counted, in: package)
            let clipIDs = keep(finished, trackID)
            guard !clipIDs.isEmpty else {
                Self.tellAgentAboutLoop("did not add the loop take \(url.path): nothing in it became a take")
                return
            }
            if !finished.isLoopRecording {
                Self.tellAgentAboutLoop("the loop never came round in \(url.path): it was added as one ordinary take")
            }
            for (number, clipID) in clipIDs.enumerated() {
                guard let clip = store.project.clip(clipID), let start = store.project.start(of: clip),
                    let end = store.project.end(of: clip)
                else { continue }
                Self.tellAgentAboutLoop(
                    "added pass \(number + 1) of \(clipIDs.count) of the loop take \(url.path) as a clip from "
                        + String(format: "%.3f s to %.3f s", start, end)
                        + ", take \(store.project.takeNumber(of: clipID) ?? 1)"
                        + " of \(store.project.takeCount(of: clipID))"
                        + (clip.isActiveTake ? ", the active take" : "")
                )
            }
        } catch {
            Self.tellAgentAboutLoop("could not add the loop take \(url.path): \(error.message)")
        }
    }

    /// Waits until what `-loop` asked for is done. Returns at once when it was not given,
    /// or when the beats are not found yet.
    func launchLoopIsOn() async {
        await loopWork.launch?.value
    }

    /// One line on standard error, for the agent that started Lockstep.
    static func tellAgentAboutLoop(_ line: String) {
        FileHandle.standardError.write(Data("Lockstep: \(line)\n".utf8))
    }
}

/// What is kept for Loop between two calls.
@MainActor
final class LoopWork {
    /// True while the marked stretch was marked after the in and out were last set, so Loop
    /// loops the stretch and not them. A drag that marks a stretch makes it true, I and O
    /// make it false.
    var stretchIsNewer = false
    /// True once the stretch given with `-loop` was looped, or could not be.
    var launchTaken = false
    /// The switching on that `-loop` asked for, while it waits for the takes of `-addTake`.
    var launch: Task<Void, Never>?
}

extension AppModel {
    /// Gives `loop` its closures. `wire()` calls it once, when every part is made.
    func wireLoop() {
        loop.clearMarkedStretch = { [weak self] in self?.clipEditing.clearMarkedStretch() }
        loop.keep = { [weak self] finished, trackID in self?.transport.keep(finished, on: trackID) ?? [] }
    }
}
