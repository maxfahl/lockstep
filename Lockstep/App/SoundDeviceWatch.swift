import CoreAudio
import Foundation

/// Tells when the Mac starts using another sound output or another microphone, and when a
/// sound device is connected or disconnected.
///
///     SoundDeviceWatch.start { model.soundDevicesChanged() }
///
/// It only listens to what the Mac says about its devices. It opens no device, makes no
/// sound and needs no permission. It listens for as long as the app runs.
enum SoundDeviceWatch {
    /// The three things listened for: the sound output in use, the microphone in use, and
    /// the list of connected devices.
    private static let selectors: [AudioObjectPropertySelector] = [
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioHardwarePropertyDefaultInputDevice,
        kAudioHardwarePropertyDevices,
    ]

    /// Core Audio reports on this queue, one change after the other.
    private static let queue = DispatchQueue(label: "se.maxfahl.lockstep.sound-device-watch")

    /// Starts listening. `onChange` is called on the main actor a moment after each change.
    /// One switch of headphones can be reported as several changes.
    nonisolated static func start(telling onChange: @escaping @MainActor @Sendable () -> Void) {
        let report = report(to: onChange)
        for selector in selectors {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, report)
        }
    }

    /// What Core Audio calls when something changed. It is called on a thread that is not
    /// the app's own, so it is made here, outside the main actor, and only passes the news on.
    private nonisolated static func report(
        to onChange: @escaping @MainActor @Sendable () -> Void
    ) -> @Sendable (UInt32, UnsafePointer<AudioObjectPropertyAddress>) -> Void {
        { @Sendable _, _ in
            Task { @MainActor in
                onChange()
            }
        }
    }
}
