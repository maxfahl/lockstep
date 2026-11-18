import Foundation
import Testing
@testable import LockstepCore

/// Moving recordings back by the measured delay, worked out with numbers alone: no sound device, no settings
/// file. The delays that would come from the settings are handed in as a small table.
@Suite("Recordings are moved back by the measured delay")
@MainActor
struct ProjectDelaysTests {
    static let wired = DevicePair(
        outputUID: "BuiltInHeadphoneOutputDevice", outputName: "External Headphones",
        inputUID: "AppleUSBAudioEngine:RODE:1", inputName: "RØDE NT-USB"
    )
    static let airPods = DevicePair(
        outputUID: "AA-BB-CC-DD-EE-FF:output", outputName: "maxax",
        inputUID: "AppleUSBAudioEngine:RODE:1", inputName: "RØDE NT-USB"
    )

    /// The delays the settings keep, as a table from a pair's key to its delay.
    static func stored(_ table: [String: Double]) -> (DevicePair) -> Double? {
        { table[$0.key] }
    }

    /// A twenty-second song with one empty track.
    static func emptySong() -> Project {
        Project(songLengthSamples: 960_000)
    }

    /// Adds a one-second recording that begins `start` seconds into the song, made with `devices`, with all of
    /// it as a clip on the first track. Returns the recording's id.
    @discardableResult
    static func record(
        at start: Double,
        with devices: DevicePair?,
        delay: Double = 0,
        in project: inout Project
    ) -> UUID {
        let recording = Recording(lengthSamples: 48_000, rawStart: start, delay: delay, devicePair: devices)
        project.addRecording(recording, samples: 0..<48_000, asClipOn: project.tracks[0].id, voices: .none)
        return recording.id
    }

    static func delay(of id: UUID, in project: Project) -> Double? {
        project.recordings.first { $0.id == id }?.delay
    }

    // MARK: A new recording

    @Test func aNewRecordingGetsTheDelayStoredForItsPair() {
        let captured = Recording(lengthSamples: 48_000, rawStart: 4, devicePair: Self.wired)
        let recording = captured.movedBack(by: Self.stored([Self.wired.key: 0.0234]))

        #expect(recording.delay == 0.0234)
        // It sits 23.4 ms earlier in the song than it was heard, and nothing else about it changed.
        #expect(abs(recording.songTime(ofSample: 0) - 3.9766) < 1e-12)
        var unmoved = recording
        unmoved.delay = 0
        #expect(unmoved == captured)
    }

    @Test func aNewRecordingOfAPairWithoutADelayGetsZero() {
        let captured = Recording(lengthSamples: 48_000, rawStart: 4, devicePair: Self.airPods)
        let recording = captured.movedBack(by: Self.stored([Self.wired.key: 0.0234]))

        #expect(recording.delay == 0)
        #expect(recording.songTime(ofSample: 0) == 4)
    }

    @Test func aNewRecordingThatDoesNotSayItsDevicesGetsZero() {
        let captured = Recording(lengthSamples: 48_000, rawStart: 4, devicePair: nil)
        #expect(captured.movedBack { _ in 0.0234 }.delay == 0)
    }

    @Test func aStoredValueThatIsNotADelayIsNotUsed() {
        let captured = Recording(lengthSamples: 48_000, rawStart: 4, devicePair: Self.wired)
        for bad in [-0.01, Double.nan, Double.infinity] {
            #expect(captured.movedBack { _ in bad }.delay == 0)
        }
    }

    // MARK: After a calibration

    @Test func afterCalibratingEveryRecordingOfThePairWithoutADelayGetsIt() throws {
        var project = Self.emptySong()
        let first = Self.record(at: 2, with: Self.wired, in: &project)
        let second = Self.record(at: 6, with: Self.wired, in: &project)
        #expect(project.recordingsWaitingForDelay(madeWith: Self.wired) == [first, second])

        let moved = project.applyDelay(0.0234, toRecordingsMadeWith: Self.wired)

        #expect(moved == 2)
        #expect(Self.delay(of: first, in: project) == 0.0234)
        #expect(Self.delay(of: second, in: project) == 0.0234)
        #expect(project.recordingsWaitingForDelay(madeWith: Self.wired).isEmpty)
        // The clips moved with their recordings: each starts 23.4 ms earlier.
        let starts = try project.tracks[0].clips.map { try #require(project.start(of: $0)) }
        #expect(abs(starts[0] - 1.9766) < 1e-12)
        #expect(abs(starts[1] - 5.9766) < 1e-12)
    }

    @Test func aRecordingThatAlreadyHasADelayKeepsIt() {
        var project = Self.emptySong()
        let earlier = Self.record(at: 2, with: Self.airPods, delay: 0.180, in: &project)
        let new = Self.record(at: 6, with: Self.airPods, in: &project)

        let moved = project.applyDelay(0.217, toRecordingsMadeWith: Self.airPods)

        #expect(moved == 1)
        #expect(Self.delay(of: earlier, in: project) == 0.180)
        #expect(Self.delay(of: new, in: project) == 0.217)
    }

    @Test func aRecordingOfAnotherPairIsUntouched() {
        var project = Self.emptySong()
        let wired = Self.record(at: 2, with: Self.wired, in: &project)
        let wireless = Self.record(at: 6, with: Self.airPods, in: &project)
        let unknown = Self.record(at: 10, with: nil, in: &project)
        // The same headphones with another microphone are another pair.
        var otherMicrophone = Self.wired
        otherMicrophone.inputUID = "BuiltInMicrophoneDevice"
        let other = Self.record(at: 14, with: otherMicrophone, in: &project)
        let before = project

        let moved = project.applyDelay(0.0234, toRecordingsMadeWith: Self.wired)

        #expect(moved == 1)
        #expect(Self.delay(of: wired, in: project) == 0.0234)
        for id in [wireless, unknown, other] {
            #expect(project.recordings.first { $0.id == id } == before.recordings.first { $0.id == id })
        }
    }

    @Test func aRenamedDeviceIsStillTheSamePair() {
        var project = Self.emptySong()
        let recording = Self.record(at: 2, with: Self.wired, in: &project)
        var renamed = Self.wired
        renamed.outputName = "Studio headphones"
        renamed.inputName = "Röde"

        #expect(project.applyDelay(0.0234, toRecordingsMadeWith: renamed) == 1)
        #expect(Self.delay(of: recording, in: project) == 0.0234)
    }

    @Test func aValueThatIsNotADelayMovesNothing() {
        var project = Self.emptySong()
        Self.record(at: 2, with: Self.wired, in: &project)
        let before = project

        for bad in [0, -0.01, Double.nan, Double.infinity] {
            #expect(project.applyDelay(bad, toRecordingsMadeWith: Self.wired) == 0)
        }
        #expect(project == before)
    }

    // MARK: Opening a project

    @Test func openingAProjectCorrectsRecordingsWhosePairHasADelayNow() {
        var project = Self.emptySong()
        let wired = Self.record(at: 2, with: Self.wired, in: &project)
        let measuredEarlier = Self.record(at: 6, with: Self.wired, delay: 0.020, in: &project)
        let wireless = Self.record(at: 10, with: Self.airPods, in: &project)
        let unknown = Self.record(at: 14, with: nil, in: &project)

        // The wired pair has a delay. The AirPods have none in use, as after the app was started again.
        let moved = project.applyStoredDelays(Self.stored([Self.wired.key: 0.0234]))

        #expect(moved == 1)
        #expect(Self.delay(of: wired, in: project) == 0.0234)
        #expect(Self.delay(of: measuredEarlier, in: project) == 0.020)
        #expect(Self.delay(of: wireless, in: project) == 0)
        #expect(Self.delay(of: unknown, in: project) == 0)
    }

    @Test func openingAProjectWithNothingStoredChangesNothing() {
        var project = Self.emptySong()
        Self.record(at: 2, with: Self.wired, in: &project)
        let before = project

        #expect(project.applyStoredDelays(Self.stored([:])) == 0)
        #expect(project == before)
    }

    @Test func eachPairGetsItsOwnDelayWhenAProjectIsOpened() {
        var project = Self.emptySong()
        let wired = Self.record(at: 2, with: Self.wired, in: &project)
        let wireless = Self.record(at: 6, with: Self.airPods, in: &project)

        let moved = project.applyStoredDelays(Self.stored([Self.wired.key: 0.0234, Self.airPods.key: 0.217]))

        #expect(moved == 2)
        #expect(Self.delay(of: wired, in: project) == 0.0234)
        #expect(Self.delay(of: wireless, in: project) == 0.217)
    }

    // MARK: Undo

    @Test func undoRestoresTheOldDelaysAndRedoAppliesThemAgain() {
        var project = Self.emptySong()
        let waiting = Self.record(at: 2, with: Self.wired, in: &project)
        let measuredEarlier = Self.record(at: 6, with: Self.wired, delay: 0.020, in: &project)
        let store = ProjectStore(project: project)
        let before = store.project

        store.edit("Apply Delay") { $0.applyDelay(0.0234, toRecordingsMadeWith: Self.wired) }
        #expect(Self.delay(of: waiting, in: store.project) == 0.0234)
        #expect(store.undoTitle == "Undo Apply Delay")

        store.undo()
        #expect(store.project == before)
        #expect(Self.delay(of: waiting, in: store.project) == 0)
        #expect(Self.delay(of: measuredEarlier, in: store.project) == 0.020)

        store.redo()
        #expect(Self.delay(of: waiting, in: store.project) == 0.0234)
        #expect(Self.delay(of: measuredEarlier, in: store.project) == 0.020)
    }
}
