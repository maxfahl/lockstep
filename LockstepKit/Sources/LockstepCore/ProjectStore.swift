import Foundation
import Observation
import Synchronization

/// Holds the open project and is the only way to change it.
///
/// - `edit` is for everything Max does to the project. Each call is one step
///   that Command-Z takes back and Shift-Command-Z brings again.
/// - `setDerived` is for what Lockstep works out by itself (the beats it
///   finds). It is not an undo step.
/// - `open` puts another project in place and forgets the undo steps of the
///   old one.
///
/// Saving is by itself. A project that was opened together with its place on
/// disk is written there half a second after a change, and at once by
/// `close()`. There is no Save command. If writing fails, `saveFailed` is told
/// and the change stays in memory until a later save works.
///
/// The write half a second after a change is made away from the main thread:
/// turning a project of several hundred clips into text takes long enough to
/// make the window stand still (15 November 2026). `close()` and `open` write
/// on the thread they are called on and are done when they return, so Quit
/// waits for the project to be on disk. Every write goes through one line
/// (`ProjectWriteLine`), which lets one write finish before the next starts
/// and never puts an older project over a newer one.
///
/// The Edit menu shows `undoTitle` and `redoTitle` and calls `undo()` and
/// `redo()`. It does so whichever window has the keyboard, so Command-Z also
/// works from a popover, a sheet or a panel.
///
///     store.edit("Move Beat") { $0.grid?.anchors.append(anchor) }
///     store.undoTitle        // "Undo Move Beat"
///     store.undo()
@MainActor
@Observable
public final class ProjectStore {
    /// The open project. Views that read it are drawn again when it changes.
    public private(set) var project: Project

    /// Where the open project lies on disk, or nil for a project that is only
    /// in memory. Nothing is saved without it.
    public private(set) var package: ProjectPackage?

    /// The Edit menu's title for Undo, such as "Undo Move Beat", or nil when
    /// there is nothing to undo.
    public private(set) var undoTitle: String?
    /// The Edit menu's title for Redo, or nil when there is nothing to redo.
    public private(set) var redoTitle: String?

    /// Keeps the undo steps. Only the store registers steps with it.
    ///
    /// It does not group by event: left alone, an undo manager folds every
    /// step registered during one event into a single undo. Here every edit
    /// opens and closes a group of its own.
    @ObservationIgnored public let undoManager: UndoManager

    /// Rebuilds what is derived from the rest of the project: the beat list,
    /// refitted from the cache with the project's own inputs (anchors, tempo
    /// level, beat-one choice) and the settings as they are now.
    ///
    /// The store calls it after every undo and redo, because the copy that was
    /// put back may be older than the cache or the settings. It may even be
    /// from before the beats were found, with no grid at all.
    @ObservationIgnored public var rebuildDerived: ((inout Project) -> Void)?

    /// Called when the project could not be written to disk, with the reason.
    /// The changes are still in memory and the next change tries again.
    @ObservationIgnored public var saveFailed: ((any Error) -> Void)?

    /// How long after a change the project is written.
    @ObservationIgnored private let saveDelay: Duration
    /// The wait before the next write, while there is one.
    @ObservationIgnored private var pendingSave: Task<Void, Never>?
    /// True from a change until the project with that change is on disk.
    @ObservationIgnored private var hasUnsavedChanges = false
    /// Counts the changes of the project, so a write knows which change it holds. It only goes up.
    @ObservationIgnored private var changeNumber = 0
    /// What every write goes through.
    @ObservationIgnored private let writeLine = ProjectWriteLine()
    /// How many times the project was written to disk.
    @ObservationIgnored private(set) var saveCount = 0

    public init(project: Project = Project(), saveDelay: Duration = .milliseconds(500)) {
        // The store never holds a line with no active take or with two, from its first project on.
        var first = project
        first.normalizeTakes()
        first.normalizeEffects()
        self.project = first
        self.saveDelay = saveDelay
        undoManager = UndoManager()
        undoManager.groupsByEvent = false
    }

    /// Puts another project in place of the open one. The undo steps of the
    /// old project are forgotten.
    ///
    /// Changes of the old project that are still waiting are written first.
    /// `package` is where the new project lies and is saved from now on. Then
    /// what is derived is rebuilt, because what was saved may be older than
    /// the cache or the settings.
    ///
    /// The takes are put right as well (`normalizeTakes()`): a project saved
    /// before takes existed has clips on top of each other that are all
    /// active, and opens with the one recorded last as the active take. That
    /// alone is not written to disk. The next edit saves it.
    public func open(_ project: Project, in package: ProjectPackage? = nil) {
        saveNow()
        undoManager.removeAllActions()
        var opened = project
        rebuildDerived?(&opened)
        opened.normalizeTakes()
        opened.normalizeEffects()
        self.project = opened
        self.package = package
        // Whatever the old project still had unsaved is not this project's.
        hasUnsavedChanges = false
        readTitles()
    }

    /// Writes changes that are still waiting. Call it before Lockstep quits
    /// and when the window closes.
    public func close() {
        saveNow()
    }

    /// Takes the recordings that no clip uses out of the project, for when the
    /// project is closed, and hands them back so their files can be removed.
    ///
    /// A deleted clip keeps its recording as long as Undo can bring the clip
    /// back. So the undo steps are forgotten here as well: after this, nothing
    /// can ask for a recording that is gone. Call `close()` afterwards to write
    /// the project.
    @discardableResult
    public func forgetUnusedRecordings() -> [Recording] {
        undoManager.removeAllActions()
        readTitles()
        let unused = Set(project.unusedRecordingIDs())
        guard !unused.isEmpty else { return [] }
        let removed = project.recordings.filter { unused.contains($0.id) }
        project.recordings.removeAll { unused.contains($0.id) }
        hasUnsavedChanges = package != nil
        // A change like any other to the line of writes, or `close()` would take the project for the
        // one that is on disk already.
        changeNumber += 1
        return removed
    }

    /// Changes the project as one step that can be undone. `actionName` is
    /// what the Edit menu shows after "Undo", for example "Move Beat".
    ///
    /// After the change the takes are put right (`normalizeTakes()`), as part
    /// of the same step: a clip recorded as a new take of a line becomes its
    /// active take, and deleting the active take brings the latest of the rest
    /// forward. The effects are put right the same way (`normalizeEffects()`):
    /// an effect on a stretch that the change cut away is gone, and one that
    /// was cut into covers what is left. Undo puts back the project as it was before, which was right
    /// too, so no step can leave a line with no active take or with two.
    public func edit(_ actionName: String, _ change: (inout Project) -> Void) {
        let before = project
        // Changed on the side and put in place once, so nothing that watches
        // the project sees it between the change and the takes being put right.
        var changed = project
        change(&changed)
        changed.normalizeTakes()
        // And every effect on a stretch is cut down to what its clip still plays (`normalizeEffects()`).
        changed.normalizeEffects()
        project = changed
        registerStep(backTo: before, actionName)
        readTitles()
        saveSoon()
    }

    /// Changes the project without making an undo step. For what Lockstep
    /// works out by itself, such as the beats it finds.
    public func setDerived(_ change: (inout Project) -> Void) {
        change(&project)
        saveSoon()
    }

    /// Takes back the last edit. Does nothing when there is none.
    public func undo() {
        guard undoManager.canUndo else { return }
        undoManager.undo()
        readTitles()
        saveSoon()
    }

    /// Brings back the edit that was last undone. Does nothing when there is none.
    public func redo() {
        guard undoManager.canRedo else { return }
        undoManager.redo()
        readTitles()
        saveSoon()
    }

    // MARK: Saving

    /// Notes that the project has changed and has it written after `saveDelay`.
    /// A change made while a write is already waiting rides along with it, so
    /// several quick changes give one write, and none waits longer than the delay.
    private func saveSoon() {
        guard package != nil else { return }
        hasUnsavedChanges = true
        changeNumber += 1
        guard pendingSave == nil else { return }
        pendingSave = Task { [weak self, saveDelay] in
            try? await Task.sleep(for: saveDelay)
            guard !Task.isCancelled else { return }
            await self?.saveAway()
        }
    }

    /// The write that comes by itself after a change: the project as it is now is written away from the
    /// main thread, and the store hears how it went when it is done.
    ///
    /// A change made while it is being written is not in it. That change has asked for a write of its own
    /// (`saveSoon`), and the project stays unsaved until that one is done.
    private func saveAway() async {
        pendingSave = nil
        guard hasUnsavedChanges, let package else { return }
        let number = changeNumber
        let result = await Self.write(project, numbered: number, to: package, through: writeLine)
        switch result {
        case .success(let wasWritten):
            if wasWritten { saveCount += 1 }
            // Only when nothing has changed since, and the same project is still open.
            if changeNumber == number, self.package == package {
                hasUnsavedChanges = false
            }
        case .failure(let error):
            saveFailed?(error)
        }
    }

    /// Writes a project away from the main thread. Whether it was written, or left because a newer one
    /// was written already.
    @concurrent
    private nonisolated static func write(
        _ project: Project,
        numbered number: Int,
        to package: ProjectPackage,
        through line: ProjectWriteLine
    ) async -> Result<Bool, any Error> {
        Result { try line.write(project, numbered: number, to: package) }
    }

    /// Writes the project if it has changes that are not on disk yet, and is done when it returns. After a
    /// failed write the changes still count as unsaved, so the next change, or `close()`, tries again.
    ///
    /// A write that is going on away from the main thread is waited for first. When that one wrote the
    /// project as it is now, nothing is written twice.
    private func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        guard hasUnsavedChanges, let package else { return }
        do {
            if try writeLine.write(project, numbered: changeNumber, to: package) {
                saveCount += 1
            }
            hasUnsavedChanges = false
        } catch {
            saveFailed?(error)
        }
    }

    /// Registers one step that puts `snapshot` back. When the step runs, it
    /// registers its own opposite the same way: while undoing, the undo
    /// manager files that as the redo step, and while redoing as the undo step.
    private func registerStep(backTo snapshot: Project, _ actionName: String) {
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: self) { store in
            let current = store.project
            var restored = snapshot
            store.rebuildDerived?(&restored)
            store.project = restored
            store.registerStep(backTo: current, actionName)
        }
        undoManager.setActionName(actionName)
        undoManager.endUndoGrouping()
    }

    private func readTitles() {
        undoTitle = undoManager.canUndo ? undoManager.undoMenuItemTitle : nil
        redoTitle = undoManager.canRedo ? undoManager.redoMenuItemTitle : nil
    }
}

/// The one line every write of a project goes through, from whichever thread it is made.
///
/// One write is finished before the next starts, and a project is never written over a newer one: each
/// write carries the number of the change it holds, and a write whose number is not higher than the last
/// one written is left out. So when Quit writes the project while the write that came by itself is still
/// going on, Quit waits for that one, and then writes only if it has something newer.
final class ProjectWriteLine: Sendable {
    /// The number of the newest change that is on disk, by the folder it was written to.
    private let newest = Mutex<[URL: Int]>([:])

    /// - Returns: false when a change with this number or a higher one was written to the same place
    ///   already. Nothing is written then.
    func write(_ project: Project, numbered number: Int, to package: ProjectPackage) throws -> Bool {
        try newest.withLock { newest in
            guard number > newest[package.url] ?? .min else { return false }
            try package.write(project)
            newest[package.url] = number
            return true
        }
    }
}
