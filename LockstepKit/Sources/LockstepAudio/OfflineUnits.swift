import AVFoundation
import LockstepCore
import Synchronization

/// Runs a sound through Apple's audio units, away from any sound device.
///
/// Each call makes an audio engine of its own in manual rendering mode (offline), hands it the sound, takes
/// what comes out and lets the engine go. Nothing is kept between calls, so the same call always gives the
/// same samples, and calls may run at the same time on any threads. Nothing here can be heard: an engine in
/// this mode has no sound device.
///
///     let equalizer = AVAudioUnitEQ(numberOfBands: 1)     // a unit made for this one call
///     let cut = OfflineUnits.render(voice, through: [equalizer])
///
/// Making the engine costs about a millisecond (measured on 15 November 2026), which is why none is kept.
enum OfflineUnits {
    /// The most samples asked of the engine at a time.
    private static let blockFrames: AVAudioFrameCount = 4096

    /// The sound through the units, one after the other.
    ///
    /// - Parameters:
    ///   - units: made for this call. A unit belongs to one engine, so it cannot be used again.
    ///   - extra: how many samples longer the answer is than the sound, with silence going in: room for what
    ///     rings after it.
    ///   - started: called once the engine has started and before any sound is asked of it. A reverb's room
    ///     must be chosen here: a factory preset loaded earlier is lost when the engine starts (measured).
    /// - Returns: nil when the engine could not be made or did not answer.
    static func render(
        _ sound: StereoSound,
        through units: [AVAudioUnit],
        extra: Int = 0,
        started: () -> Void = {}
    ) -> StereoSound? {
        let frames = sound.left.count + max(extra, 0)
        guard frames > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: Lockstep.sampleRate, channels: 2)
        else { return nil }

        let engine = AVAudioEngine()
        do {
            // Before anything else: an engine in this mode never opens a sound device.
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: blockFrames)
        } catch {
            return nil
        }
        let source = AVAudioSourceNode(format: format, renderBlock: feed(Feed(sound)))
        engine.attach(source)
        var last: AVAudioNode = source
        for unit in units {
            engine.attach(unit)
            engine.connect(last, to: unit, format: format)
            last = unit
        }
        engine.connect(last, to: engine.mainMixerNode, format: format)

        guard (try? engine.start()) != nil,
              let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: blockFrames)
        else { return nil }
        defer { engine.stop() }
        started()

        var left: [Float] = []
        var right: [Float] = []
        left.reserveCapacity(frames)
        right.reserveCapacity(frames)
        while left.count < frames {
            let wanted = min(AVAudioFrameCount(frames - left.count), blockFrames)
            guard (try? engine.renderOffline(wanted, to: buffer)) == .success, buffer.frameLength > 0,
                  let sides = buffer.floatChannelData
            else { return nil }
            let produced = Int(buffer.frameLength)
            left.append(contentsOf: UnsafeBufferPointer(start: sides[0], count: produced))
            right.append(contentsOf: UnsafeBufferPointer(start: sides[1], count: produced))
        }
        return StereoSound(left: left, right: right)
    }

    /// The sound an engine is fed, and how much of it the engine has taken.
    private final class Feed: Sendable {
        let sound: StereoSound
        let taken = Mutex(0)

        init(_ sound: StereoSound) {
            self.sound = sound
        }
    }

    /// For the engine's source: hands out the sound from its start, then silence. The engine calls it on the
    /// thread that asks for sound, and it touches only the feed, whose count is behind a lock.
    private nonisolated static func feed(_ feed: Feed) -> AVAudioSourceNodeRenderBlock {
        { @Sendable _, _, frameCount, audioBufferList in
            let wanted = Int(frameCount)
            let start = feed.taken.withLock { taken in
                defer { taken += wanted }
                return taken
            }
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            for (side, buffer) in buffers.enumerated() {
                guard let data = buffer.mData else { continue }
                let out = data.assumingMemoryBound(to: Float.self)
                let samples = side == 0 ? feed.sound.left : feed.sound.right
                let there = max(min(samples.count - start, wanted), 0)
                samples.withUnsafeBufferPointer { samples in
                    if there > 0, let base = samples.baseAddress {
                        out.update(from: base + start, count: there)
                    }
                }
                if there < wanted {
                    (out + there).update(repeating: 0, count: wanted - there)
                }
            }
            return noErr
        }
    }
}
