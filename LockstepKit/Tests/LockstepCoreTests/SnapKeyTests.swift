import Foundation
import Testing
@testable import LockstepCore

@Suite("Holding Command turns snapping the other way")
@MainActor
struct SnapKeyTests {
    /// Settings kept in a throwaway suite, with snapping as given.
    private func settings(snapping: Bool) -> AppSettings {
        let suite = "SnapKeyTests-\(UUID().uuidString)"
        let settings = AppSettings(store: UserDefaults(suiteName: suite)!)
        settings[.snapping] = snapping
        return settings
    }

    @Test("Without Command, snapping holds as the setting says")
    func withoutCommand() {
        #expect(SnapKey.snappingHolds(isOn: true, commandHeld: false))
        #expect(!SnapKey.snappingHolds(isOn: false, commandHeld: false))
    }

    @Test("With Command held, snapping holds the other way")
    func withCommand() {
        #expect(!SnapKey.snappingHolds(isOn: true, commandHeld: true))
        #expect(SnapKey.snappingHolds(isOn: false, commandHeld: true))
    }

    @Test("The settings answer from the setting, and the setting itself stays as it is")
    func settingStays() {
        let on = settings(snapping: true)
        #expect(on.snappingHolds(commandHeld: false))
        #expect(!on.snappingHolds(commandHeld: true))
        #expect(on[.snapping])

        let off = settings(snapping: false)
        #expect(!off.snappingHolds(commandHeld: false))
        #expect(off.snappingHolds(commandHeld: true))
        #expect(!off[.snapping])
    }
}
