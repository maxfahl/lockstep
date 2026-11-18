import CoreAudio
import LockstepCore

/// Reads which sound devices the Mac is using right now. Lockstep offers no choice of its own: it follows the
/// Mac's sound output and microphone, which Max's `audio-priority` helper sets.
///
/// Asking these questions opens no device and needs no permission.
public enum AudioDevices {
    /// The Mac's current sound output and microphone, each with the id that stays the same across restarts and
    /// the name macOS shows. Nil when the Mac has no output or no microphone, or does not say which they are.
    public static func currentPair() -> DevicePair? {
        guard
            let output = defaultDevice(kAudioHardwarePropertyDefaultOutputDevice),
            let input = defaultDevice(kAudioHardwarePropertyDefaultInputDevice),
            let outputUID = text(kAudioDevicePropertyDeviceUID, of: output),
            let inputUID = text(kAudioDevicePropertyDeviceUID, of: input)
        else { return nil }
        return DevicePair(
            outputUID: outputUID,
            outputName: text(kAudioObjectPropertyName, of: output) ?? "",
            inputUID: inputUID,
            inputName: text(kAudioObjectPropertyName, of: input) ?? ""
        )
    }

    /// Whether the connected sound device with this id is a wireless one (Bluetooth, such as AirPods). False for
    /// every other device, and for an id that no connected device has.
    ///
    /// A wireless device's delay changes from one connection to the next, so a delay measured with it is only
    /// good until it disconnects (`AppSettings.setDelay(_:for:wireless:measured:)`).
    public static func isWireless(uid: String) -> Bool {
        guard let device = devices().first(where: { text(kAudioDevicePropertyDeviceUID, of: $0) == uid }) else {
            return false
        }
        var address = address(kAudioDevicePropertyTransportType)
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr else { return false }
        return transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    /// The ids of every sound device that is connected right now, the ones that stay the same across restarts.
    /// A wireless device that is missing here has disconnected, and the delays measured with it no longer hold
    /// (`AppSettings.endWirelessConnections(except:)`).
    public static func connectedUIDs() -> Set<String> {
        Set(devices().compactMap { text(kAudioDevicePropertyDeviceUID, of: $0) })
    }

    /// Every sound device the Mac has right now.
    private static func devices() -> [AudioDeviceID] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard !devices.isEmpty, AudioObjectGetPropertyData(system, &address, 0, nil, &size, &devices) == noErr else {
            return []
        }
        // A device can go away between the two questions. Then fewer ids were filled in than there was room for.
        return Array(devices.prefix(Int(size) / MemoryLayout<AudioDeviceID>.size))
    }

    /// The device the Mac uses for output or for input, or nil when there is none.
    private static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        var address = address(selector)
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard status == noErr, device != kAudioObjectUnknown else { return nil }
        return device
    }

    /// One piece of text about a device, or nil when the device does not give it.
    private static func text(_ selector: AudioObjectPropertySelector, of device: AudioDeviceID) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        // The system hands the text over for us to release, which `takeRetainedValue` does.
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}
