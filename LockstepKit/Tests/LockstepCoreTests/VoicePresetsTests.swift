import Foundation
import Testing
@testable import LockstepCore

/// The answer of a call that changes what it is called on. Such a call cannot stand inside `#expect` itself.
private func answer<Answer>(_ change: () -> Answer) -> Answer {
    change()
}

/// The presets of a Voice. Each test that keeps them does so in a settings store of its own, which is removed
/// when the test ends. Max's own settings are never read or written.
@MainActor
@Suite("The presets of a Voice")
struct VoicePresetsTests {
    private let villain = VoiceKnobs(depth: 8, pitch: -1.5)

    @Test func theThreeBuiltInPresetsAreTheOnesTheDesignNames() {
        #expect(VoicePresets.builtIn == [
            VoicePreset(name: "Darker", knobs: VoiceKnobs(depth: 6, pitch: -1)),
            VoicePreset(name: "Deeper", knobs: VoiceKnobs(depth: 10, pitch: -2)),
            VoicePreset(name: "Lighter", knobs: VoiceKnobs(depth: -6, pitch: 1)),
        ])
        #expect(VoicePresets.builtIn(named: "deeper")?.knobs == VoiceKnobs(depth: 10, pitch: -2))
        #expect(VoicePresets.builtIn(named: "Villain") == nil)
    }

    @Test func aChosenPresetIsCopiedOntoTheTrackSwitchedOn() {
        let voice = VoicePresets.builtIn[0].voice
        #expect(voice == TrackVoice(isOn: true, name: "Darker", knobs: VoiceKnobs(depth: 6, pitch: -1), natural: false))
        #expect(voice.isHeard)
    }

    @Test func aPresetIsSavedLastAndOneOfHisOwnWithTheNameIsReplacedWhereItStands() {
        var own = VoicePresets()
        #expect(answer { own.save(named: "Villain", knobs: villain) })
        #expect(answer { own.save(named: "Kid", knobs: VoiceKnobs(depth: -10, pitch: 3)) })
        #expect(own.presets.map(\.name) == ["Villain", "Kid"])

        // The same name with other letters' case is the same preset.
        #expect(answer { own.save(named: "villain", knobs: VoiceKnobs(depth: 12, pitch: -3)) })
        #expect(own.presets.map(\.name) == ["villain", "Kid"])
        #expect(own.presets[0].knobs == VoiceKnobs(depth: 12, pitch: -3))

        // One is found by its name, a built-in one first.
        #expect(own.preset(named: "KID")?.knobs == VoiceKnobs(depth: -10, pitch: 3))
        #expect(own.preset(named: "darker") == VoicePresets.builtIn[0])
        #expect(own.preset(named: "Nobody") == nil)
    }

    @Test func aNameIsTrimmedAndAnEmptyOrTakenNameIsRefused() {
        var own = VoicePresets()
        #expect(answer { own.save(named: "  Villain \n", knobs: villain) })
        #expect(own.presets.map(\.name) == ["Villain"])
        #expect(!answer { own.save(named: "", knobs: villain) })
        #expect(!answer { own.save(named: "   ", knobs: villain) })
        // A built-in preset's name, and the name of a Voice that is no preset's.
        #expect(!answer { own.save(named: "Darker", knobs: villain) })
        #expect(!answer { own.save(named: " lighter ", knobs: villain) })
        #expect(!answer { own.save(named: "Custom", knobs: villain) })
        #expect(!answer { own.save(named: "custom", knobs: villain) })
        #expect(own.presets == [VoicePreset(name: "Villain", knobs: villain)])
    }

    @Test func removingForgetsOnePresetAndSaysWhenThereIsNone() {
        var own = VoicePresets()
        own.save(named: "One", knobs: villain)
        own.save(named: "Two", knobs: villain)
        #expect(answer { own.remove(named: "one") })
        #expect(own.presets.map(\.name) == ["Two"])
        #expect(!answer { own.remove(named: "one") })
        // A built-in preset is not his to remove.
        #expect(!answer { own.remove(named: "Darker") })
    }

    @Test func thePresetsAreKeptWithTheSettingsAndReadAgainAfterARestart() throws {
        let store = try MeasuredDelaysTests.Store()
        let settings = AppSettings(store: store.defaults)
        #expect(SettingKey.ownVoicePresets.name == "voices.ownPresets")
        #expect(settings[.ownVoicePresets].presets.isEmpty)

        #expect(settings.saveOwnVoicePreset(named: "Villain", knobs: villain))
        #expect(settings.saveOwnVoicePreset(named: "Kid", knobs: VoiceKnobs(depth: -10, pitch: 3)))
        #expect(!settings.saveOwnVoicePreset(named: "Deeper", knobs: villain))

        let again = try store.settingsAfterRestart()
        #expect(again[.ownVoicePresets].presets == [
            VoicePreset(name: "Villain", knobs: villain),
            VoicePreset(name: "Kid", knobs: VoiceKnobs(depth: -10, pitch: 3)),
        ])
        // A Sound's presets are another setting.
        #expect(again[.ownPresets].presets.isEmpty)

        #expect(again.removeOwnVoicePreset(named: "Villain"))
        #expect(!again.removeOwnVoicePreset(named: "Villain"))
        #expect(try store.settingsAfterRestart()[.ownVoicePresets].presets.map(\.name) == ["Kid"])
    }

    @Test func restoreDefaultsOfAPaneLeavesThePresetsAlone() throws {
        let store = try MeasuredDelaysTests.Store()
        let settings = AppSettings(store: store.defaults)
        settings.saveOwnVoicePreset(named: "Mine", knobs: villain)
        for pane in SettingsPane.allCases {
            settings.restoreDefaults(for: pane)
        }
        #expect(settings[.ownVoicePresets].presets.map(\.name) == ["Mine"])
    }

    @Test func theStoredRowsAreNameDepthAndPitch() throws {
        var own = VoicePresets()
        own.save(named: "Villain", knobs: villain)
        own.save(named: "Kid", knobs: VoiceKnobs(depth: -10, pitch: 3))
        let rows = try #require(own.storedForm as? [[String: Any]])
        #expect(rows.map { Set($0.keys) } == [["name", "depth", "pitch"], ["name", "depth", "pitch"]])
        #expect(rows[0]["name"] as? String == "Villain")
        #expect(rows[0]["depth"] as? Int == 8)
        #expect(rows[0]["pitch"] as? Double == -1.5)
        #expect(VoicePresets(stored: own.storedForm) == own)
    }

    @Test func aStoredRowThatCannotBeReadIsLeftOutAndAKnobIsBroughtInsideItsRange() throws {
        let stored: [Any] = [
            ["name": "Good", "depth": 8, "pitch": -1.5],
            ["name": "By hand", "depth": 99.4, "pitch": "2.3"],
            ["name": "No knobs"],
            ["depth": 3, "pitch": 1],
            ["name": "Darker", "depth": 1, "pitch": 1],
            "not a row",
        ]
        let own = try #require(VoicePresets(stored: stored))
        #expect(own.presets == [
            VoicePreset(name: "Good", knobs: VoiceKnobs(depth: 8, pitch: -1.5)),
            VoicePreset(name: "By hand", knobs: VoiceKnobs(depth: 15, pitch: 2.5)),
            VoicePreset(name: "No knobs", knobs: .neutral),
        ])
        #expect(VoicePresets(stored: "nothing like a list") == nil)
    }

    @Test func thePresetsAreWrittenAndReadBackAsText() throws {
        var own = VoicePresets()
        own.save(named: "One", knobs: villain)
        own.save(named: "Two", knobs: VoiceKnobs(depth: -4, pitch: 0.5))
        let read = try JSONDecoder().decode(VoicePresets.self, from: JSONEncoder().encode(own))
        #expect(read == own)
    }
}
