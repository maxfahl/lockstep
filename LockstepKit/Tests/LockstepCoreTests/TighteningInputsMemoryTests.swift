import Foundation
import Testing
@testable import LockstepCore

@Suite("TighteningInputsMemory")
struct TighteningInputsMemoryTests {
    /// Three syllables in every recording of a project, by recording id.
    private func markers(of project: Project) -> [UUID: [SyllableMarker]] {
        Dictionary(uniqueKeysWithValues: project.recordings.map { recording in
            (recording.id, [9_000, 30_000, 52_000].map { SyllableMarker(sample: $0, strength: 20) })
        })
    }

    /// What the app worked out before the memory: the inputs of every clip with a timing fix, one by one.
    private func oneByOne(
        _ project: Project, _ markers: [UUID: [SyllableMarker]], _ settings: TightenSettings
    ) -> [ClipTightening.Inputs] {
        project.tracks.flatMap(\.clips).filter(\.hasTimingFix).compactMap { clip in
            guard clip.segments.allSatisfy({ markers[$0.recordingID] != nil }) else { return nil }
            return ClipTightening.Inputs(
                correcting: clip, in: project, markers: markers, settings: settings,
                perBeat: project.grid(for: clip, markers: markers).perBeat, voices: .none
            )
        }
    }

    private func entries(
        _ memory: inout TighteningInputsMemory, _ project: Project, _ markers: [UUID: [SyllableMarker]],
        _ settings: TightenSettings = TightenSettings()
    ) -> [TighteningInputsMemory.Entry] {
        memory.inputs(
            in: ProjectLookup(project), markers: markers, settings: settings,
            perBeat: { project.grid(for: $0, markers: markers).perBeat }, voices: .none
        )
    }

    @Test func givesTheInputsOfEveryClipWithATimingFix() {
        let project = projectWithManyClips()
        let markers = markers(of: project)
        var memory = TighteningInputsMemory()
        let made = entries(&memory, project, markers)
        let fixed = project.tracks.flatMap(\.clips).filter(\.hasTimingFix)
        #expect(made.map(\.inputs) == oneByOne(project, markers, TightenSettings()))
        #expect(made.map(\.clip) == fixed)
        #expect(made.count > 30)
        #expect(memory.builds == made.count)
        // Clips close to each other have less room than the furthest slide, so the rooms are really asked.
        #expect(made.contains { $0.inputs.rooms.contains { $0.after < TightenSettings().maxShiftSamples } })
        #expect(Set(made.map(\.stamp)).count == made.count)
    }

    @Test func aSecondAskingWorksNothingOutAgain() {
        let project = projectWithManyClips()
        let markers = markers(of: project)
        var memory = TighteningInputsMemory()
        let first = entries(&memory, project, markers)
        let builds = memory.builds
        // The same project, but not the same arrays: every track's clips are copied.
        var copy = project
        for track in copy.tracks.indices { copy.tracks[track].clips = Array(copy.tracks[track].clips.map { $0 }) }
        let second = entries(&memory, copy, markers)
        #expect(memory.builds == builds)
        #expect(second.map(\.stamp) == first.map(\.stamp))
        #expect(second.map(\.inputs) == first.map(\.inputs))
    }

    @Test func onlyTheTracksOfAnEditAreWorkedOutAgain() {
        var project = projectWithManyClips()
        let markers = markers(of: project)
        var memory = TighteningInputsMemory()
        let before = entries(&memory, project, markers)
        let builds = memory.builds
        // Two shown clips are deleted, on the second and the fourth track.
        let gone = [project.tracks[1], project.tracks[3]].map { $0.clips.filter(\.isActiveTake)[2].id }
        project.removeClips(Set(gone))
        project.normalizeTakes()
        let after = entries(&memory, project, markers)
        #expect(after.map(\.inputs) == oneByOne(project, markers, TightenSettings()))
        let onChangedTracks = [project.tracks[1], project.tracks[3]].flatMap(\.clips).filter(\.hasTimingFix).count
        #expect(memory.builds == builds + onChangedTracks)
        // The clips of the other tracks keep their stamps, and the clips of these get new ones.
        let untouched = Set((project.tracks[0].clips + project.tracks[2].clips).map(\.id))
        let stampBefore = Dictionary(uniqueKeysWithValues: before.map { ($0.clip.id, $0.stamp) })
        for entry in after {
            #expect((stampBefore[entry.clip.id] == entry.stamp) == untouched.contains(entry.clip.id))
        }
    }

    @Test func everyKindOfEditGivesTheInputsOfTheProjectAsItIs() throws {
        var project = projectWithManyClips()
        let markers = markers(of: project)
        var memory = TighteningInputsMemory()
        _ = entries(&memory, project, markers)
        var edits: [(String, (inout Project) -> Void)] = []
        let first = project.tracks[0].clips.filter(\.isActiveTake)
        edits.append(("a move along the song", { $0.moveClips([first[1].id], bySamples: 30_000, trackSteps: 0, voices: .none) }))
        edits.append(("a move to another track", { $0.moveClips([first[3].id], bySamples: 0, trackSteps: 2, voices: .none) }))
        edits.append(("a split", { project in
            let clip = project.tracks[2].clips.filter(\.isActiveTake)[1]
            project.splitClip(clip.id, at: project.start(of: clip)! + 0.7, voices: .none)
        }))
        edits.append(("Strength", { $0.setClips([first[4].id, first[5].id], strength: 0.4) }))
        edits.append(("Stretch", { $0.setClips([first[4].id], stretch: true) }))
        edits.append(("Off", { $0.setClips([first[5].id], tighten: .off) }))
        edits.append(("another take chosen", { project in
            let group = project.takeGroups(on: project.tracks[3].id)[0]
            project.setActiveTake(group[0].id)
        }))
        edits.append(("a muted clip and a volume", { project in
            project.setClips([first[6].id], muted: true)
            project.tracks[0].clips[0].gainDb = 3
        }))
        edits.append(("a track deleted", { $0.tracks.remove(at: 2) }))
        for (name, edit) in edits {
            edit(&project)
            project.normalizeTakes()
            let made = entries(&memory, project, markers)
            #expect(made.map(\.inputs) == oneByOne(project, markers, TightenSettings()), "after \(name)")
        }
    }

    @Test func whatIsTheSameForEveryClipMakesEverythingAgain() {
        var project = projectWithManyClips()
        var markers = markers(of: project)
        var memory = TighteningInputsMemory()
        var settings = TightenSettings()
        let count = entries(&memory, project, markers, settings).count
        var builds = memory.builds
        func expectAllAgain(_ what: String, _ made: [TighteningInputsMemory.Entry]) {
            #expect(made.map(\.inputs) == oneByOne(project, markers, settings), "after \(what)")
        }

        // The settings.
        settings.maxLineShiftMs = 40
        expectAllAgain("a setting", entries(&memory, project, markers, settings))
        #expect(memory.builds == builds + count)
        builds = memory.builds

        // A beat is moved.
        project.grid?.beats[20].time += 0.02
        expectAllAgain("a moved beat", entries(&memory, project, markers, settings))
        #expect(memory.builds == builds + count)
        builds = memory.builds

        // A syllable is excluded, which is kept with its recording.
        let recording = project.recordings[0]
        project.recordings[0].setExcluded(true, markerAt: 30_000, among: markers[recording.id]!)
        expectAllAgain("an excluded syllable", entries(&memory, project, markers, settings))
        #expect(memory.builds == builds + count)
        builds = memory.builds

        // New markers for one recording.
        markers[recording.id] = [SyllableMarker(sample: 12_000, strength: 20)]
        expectAllAgain("new markers", entries(&memory, project, markers, settings))
        #expect(memory.builds == builds + count)
        builds = memory.builds

        // The song is cut at its start.
        project.songPlace.cutStartSamples = 48_000
        expectAllAgain("a cut of the song", entries(&memory, project, markers, settings))
        #expect(memory.builds == builds + count)
    }

    @Test func aClipHeldAgainstAnotherTrackIsWorkedOutEveryTimeAndFollowsItsLead() {
        var project = projectWithManyClips()
        let markers = markers(of: project)
        // Every clip of the second track aims at the first.
        let lead = project.tracks[0].id
        for clip in project.tracks[1].clips.indices { project.tracks[1].clips[clip].aimTrack = lead }
        var heard: [TimingTargets.Target] = (0..<40).map { TimingTargets.Target(time: 2 + Double($0) * 0.4) }
        func oneByOne() -> [ClipTightening.Inputs] {
            project.tracks.flatMap(\.clips).filter(\.hasTimingFix).compactMap { clip in
                ClipTightening.Inputs(
                    correcting: clip, in: project, markers: markers, settings: TightenSettings(),
                    perBeat: project.grid(for: clip, markers: markers).perBeat,
                    aimedAt: clip.aimTrack == nil ? nil : heard, voices: .none
                )
            }
        }
        var memory = TighteningInputsMemory()
        func ask() -> [TighteningInputsMemory.Entry] {
            memory.inputs(
                in: ProjectLookup(project), markers: markers, settings: TightenSettings(),
                perBeat: { project.grid(for: $0, markers: markers).perBeat },
                aimedAt: { _ in .lead(heard) }, voices: .none
            )
        }
        let first = ask()
        #expect(first.map(\.inputs) == oneByOne())
        #expect(first.contains { $0.inputs.aimedAt?.isEmpty == false })
        let builds = memory.builds
        // The lead is heard elsewhere, and nothing in the project has changed.
        heard = heard.map { TimingTargets.Target(time: $0.time + 0.03) }
        let second = ask()
        #expect(second.map(\.inputs) == oneByOne())
        #expect(second.map(\.inputs) != first.map(\.inputs))
        // Only the track with the aim was worked out again.
        #expect(memory.builds == builds + project.tracks[1].clips.filter(\.hasTimingFix).count)
        // While the lead's syllables are still being looked for, the clips that aim at it are left out, and
        // an aim that cannot be followed is the beat.
        let aiming = Set(project.tracks[1].clips.map(\.id))
        let waiting = memory.inputs(
            in: ProjectLookup(project), markers: markers, settings: TightenSettings(),
            perBeat: { project.grid(for: $0, markers: markers).perBeat }, aimedAt: { _ in .leadNotKnownYet }, voices: .none
        )
        #expect(!waiting.contains { aiming.contains($0.clip.id) })
        #expect(waiting.count == second.count - second.filter { aiming.contains($0.clip.id) }.count)
        let asBeat = memory.inputs(
            in: ProjectLookup(project), markers: markers, settings: TightenSettings(),
            perBeat: { project.grid(for: $0, markers: markers).perBeat }, aimedAt: { _ in .beat }, voices: .none
        )
        #expect(asBeat.map(\.inputs) == self.oneByOne(project, markers, TightenSettings()))
        // Without the lead's syllables handed in, every clip is held against the beat and nothing is
        // worked out for a track that did not change.
        var plain = TighteningInputsMemory()
        let beat = entries(&plain, project, markers)
        #expect(beat.allSatisfy { $0.inputs.aimedAt == nil })
        #expect(beat.map(\.inputs) == self.oneByOne(project, markers, TightenSettings()))
    }

    @Test func aClipWhoseSyllablesAreNotFoundIsLeftOut() {
        let project = projectWithManyClips()
        var markers = markers(of: project)
        let clip = project.tracks[0].clips.first(where: \.hasTimingFix)!
        markers[clip.segments[0].recordingID] = nil
        var memory = TighteningInputsMemory()
        let made = entries(&memory, project, markers)
        #expect(!made.contains { $0.clip.id == clip.id })
        #expect(made.map(\.inputs) == oneByOne(project, markers, TightenSettings()))
        // And nothing at all while the song has no beats.
        var noBeats = project
        noBeats.grid = nil
        #expect(entries(&memory, noBeats, markers).isEmpty)
    }
}
