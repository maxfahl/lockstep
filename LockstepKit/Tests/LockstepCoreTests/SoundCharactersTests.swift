import Foundation
import Testing
@testable import LockstepCore

@Suite("The six presets and the table that turns knobs into the chain's numbers")
struct SoundCharactersTests {
    private static let positions = [0.0, 0.5, 1.0]

    /// Every way to set the four knobs to 0, 50 or 100 %.
    private static var everyKnobSetting: [SoundKnobs] {
        var settings: [SoundKnobs] = []
        for squeeze in positions {
            for tone in positions {
                for warmth in positions {
                    for space in positions {
                        settings.append(SoundKnobs(squeeze: squeeze, tone: tone, warmth: warmth, space: space))
                    }
                }
            }
        }
        return settings
    }

    private func knobs(_ value: Double) -> SoundKnobs {
        SoundKnobs(squeeze: value, tone: value, warmth: value, space: value)
    }

    // MARK: The presets

    @Test func theSixBuiltInPresetsAreTheOnesOfTheDesign() {
        let expected: [(String, SoundCharacter, [Double])] = [
            ("Rap lead", .rapLead, [0.70, 0.55, 0.35, 0.08]),
            ("Rap double", .rapDouble, [0.80, 0.50, 0.25, 0.12]),
            ("Ad-lib", .adLib, [0.80, 1.00, 0.55, 0.25]),
            ("Sung lead", .sungLead, [0.50, 0.55, 0.15, 0.35]),
            ("Sung hook", .sungHook, [0.60, 0.65, 0.20, 0.45]),
            ("Backing voice", .backingVoice, [0.75, 0.45, 0.10, 0.50]),
        ]
        #expect(SoundPreset.builtIn.count == expected.count)
        for (preset, wanted) in zip(SoundPreset.builtIn, expected) {
            #expect(preset.name == wanted.0)
            #expect(preset.character == wanted.1)
            #expect(preset.knobs == SoundKnobs(squeeze: wanted.2[0], tone: wanted.2[1], warmth: wanted.2[2], space: wanted.2[3]))
        }
    }

    @Test func aPresetIsFoundByItsNameAndCopiedOntoATrackAsItsSound() throws {
        let preset = try #require(SoundPreset.builtIn(named: "sung hook"))
        #expect(preset.character == .sungHook)
        #expect(preset.sound == TrackSound(name: "Sung hook", character: .sungHook, knobs: preset.knobs))
        #expect(SoundPreset.builtIn(named: "No such sound") == nil)
    }

    // MARK: The table

    @Test(arguments: SoundCharacter.allCases)
    func everyNumberIsInsideWhatTheChainAllows(character: SoundCharacter) {
        for setting in Self.everyKnobSetting {
            let chain = character.parameters(setting)
            #expect((20...500).contains(chain.lowCutHz))
            #expect((-40..<0).contains(chain.deEss.thresholdDb))
            #expect((0...24).contains(chain.deEss.maxCutDb))
            if let ride = chain.ride {
                #expect(ride.maxGainDb > 0 && ride.maxGainDb <= 12)
                #expect((50...2_000).contains(ride.speedMs))
            }
            #expect((1...20).contains(chain.squeeze.ratio))
            #expect((-60...0).contains(chain.squeeze.thresholdDb))
            #expect((0.1...100).contains(chain.squeeze.attackMs))
            #expect((1...1_000).contains(chain.squeeze.releaseMs))
            #expect((0...24).contains(chain.squeeze.makeupDb))
            #expect(chain.tone.count <= 4)
            for band in chain.tone {
                #expect((20...21_600).contains(band.hz))
                #expect((-24...24).contains(band.gainDb))
                #expect(band.q > 0)
            }
            #expect((0...1).contains(chain.warmth))
            if let reverb = chain.reverb {
                #expect(reverb.mix > 0 && reverb.mix <= 1)
            }
            if let echo = chain.echo {
                #expect(echo.levelDb.isFinite && echo.levelDb <= 0)
            }
        }
    }

    @Test(arguments: SoundCharacter.allCases)
    func squeezeRisesWithItsKnob(character: SoundCharacter) {
        let none = character.parameters(knobs(0)).squeeze
        let half = character.parameters(knobs(0.5)).squeeze
        let full = character.parameters(knobs(1)).squeeze
        // No levelling at 0 %: nothing is turned down and nothing is made up for.
        #expect(none.ratio == 1)
        #expect(none.makeupDb == 0)
        #expect(half.ratio > 1)
        #expect(full.ratio > half.ratio)
        // At 100 % the threshold is 6 dB lower than at 50 %.
        #expect(abs(full.thresholdDb - (half.thresholdDb - 6)) < 1e-9)
        #expect(full.makeupDb > half.makeupDb)
        #expect(half.makeupDb > 0)
        // How fast it reacts is the character's, whatever the knob says.
        #expect(none.attackMs == full.attackMs)
        #expect(none.releaseMs == full.releaseMs)
    }

    @Test func onlySqueezeChangesTheSqueeze() {
        for character in SoundCharacter.allCases {
            var turned = knobs(0.5)
            let before = character.parameters(turned)
            turned.tone = 1
            turned.warmth = 1
            turned.space = 1
            let after = character.parameters(turned)
            #expect(after.squeeze == before.squeeze)
            #expect(after.ride == before.ride)
            #expect(after.deEss == before.deEss)
        }
    }

    @Test func theSungCharactersRideTheLevelAndTheRideFollowsSqueeze() throws {
        for character in [SoundCharacter.sungLead, .sungHook] {
            #expect(character.parameters(knobs(0)).ride == nil)
            let half = try #require(character.parameters(knobs(0.5)).ride)
            let full = try #require(character.parameters(knobs(1)).ride)
            #expect(full.maxGainDb == 6)
            #expect(half.maxGainDb == 3)
        }
        for character in [SoundCharacter.rapLead, .rapDouble, .adLib, .backingVoice] {
            #expect(character.parameters(knobs(1)).ride == nil)
        }
    }

    @Test(arguments: SoundCharacter.allCases)
    func toneAtNothingIsFlatAndTheLowCutDoesNotFollowIt(character: SoundCharacter) {
        let flat = character.parameters(knobs(0))
        // Nothing lifts or cuts, and nothing is kept from getting through.
        for band in flat.tone {
            #expect(band.gainDb == 0)
            #expect(band.kind != .highPass && band.kind != .lowPass)
        }
        let full = character.parameters(knobs(1))
        #expect(full.tone.contains { $0.gainDb != 0 || $0.kind == .highPass || $0.kind == .lowPass })
        #expect(full.lowCutHz == flat.lowCutHz)
        #expect(character.parameters(knobs(0.5)).lowCutHz == flat.lowCutHz)
    }

    @Test func aBandsGainIsTheKnobTimesItsFullGain() {
        for character in SoundCharacter.allCases {
            let half = character.parameters(knobs(0.5)).tone
            let full = character.parameters(knobs(1)).tone
            #expect(half.count == full.count)
            for (halfBand, fullBand) in zip(half, full) where fullBand.kind != .highPass && fullBand.kind != .lowPass {
                #expect(halfBand.hz == fullBand.hz)
                #expect(abs(halfBand.gainDb - fullBand.gainDb / 2) < 1e-9)
            }
        }
    }

    @Test func theAdLibIsThinLikeAPhoneAtFullToneAndOpensAsToneIsTurnedDown() throws {
        let full = SoundCharacter.adLib.parameters(knobs(1)).tone
        let fullLow = try #require(full.first { $0.kind == .highPass })
        let fullTop = try #require(full.first { $0.kind == .lowPass })
        #expect(fullLow.hz == 350)
        #expect(fullTop.hz == 3_400)
        let half = SoundCharacter.adLib.parameters(knobs(0.5)).tone
        let halfLow = try #require(half.first { $0.kind == .highPass })
        let halfTop = try #require(half.first { $0.kind == .lowPass })
        #expect(halfLow.hz < fullLow.hz)
        #expect(halfTop.hz > fullTop.hz)
    }

    @Test(arguments: SoundCharacter.allCases)
    func warmthAndSpaceRiseWithTheirKnobs(character: SoundCharacter) throws {
        let none = character.parameters(knobs(0))
        let half = character.parameters(knobs(0.5))
        let full = character.parameters(knobs(1))
        // Clean and dry at 0 %.
        #expect(none.warmth == 0)
        #expect(none.reverb == nil)
        #expect(none.echo == nil)
        #expect(half.warmth > 0)
        #expect(full.warmth > half.warmth)
        let halfRoom = try #require(half.reverb)
        let fullRoom = try #require(full.reverb)
        #expect(halfRoom.room == fullRoom.room)
        #expect(fullRoom.mix > halfRoom.mix)
        // The echo's level follows Space together with the reverb.
        #expect((half.echo == nil) == (full.echo == nil))
        if let halfEcho = half.echo, let fullEcho = full.echo {
            #expect(halfEcho.note == fullEcho.note)
            #expect(fullEcho.levelDb > halfEcho.levelDb)
        }
    }

    @Test func eachCharacterHasTheRoomAndTheEchoOfTheDesign() {
        let expected: [(SoundCharacter, ChainParameters.Reverb.Room, ChainParameters.Echo.Note?, Double)] = [
            (.rapLead, .smallRoom, nil, 90),
            (.rapDouble, .smallRoom, nil, 140),
            (.adLib, .smallRoom, .eighth, 150),
            (.sungLead, .plate, .quarter, 80),
            (.sungHook, .largeHall, .eighth, 80),
            (.backingVoice, .largeHall, nil, 160),
        ]
        for (character, room, note, lowCut) in expected {
            let chain = character.parameters(knobs(1))
            #expect(chain.reverb?.room == room)
            #expect(chain.echo?.note == note)
            #expect(chain.lowCutHz == lowCut)
        }
    }

    @Test func aKnobOutsideItsRangeCountsAsItsNearestEnd() {
        for character in SoundCharacter.allCases {
            #expect(character.parameters(knobs(-1)) == character.parameters(knobs(0)))
            #expect(character.parameters(knobs(7)) == character.parameters(knobs(1)))
        }
    }
}
