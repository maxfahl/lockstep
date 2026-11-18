import Foundation
import Testing
@testable import LockstepCore

@Suite("ProjectStore")
@MainActor
struct ProjectStoreTests {
    /// A store with a song whose beats are found: eight beats, half a second apart.
    private func makeStore() -> ProjectStore {
        let beats = (0..<8).map { Beat(number: $0, time: Double($0) * 0.5, estimated: false) }
        let grid = Grid(beats: beats, barStartNumber: 0, anchors: [], tempoLevel: .normal, beatOne: nil)
        let store = ProjectStore(project: Project(songName: "Song", songLengthSamples: 192_000, grid: grid))
        store.undoManager.groupsByEvent = false
        return store
    }

    /// The whole project as text, so two projects can be compared field by field.
    private func text(_ project: Project) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(project), as: UTF8.self)
    }

    @Test func anEditChangesTheProject() {
        let store = makeStore()
        store.edit("Halve Tempo") { $0.grid?.tempoLevel = .halved }
        #expect(store.project.grid?.tempoLevel == .halved)
        #expect(store.undoTitle == "Undo Halve Tempo")
        #expect(store.redoTitle == nil)
    }

    @Test func undoRestoresTheOldValueExactlyAndRedoReappliesIt() throws {
        let store = makeStore()
        let before = try text(store.project)
        store.edit("Move Beat") { project in
            project.grid?.anchors.append(Anchor(from: 1.5, to: 1.52))
            project.grid?.beats[3].time = 1.52
        }
        let after = try text(store.project)
        #expect(after != before)

        store.undo()
        #expect(try text(store.project) == before)
        #expect(store.undoTitle == nil)
        #expect(store.redoTitle == "Redo Move Beat")

        store.redo()
        #expect(try text(store.project) == after)
        #expect(store.undoTitle == "Undo Move Beat")
        #expect(store.redoTitle == nil)

        store.undo()
        #expect(try text(store.project) == before)
    }

    @Test func threeEditsUndoOneAtATimeInReverseOrder() throws {
        let store = makeStore()
        var states = [try text(store.project)]
        store.edit("Move Beat") { $0.grid?.anchors.append(Anchor(from: 1.0, to: 1.01)) }
        states.append(try text(store.project))
        store.edit("This Is Beat 1") { $0.grid?.beatOne = 0.5 }
        states.append(try text(store.project))
        store.edit("Double Tempo") { $0.grid?.tempoLevel = .doubled }
        states.append(try text(store.project))

        #expect(store.undoTitle == "Undo Double Tempo")
        store.undo()
        #expect(try text(store.project) == states[2])
        #expect(store.undoTitle == "Undo This Is Beat 1")
        store.undo()
        #expect(try text(store.project) == states[1])
        #expect(store.undoTitle == "Undo Move Beat")
        store.undo()
        #expect(try text(store.project) == states[0])
        #expect(store.undoTitle == nil)

        // And forward again, one at a time, in the order they were made.
        store.redo()
        #expect(try text(store.project) == states[1])
        store.redo()
        #expect(try text(store.project) == states[2])
        store.redo()
        #expect(try text(store.project) == states[3])
        #expect(store.redoTitle == nil)
    }

    @Test func aNewEditAfterAnUndoDropsTheRedo() {
        let store = makeStore()
        store.edit("Halve Tempo") { $0.grid?.tempoLevel = .halved }
        store.undo()
        store.edit("Double Tempo") { $0.grid?.tempoLevel = .doubled }
        #expect(store.redoTitle == nil)
        store.redo()
        #expect(store.project.grid?.tempoLevel == .doubled)
    }

    /// The beat list is rebuilt from the inputs and the settings as they are
    /// at the moment of the undo, not taken from the old copy.
    @Test func undoingAnEditMadeBeforeASettingsChangeLeavesAGridThatMatchesTheSettings() {
        let store = makeStore()
        // Stands in for the refit: the "setting" is the spacing of the beats,
        // and each anchor moves the first beat.
        final class Settings { var spacing = 0.5 }
        let settings = Settings()
        func refit(_ project: inout Project) {
            guard var grid = project.grid else { return }
            let shift = grid.anchors.reduce(0) { $0 + ($1.to - $1.from) }
            grid.beats = (0..<8).map { Beat(number: $0, time: shift + Double($0) * settings.spacing, estimated: false) }
            project.grid = grid
        }
        store.rebuildDerived = refit

        store.edit("Move Beat") { project in
            project.grid?.anchors.append(Anchor(from: 0, to: 0.25))
            refit(&project)
        }
        #expect(store.project.grid?.beats.map(\.time) == [0.25, 0.75, 1.25, 1.75, 2.25, 2.75, 3.25, 3.75])

        // The setting changes after the edit. That is not an edit.
        settings.spacing = 1
        store.setDerived(refit)
        #expect(store.undoTitle == "Undo Move Beat")

        store.undo()
        #expect(store.project.grid?.anchors.isEmpty == true)
        #expect(store.project.grid?.beats.map(\.time) == [0, 1, 2, 3, 4, 5, 6, 7])

        store.redo()
        #expect(store.project.grid?.anchors.count == 1)
        #expect(store.project.grid?.beats.map(\.time) == [0.25, 1.25, 2.25, 3.25, 4.25, 5.25, 6.25, 7.25])
    }

    @Test func whatLockstepWorksOutItselfIsNotAnUndoStep() {
        let store = makeStore()
        store.setDerived { $0.grid?.barStartNumber = 2 }
        #expect(store.project.grid?.barStartNumber == 2)
        #expect(store.undoTitle == nil)
        store.undo()
        #expect(store.project.grid?.barStartNumber == 2)
    }

    @Test func openingAnotherProjectForgetsTheUndoSteps() {
        let store = makeStore()
        store.edit("Halve Tempo") { $0.grid?.tempoLevel = .halved }
        store.open(Project(songName: "Other"))
        #expect(store.undoTitle == nil)
        store.undo()
        #expect(store.project.songName == "Other")
        #expect(store.project.grid == nil)
    }
}
