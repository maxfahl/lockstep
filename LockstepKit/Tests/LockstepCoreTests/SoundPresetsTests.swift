import Foundation
import Testing
@testable import LockstepCore

/// The answer of a call that changes what it is called on. Such a call cannot stand inside `#expect` itself.
private func answer<Answer>(_ change: () -> Answer) -> Answer {
    change()
}

/// Max's own presets. Each test that keeps them does so in a settings store of its own, which is removed
/// when the test ends. Max's own settings are never read or written.
@MainActor
@Suite("Max's own presets of a Sound")
struct SoundPresetsTests {
    private func preset(_ name: String, _ character: SoundCharacter = .rapLead, space: Double = 0.2) -> SoundPreset {
        SoundPreset(name: name, character: character, knobs: SoundKnobs(squeeze: 0.7, tone: 0.5, warmth: 0.3, space: space))
    }

    @Test func aPresetIsAddedLastAndOneWithATakenNameIsReplacedWhereItStands() {
        var own = SoundPresets()
        #expect(answer { own.add(preset("My hook", .sungHook)) })
        #expect(answer { own.add(preset("Dry", .rapLead, space: 0)) })
        #expect(own.presets.map(\.name) == ["My hook", "Dry"])

        // The same name with other letters' case is the same preset.
        #expect(answer { own.add(preset("my hook", .backingVoice, space: 0.9)) })
        #expect(own.presets.map(\.name) == ["my hook", "Dry"])
        #expect(own.presets[0].character == .backingVoice)
        #expect(own.presets[0].knobs.space == 0.9)
    }

    @Test func aNameIsTrimmedAndAnEmptyOrBuiltInNameIsRefused() {
        var own = SoundPresets()
        #expect(answer { own.add(preset("  Wide  ")) })
        #expect(own.presets.map(\.name) == ["Wide"])
        #expect(!answer { own.add(preset("   ")) })
        #expect(!answer { own.add(preset("Rap lead")) })
        #expect(!answer { own.add(preset("sung HOOK")) })
        #expect(own.presets.map(\.name) == ["Wide"])
    }

    @Test func aKeptPresetHasItsKnobsInWholePercentBetweenNothingAndAll() {
        var own = SoundPresets()
        own.add(SoundPreset(name: "Odd", character: .adLib, knobs: SoundKnobs(squeeze: 0.333, tone: 1.4, warmth: -2, space: 0.555)))
        #expect(own.presets[0].knobs == SoundKnobs(squeeze: 0.33, tone: 1, warmth: 0, space: 0.56))
    }

    @Test func removingForgetsOnePresetAndSaysWhenThereIsNone() {
        var own = SoundPresets()
        own.add(preset("One"))
        own.add(preset("Two"))
        #expect(answer { own.remove(named: "one") })
        #expect(own.presets.map(\.name) == ["Two"])
        #expect(!answer { own.remove(named: "one") })
    }

    @Test func thePresetsAreKeptWithTheSettingsAndReadAgainAfterARestart() throws {
        let store = try MeasuredDelaysTests.Store()
        let settings = AppSettings(store: store.defaults)
        #expect(settings[.ownPresets].presets.isEmpty)

        let sound = TrackSound(name: "Sung lead", character: .sungLead, knobs: SoundKnobs(squeeze: 0.4, tone: 0.6, warmth: 0.1, space: 0.75))
        #expect(settings.saveOwnPreset(named: "Verse two", from: sound))
        #expect(settings.saveOwnPreset(named: "Shout", from: TrackSound(name: "Ad-lib", character: .adLib, knobs: sound.knobs)))
        #expect(!settings.saveOwnPreset(named: "Ad-lib", from: sound))

        let again = try store.settingsAfterRestart()
        #expect(again[.ownPresets].presets == [
            SoundPreset(name: "Verse two", character: .sungLead, knobs: sound.knobs),
            SoundPreset(name: "Shout", character: .adLib, knobs: sound.knobs),
        ])

        #expect(again.removeOwnPreset(named: "Verse two"))
        #expect(!again.removeOwnPreset(named: "Verse two"))
        #expect(try store.settingsAfterRestart()[.ownPresets].presets.map(\.name) == ["Shout"])
    }

    @Test func restoreDefaultsOfAPaneLeavesThePresetsAlone() throws {
        let store = try MeasuredDelaysTests.Store()
        let settings = AppSettings(store: store.defaults)
        settings.saveOwnPreset(named: "Mine", from: SoundPreset.builtIn[0].sound)
        for pane in SettingsPane.allCases {
            settings.restoreDefaults(for: pane)
        }
        #expect(settings[.ownPresets].presets.map(\.name) == ["Mine"])
    }

    @Test func aStoredRowThatCannotBeReadIsLeftOutAndTheOthersAreKept() throws {
        let stored: [Any] = [
            ["name": "Good", "character": "rapDouble", "squeeze": 0.8, "tone": 0.5, "warmth": 0.25, "space": 0.12],
            ["name": "From a newer Lockstep", "character": "whisper", "squeeze": 0.5],
            ["character": "rapLead"],
            "not a row",
        ]
        let own = try #require(SoundPresets(stored: stored))
        #expect(own.presets == [
            SoundPreset(name: "Good", character: .rapDouble, knobs: SoundKnobs(squeeze: 0.8, tone: 0.5, warmth: 0.25, space: 0.12)),
        ])
        #expect(SoundPresets(stored: "nothing like a list") == nil)
    }

    @Test func thePresetsAreWrittenAndReadBackAsText() throws {
        var own = SoundPresets()
        own.add(preset("One", .sungHook))
        own.add(preset("Two", .adLib))
        let read = try JSONDecoder().decode(SoundPresets.self, from: JSONEncoder().encode(own))
        #expect(read == own)
    }
}
