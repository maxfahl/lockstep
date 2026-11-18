import AVFoundation
import Foundation
import Testing
import LockstepCore
@testable import LockstepAudio

/// The file an exported clip becomes: read back from disk and compared with the offline mix of the clip.
@Suite("Clip export file")
struct ClipExportFileTests {
    /// One step of a 24-bit sample, as a float.
    private let step: Float = 1 / 8_388_608

    /// Made-up voice that is the same on every run, with no silent sample in it.
    private static func voice(_ count: Int) -> [Float] {
        var state: UInt64 = 0x2545_F491_4F6C_DD1D
        return (0..<count).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let value = Float(state >> 40) / Float(1 << 24) - 0.5
            return value == 0 ? 0.25 : value
        }
    }

    /// A project whose one clip is first heard on sample 13,000 of the song and lasts 40,000 samples, on a
    /// track with a slash in its name.
    private static func project() -> (project: Project, clipID: UUID, sounds: [UUID: [Float]]) {
        let recording = Recording(lengthSamples: 96_000, rawStart: 0.25)
        let clip = Clip(segments: [Segment(recordingID: recording.id, inSample: 1_000, outSample: 41_000)])
        let project = Project(
            songName: "Weighted Silence",
            songLengthSamples: 192_000,
            tracks: [Track(name: "Double / lead", clips: [clip])],
            recordings: [recording]
        )
        return (project, clip.id, [recording.id: voice(96_000)])
    }

    private static func temporaryFolder() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "lockstep-export-tests-\(UUID().uuidString)")
    }

    @Test("The file is a plain mono 24-bit WAV, whole frames long, with the clip after its padding")
    func fileHoldsTheClipOnAFrame() throws {
        let made = Self.project()
        let folder = Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let export = try #require(ClipExporter.export(
            made.clipID, in: made.project, recordings: made.sounds, peaks: Clip.unknownPeaks, edgeFadeMs: 5, voices: .none
        ))

        // The folder is not there yet: writing makes it.
        let url = try ClipExporter.write(export, toFolder: folder.appending(path: "exports"))

        #expect(url.lastPathComponent == "Weighted Silence - Double   lead - 01.00.00.06.wav")
        #expect(url.deletingLastPathComponent().lastPathComponent == "exports")
        let file = try AVAudioFile(forReading: url)
        let settings = file.fileFormat.settings
        #expect(file.fileFormat.sampleRate == 48_000)
        #expect(file.fileFormat.channelCount == 1)
        #expect(settings[AVLinearPCMBitDepthKey] as? Int == 24)
        #expect(settings[AVLinearPCMIsFloatKey] as? Bool == false)
        // 25 frames per second: 1,920 samples a frame.
        #expect(Int(file.length) == 22 * 1_920)
        #expect(Int(file.length).isMultiple(of: made.project.resolve.samplesPerFrame))

        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let read = Array(UnsafeBufferPointer(start: try #require(buffer.floatChannelData)[0], count: Int(buffer.frameLength)))
        #expect(read.firstIndex { $0 != 0 } == export.paddingSamples)
        #expect(export.paddingSamples == 1_480)
        let mix = OfflineMix.render(
            made.project, from: 13_000, to: 53_000, recordings: made.sounds, peaks: Clip.unknownPeaks, edgeFadeMs: 5, voices: .none
        )
        let sound = Array(read[1_480..<41_480])
        #expect(zip(sound, mix).allSatisfy { abs($0 - $1) <= step })
        #expect(read[41_480...].allSatisfy { $0 == 0 })

        // Nothing but the 44-byte header and the sound: no `bext` chunk and no other timecode.
        let bytes = try Data(contentsOf: url)
        #expect(bytes.count == 44 + 22 * 1_920 * 3)
        #expect(bytes.range(of: Data("bext".utf8)) == nil)
    }

    @Test("A clip sent with its sound is a stereo 24-bit WAV, whole frames long, with left and right as the finished sound has them")
    func stereoFileHoldsTheFinishedSound() throws {
        let made = Self.project()
        let folder = Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let clip = try #require(made.project.clip(made.clipID))
        // The clip's 40,000 samples and 9,000 more that ring after it.
        let sound = StereoSound(
            left: (0..<49_000).map { Float($0 + 1) / 262_144 },
            right: (0..<49_000).map { -Float($0 + 1) / 524_288 }
        )
        let soundID = UUID()
        var lookup = FinishedSounds()
        lookup.set(FinishedSounds.Sound(id: soundID, drySamples: 40_000, tailSamples: 9_000, pieces: clip.segments, madeFrom: .recordings), for: clip.id)
        let export = try #require(ClipExporter.export(
            made.clipID, in: made.project, recordings: made.sounds, peaks: Clip.unknownPeaks, edgeFadeMs: 5,
            finished: lookup, finishedSamples: [soundID: sound], voices: .none
        ))

        let url = try ClipExporter.write(export, toFolder: folder)

        let file = try AVAudioFile(forReading: url)
        #expect(file.fileFormat.sampleRate == 48_000)
        #expect(file.fileFormat.channelCount == 2)
        #expect(file.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int == 24)
        // 1,480 samples of padding and 49,000 of sound end inside frame 27 of the file.
        #expect(Int(file.length) == 27 * 1_920)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let sides = try #require(buffer.floatChannelData)
        let left = Array(UnsafeBufferPointer(start: sides[0], count: Int(buffer.frameLength)))
        let right = Array(UnsafeBufferPointer(start: sides[1], count: Int(buffer.frameLength)))
        #expect(left[..<1_480].allSatisfy { $0 == 0 } && right[..<1_480].allSatisfy { $0 == 0 })
        #expect(zip(left[1_480..<50_480], sound.left).allSatisfy { abs($0 - $1) <= step })
        #expect(zip(right[1_480..<50_480], sound.right).allSatisfy { abs($0 - $1) <= step })
        #expect(left[50_480...].allSatisfy { $0 == 0 } && right[50_480...].allSatisfy { $0 == 0 })
        #expect(try Data(contentsOf: url).count == 44 + 2 * 27 * 1_920 * 3)
    }

    @Test("A file of the same name is replaced")
    func replacesTheFileThatWasThere() throws {
        let made = Self.project()
        let folder = Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = try #require(ClipExporter.export(
            made.clipID, in: made.project, recordings: made.sounds, peaks: Clip.unknownPeaks, edgeFadeMs: 5, voices: .none
        ))
        let url = try ClipExporter.write(first, toFolder: folder)
        // The same clip, 6 dB quieter: the same name, other sound.
        var quieter = made.project
        quieter.tracks[0].clips[0].gainDb = -6
        let second = try #require(ClipExporter.export(
            made.clipID, in: quieter, recordings: made.sounds, peaks: Clip.unknownPeaks, edgeFadeMs: 5, voices: .none
        ))
        #expect(second.fileName == first.fileName)
        #expect(second.samples != first.samples)

        let again = try ClipExporter.write(second, toFolder: folder)

        #expect(again == url)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == [first.fileName])
        let file = try AVAudioFile(forReading: url)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let read = Array(UnsafeBufferPointer(start: try #require(buffer.floatChannelData)[0], count: Int(buffer.frameLength)))
        #expect(read.count == second.samples.count)
        #expect(zip(read, second.samples).allSatisfy { abs($0 - $1) <= step })
    }

    @Test("An export can be written to a file of the caller's choosing")
    func writesToAGivenFile() throws {
        let made = Self.project()
        let folder = Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let export = try #require(ClipExporter.export(
            made.clipID, in: made.project, recordings: made.sounds, peaks: Clip.unknownPeaks, edgeFadeMs: 5, voices: .none
        ))
        let url = folder.appending(path: "check/sent.wav")

        try ClipExporter.write(export, to: url)

        #expect(try Data(contentsOf: url).count == 44 + export.samples.count * 3)
    }
}
