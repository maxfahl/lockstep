import Foundation
import Testing
@testable import LockstepCore

@Suite("TakeFlow")
struct TakeFlowTests {
    private let track = UUID()

    /// Record pressed at 30 s, with a run-up that starts at 28 s.
    private var origin: RecordOrigin {
        RecordOrigin(seconds: 30, trackID: track, runUpStart: 28)
    }

    /// A take that was started at `origin`, whose microphone and song are going.
    private func startedFlow() -> TakeFlow {
        var flow = TakeFlow()
        flow.record(from: origin)
        flow.started()
        return flow
    }

    // MARK: Record and Stop

    @Test("Record goes from stopped to running up, and to recording when the song reaches the origin")
    func recordRunsUpThenRecords() {
        var flow = TakeFlow()
        #expect(flow.phase == nil)
        #expect(!flow.isGoing)

        let didStart = flow.record(from: origin)
        #expect(didStart)
        #expect(flow.phase == .runningUp)
        #expect(flow.isGoing)
        #expect(flow.attempt == 1)
        #expect(flow.isStarting)
        flow.started()
        #expect(!flow.isStarting)

        // Still in the run-up just before the origin.
        flow.reach(29.99)
        #expect(flow.phase == .runningUp)
        flow.reach(30)
        #expect(flow.phase == .recording)
        // The song moving on changes nothing more.
        flow.reach(31)
        #expect(flow.phase == .recording)
    }

    @Test("At the very start of the song there is no run-up")
    func noRunUpAtTheStartOfTheSong() {
        var flow = TakeFlow()
        flow.record(from: RecordOrigin(seconds: 0, trackID: track, runUpStart: 0))
        #expect(flow.phase == .recording)
    }

    @Test("Record while a take is going changes nothing")
    func recordWhileGoingIsRefused() {
        var flow = startedFlow()
        let before = flow
        let didStart = flow.record(from: RecordOrigin(seconds: 5, trackID: UUID(), runUpStart: 3))
        #expect(!didStart)
        #expect(flow == before)
    }

    @Test("Stop goes to finishing, and the end goes back to stopped")
    func stopFinishesAndEnds() {
        var flow = startedFlow()
        flow.reach(30)
        let didStop = flow.stop()
        #expect(didStop)
        #expect(flow.phase == .finishing)
        #expect(!flow.isGoing)
        // A second stop has nothing to stop.
        let stoppedTwice = flow.stop()
        #expect(!stoppedTwice)
        flow.end()
        #expect(flow == TakeFlow())
        let stoppedAfterTheEnd = flow.stop()
        #expect(!stoppedAfterTheEnd)
    }

    // MARK: Restart

    @Test("A restart while recording goes back to running up")
    func restartWhileRecordingRunsUpAgain() {
        var flow = startedFlow()
        flow.reach(32)
        #expect(flow.phase == .recording)

        #expect(flow.restart() == origin)
        #expect(flow.phase == .runningUp)
        #expect(flow.attempt == 2)
        // The new attempt runs up and records like the first.
        flow.started()
        flow.reach(30)
        #expect(flow.phase == .recording)
    }

    @Test("A restart during the run-up starts the run-up again")
    func restartDuringTheRunUpRunsUpAgain() {
        var flow = startedFlow()
        flow.reach(29)
        #expect(flow.phase == .runningUp)

        #expect(flow.restart() == origin)
        #expect(flow.phase == .runningUp)
        #expect(flow.attempt == 2)
    }

    @Test("A restart where there is no run-up records again at once")
    func restartWithoutRunUpRecordsAtOnce() {
        var flow = TakeFlow()
        let start = RecordOrigin(seconds: 0, trackID: track, runUpStart: 0)
        flow.record(from: start)
        flow.started()
        #expect(flow.restart() == start)
        #expect(flow.phase == .recording)
    }

    @Test("A restart while stopped does nothing")
    func restartWhileStoppedDoesNothing() {
        var flow = TakeFlow()
        #expect(flow.restart() == nil)
        #expect(flow == TakeFlow())
    }

    @Test("A restart while the take is being finished does nothing")
    func restartWhileFinishingDoesNothing() {
        var flow = startedFlow()
        flow.stop()
        let before = flow
        #expect(flow.restart() == nil)
        #expect(flow == before)
    }

    @Test("A restart asked for while the start or another restart is under way is ignored")
    func restartWhileOneIsUnderWayIsIgnored() {
        var flow = TakeFlow()
        flow.record(from: origin)
        // Record has not opened the microphone yet.
        #expect(flow.restart() == nil)
        #expect(flow.attempt == 1)
        flow.started()

        #expect(flow.restart() == origin)
        // The key pressed again before the song is on its way.
        #expect(flow.restart() == nil)
        #expect(flow.attempt == 2)
        flow.started()
        // Once it is, the key works again.
        #expect(flow.restart() == origin)
        #expect(flow.attempt == 3)
    }

    @Test("The origin, the track and the run-up are unchanged after three restarts")
    func originIsUnchangedAfterThreeRestarts() {
        var flow = startedFlow()
        for position in [31.0, 28.5, 40.0] {
            flow.reach(position)
            #expect(flow.restart() == origin)
            flow.started()
        }
        #expect(flow.origin == origin)
        #expect(flow.origin?.seconds == 30)
        #expect(flow.origin?.trackID == track)
        #expect(flow.origin?.runUpStart == 28)
        #expect(flow.attempt == 4)
        #expect(flow.phase == .runningUp)
    }

    @Test("A take can be stopped while a restart is under way, and stays stopped")
    func stopDuringARestartStaysStopped() {
        var flow = startedFlow()
        #expect(flow.restart() == origin)
        let didStop = flow.stop()
        #expect(didStop)
        // The restart's answer arrives after the stop.
        flow.started()
        #expect(flow.phase == .finishing)
        #expect(flow.restart() == nil)
    }
}
