import Foundation
import Observation
import Testing
@testable import LockstepCore

/// Each test keeps its settings in a store of its own, which is removed when the test ends. Max's own settings
/// are never read or written.
@MainActor
@Suite("Measured delays")
struct MeasuredDelaysTests {
    /// A settings store that nothing else uses. Its name is the path of a file in a folder of its own among
    /// the Mac's temporary files, which makes macOS keep the settings in that file and nowhere else. The folder
    /// is deleted when the test ends.
    final class Store {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("lockstep-settings-tests-\(UUID().uuidString)", isDirectory: true)
        let name: String
        let defaults: UserDefaults

        init() throws {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            name = folder.appendingPathComponent("Settings").path
            defaults = try #require(UserDefaults(suiteName: name))
        }

        deinit {
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: folder)
        }

        /// The settings as the app has them after it was started again: read from the same store by a
        /// settings object that remembers nothing.
        @MainActor
        func settingsAfterRestart() throws -> AppSettings {
            AppSettings(store: try #require(UserDefaults(suiteName: name)))
        }
    }

    static let wired = DevicePair(
        outputUID: "BuiltInHeadphoneOutputDevice", outputName: "External Headphones",
        inputUID: "AppleUSBAudioEngine:RODE:1", inputName: "RØDE NT-USB"
    )
    static let airPods = DevicePair(
        outputUID: "AA-BB-CC-DD-EE-FF:output", outputName: "maxax",
        inputUID: "AppleUSBAudioEngine:RODE:1", inputName: "RØDE NT-USB"
    )
    static let builtIn = DevicePair(
        outputUID: "BuiltInSpeakerDevice", outputName: "MacBook Pro Speakers",
        inputUID: "BuiltInMicrophoneDevice", inputName: "MacBook Pro Microphone"
    )
    static let november = Date(timeIntervalSince1970: 1_794_500_000)

    /// Every sound device of these tests that can be connected, with or without the AirPods.
    static func connected(airPods: Bool) -> Set<String> {
        var uids: Set<String> = [wired.outputUID, wired.inputUID, builtIn.outputUID, builtIn.inputUID]
        if airPods { uids.insert(Self.airPods.outputUID) }
        return uids
    }

    @Test("A measured delay is read back for its pair, and a pair that was never measured has none")
    func delayIsKeptForItsPair() throws {
        let store = try Store()
        let settings = AppSettings(store: store.defaults)
        #expect(settings.delay(for: Self.wired) == nil)
        #expect(settings.measuredDelays.isEmpty)

        settings.setDelay(0.0123, for: Self.wired, wireless: false, measured: Self.november)
        #expect(settings.delay(for: Self.wired) == 0.0123)
        #expect(settings.delay(for: Self.builtIn) == nil)
        // The same headphones with another microphone are another pair.
        var otherMicrophone = Self.wired
        otherMicrophone.inputUID = Self.builtIn.inputUID
        #expect(settings.delay(for: otherMicrophone) == nil)
        // The names are not what a pair is known by: a renamed device keeps its delay.
        var renamed = Self.wired
        renamed.outputName = "Studio headphones"
        #expect(settings.delay(for: renamed) == 0.0123)

        #expect(settings.measuredDelays == [
            MeasuredDelay(devices: Self.wired, delay: 0.0123, measured: Self.november, wireless: false)
        ])
        #expect(Self.wired.key == "BuiltInHeadphoneOutputDevice|AppleUSBAudioEngine:RODE:1")
    }

    @Test("Measuring a pair again replaces its delay, and what is not a delay is not kept")
    func measuringAgainReplaces() throws {
        let store = try Store()
        let settings = AppSettings(store: store.defaults)
        settings.setDelay(0.0123, for: Self.wired, wireless: false, measured: Self.november)
        settings.setDelay(0.0131, for: Self.wired, wireless: false, measured: Self.november + 60)
        #expect(settings.delay(for: Self.wired) == 0.0131)
        #expect(settings.measuredDelays.count == 1)
        #expect(settings.measuredDelays.first?.measured == Self.november + 60)

        settings.setDelay(-0.5, for: Self.wired, wireless: false)
        settings.setDelay(.nan, for: Self.wired, wireless: false)
        settings.setDelay(0.02, for: DevicePair(), wireless: false)
        #expect(settings.delay(for: Self.wired) == 0.0131)
        #expect(settings.measuredDelays.count == 1)
    }

    @Test("Removing a pair's delay leaves the other pairs alone")
    func removing() throws {
        let store = try Store()
        let settings = AppSettings(store: store.defaults)
        settings.setDelay(0.0123, for: Self.wired, wireless: false, measured: Self.november)
        settings.setDelay(0.0345, for: Self.builtIn, wireless: false, measured: Self.november)

        settings.removeDelay(for: Self.wired)
        #expect(settings.delay(for: Self.wired) == nil)
        #expect(settings.delay(for: Self.builtIn) == 0.0345)
        #expect(settings.measuredDelays.map(\.devices) == [Self.builtIn])
        // Removing what is not there changes nothing.
        settings.removeDelay(for: Self.airPods)
        #expect(settings.measuredDelays.map(\.devices) == [Self.builtIn])
    }

    @Test("The delays are kept in the app's settings store and are still there after a restart")
    func delaysOutliveARestart() throws {
        let store = try Store()
        let settings = AppSettings(store: store.defaults)
        settings.setDelay(0.0123, for: Self.wired, wireless: false, measured: Self.november)
        settings.setDelay(0.0345, for: Self.builtIn, wireless: false, measured: Self.november + 1)
        #expect(store.defaults.dictionary(forKey: "recording.measuredDelays")?.count == 2)

        let restarted = try store.settingsAfterRestart()
        #expect(restarted.delay(for: Self.wired) == 0.0123)
        #expect(restarted.delay(for: Self.builtIn) == 0.0345)
        // The list is in the order of the outputs' names, with everything that was kept.
        #expect(restarted.measuredDelays == [
            MeasuredDelay(devices: Self.wired, delay: 0.0123, measured: Self.november, wireless: false),
            MeasuredDelay(devices: Self.builtIn, delay: 0.0345, measured: Self.november + 1, wireless: false),
        ])
    }

    @Test("A wireless pair has no delay after it disconnects, and has one again after a new calibration")
    func wirelessDelayEndsWithTheConnection() throws {
        let store = try Store()
        let settings = AppSettings(store: store.defaults)
        settings.setDelay(0.0123, for: Self.wired, wireless: false, measured: Self.november)
        settings.setDelay(0.217, for: Self.airPods, wireless: true, measured: Self.november)
        #expect(settings.delay(for: Self.airPods) == 0.217)

        // Other devices come and go while the AirPods stay connected: the delay holds.
        settings.endWirelessConnections(except: Self.connected(airPods: true))
        #expect(settings.delay(for: Self.airPods) == 0.217)

        // The AirPods disconnect.
        settings.endWirelessConnections(except: Self.connected(airPods: false))
        #expect(settings.delay(for: Self.airPods) == nil)
        // The wired pair is untouched, also when its headphones are unplugged.
        settings.endWirelessConnections(except: [])
        #expect(settings.delay(for: Self.wired) == 0.0123)

        // The AirPods connect again: the old delay is not taken for the new connection.
        settings.endWirelessConnections(except: Self.connected(airPods: true))
        #expect(settings.delay(for: Self.airPods) == nil)
        // The row is still in the list, with its old value, so it can be measured again from there.
        #expect(settings.measuredDelays.contains { $0.devices == Self.airPods && $0.delay == 0.217 && $0.wireless })

        settings.setDelay(0.224, for: Self.airPods, wireless: true, measured: Self.november + 600)
        #expect(settings.delay(for: Self.airPods) == 0.224)
    }

    @Test("After a restart a wireless pair has no delay until it is measured again, and a wired pair keeps its")
    func restartEndsWirelessDelaysOnly() throws {
        let store = try Store()
        let settings = AppSettings(store: store.defaults)
        settings.setDelay(0.0123, for: Self.wired, wireless: false, measured: Self.november)
        settings.setDelay(0.217, for: Self.airPods, wireless: true, measured: Self.november)

        let restarted = try store.settingsAfterRestart()
        #expect(restarted.delay(for: Self.wired) == 0.0123)
        #expect(restarted.delay(for: Self.airPods) == nil)
        #expect(restarted.measuredDelays.count == 2)

        restarted.setDelay(0.209, for: Self.airPods, wireless: true, measured: Self.november + 600)
        #expect(restarted.delay(for: Self.airPods) == 0.209)
        // A wireless pair can be removed like any other.
        restarted.removeDelay(for: Self.airPods)
        #expect(restarted.delay(for: Self.airPods) == nil)
        #expect(restarted.measuredDelays.map(\.devices) == [Self.wired])
    }

    @Test("What shows a delay is told when the delay is measured and when a wireless connection ends")
    func readersAreToldOfChanges() throws {
        let store = try Store()
        let settings = AppSettings(store: store.defaults)

        /// Reads the AirPods' delay as a view would, and says whether the reader was told of a change by `change`.
        func isTold(by change: () -> Void) -> Bool {
            let told = Told()
            withObservationTracking {
                _ = settings.delay(for: Self.airPods)
            } onChange: {
                told.value = true
            }
            change()
            return told.value
        }

        #expect(isTold { settings.setDelay(0.217, for: Self.airPods, wireless: true) })
        #expect(!isTold { settings.endWirelessConnections(except: Self.connected(airPods: true)) })
        #expect(isTold { settings.endWirelessConnections(except: Self.connected(airPods: false)) })
        #expect(isTold { settings.setDelay(0.22, for: Self.airPods, wireless: true) })
        #expect(isTold { settings.removeDelay(for: Self.airPods) })
    }

    @Test("Restore Defaults in the Recording pane empties the list and leaves the other panes alone")
    func restoreDefaultsEmptiesTheList() throws {
        let store = try Store()
        let settings = AppSettings(store: store.defaults)
        settings.setDelay(0.0123, for: Self.wired, wireless: false)
        settings[.maxGapBeats] = 12

        settings.restoreDefaults(for: .general)
        #expect(settings.delay(for: Self.wired) == 0.0123)
        settings.restoreDefaults(for: .recording)
        #expect(settings.delay(for: Self.wired) == nil)
        #expect(settings.measuredDelays.isEmpty)
        #expect(settings[.maxGapBeats] == 12)
    }

    @Test("A row of the stored list that cannot be read is left out, and the rest is kept")
    func damagedRowsAreLeftOut() throws {
        let store = try Store()
        let settings = AppSettings(store: store.defaults)
        settings.setDelay(0.0123, for: Self.wired, wireless: false, measured: Self.november)
        var table = try #require(store.defaults.dictionary(forKey: "recording.measuredDelays"))
        table["no devices"] = ["delay": 0.05]
        table["no delay"] = ["outputUID": "a", "inputUID": "b", "delay": "soon"]
        table["not a row"] = 7
        // A row from which "wireless" is missing counts as wireless, so its delay is not used unmeasured.
        table["unsure"] = ["outputUID": "x", "inputUID": "y", "delay": 0.2]
        store.defaults.set(table, forKey: "recording.measuredDelays")

        let restarted = try store.settingsAfterRestart()
        #expect(restarted.delay(for: Self.wired) == 0.0123)
        #expect(restarted.measuredDelays.count == 2)
        #expect(restarted.delay(for: DevicePair(outputUID: "x", inputUID: "y")) == nil)

        // Something that is not a list at all counts as an empty list.
        store.defaults.set("gone", forKey: "recording.measuredDelays")
        #expect(try store.settingsAfterRestart().measuredDelays.isEmpty)
    }
}

/// Whether a reader was told of a change. The telling may come from any thread, so it is kept behind a lock.
private final class Told: @unchecked Sendable {
    private let lock = NSLock()
    private var told = false

    var value: Bool {
        get { lock.withLock { told } }
        set { lock.withLock { told = newValue } }
    }
}
