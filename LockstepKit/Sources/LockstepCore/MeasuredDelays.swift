import Foundation

extension DevicePair {
    /// What a pair's measured delay is kept under: "<output UID>|<input UID>". The names are not part of it,
    /// so a device that Max renames keeps its delay.
    public var key: String {
        "\(outputUID)|\(inputUID)"
    }
}

/// The delay that was measured for one pair of headphones and microphone: one row of "Measured delays" in the
/// Recording pane of the settings.
public struct MeasuredDelay: Sendable, Equatable, Identifiable {
    /// The sound output and the microphone, with the names they had when the delay was measured.
    public var devices: DevicePair
    /// How late a sound arrives in a recording made with these devices, in seconds.
    public var delay: Double
    /// When it was measured.
    public var measured: Date
    /// Whether the sound output is a wireless one (Bluetooth, such as AirPods). Its delay changes with every
    /// connection, so this delay is used only in the connection it was measured in.
    public var wireless: Bool

    public var id: String { devices.key }

    public init(devices: DevicePair, delay: Double, measured: Date, wireless: Bool) {
        self.devices = devices
        self.delay = delay
        self.measured = measured
        self.wireless = wireless
    }
}

/// Every measured delay, by the key of its pair of devices. This is the value the settings store keeps, as one
/// setting. The app does not use it directly: it asks `AppSettings` (`delay(for:)`, `setDelay`, `removeDelay`,
/// `measuredDelays`).
public struct MeasuredDelays: SettingValue {
    public var entries: [String: MeasuredDelay]

    public init(entries: [String: MeasuredDelay] = [:]) {
        self.entries = entries
    }

    /// Reads the table as the store keeps it. A row that cannot be read (no devices, or no usable delay) is
    /// left out and the others are kept.
    public init?(stored: Any) {
        guard let table = stored as? [String: Any] else { return nil }
        var entries: [String: MeasuredDelay] = [:]
        for row in table.values {
            guard
                let row = row as? [String: Any],
                let outputUID = row["outputUID"] as? String, !outputUID.isEmpty,
                let inputUID = row["inputUID"] as? String, !inputUID.isEmpty,
                let delay = row["delay"].flatMap({ Double(stored: $0) }), delay >= 0
            else { continue }
            let devices = DevicePair(
                outputUID: outputUID,
                outputName: row["outputName"] as? String ?? "",
                inputUID: inputUID,
                inputName: row["inputName"] as? String ?? ""
            )
            entries[devices.key] = MeasuredDelay(
                devices: devices,
                delay: delay,
                measured: row["measured"] as? Date ?? .distantPast,
                // A row that does not say is taken to be wireless: then its delay is not used until it has
                // been measured again, which is the careful side to be wrong on.
                wireless: row["wireless"].flatMap { Bool(stored: $0) } ?? true
            )
        }
        self.entries = entries
    }

    public var storedForm: Any {
        entries.mapValues { entry -> [String: Any] in
            [
                "outputUID": entry.devices.outputUID,
                "outputName": entry.devices.outputName,
                "inputUID": entry.devices.inputUID,
                "inputName": entry.devices.inputName,
                "delay": entry.delay,
                "measured": entry.measured,
                "wireless": entry.wireless,
            ]
        }
    }
}

extension SettingKey where Value == MeasuredDelays {
    /// The measured delays of every pair of headphones and microphone. App-wide, not part of a project.
    public static var measuredDelays: SettingKey {
        SettingKey("recording.measuredDelays", pane: .recording, default: MeasuredDelays())
    }
}

// MARK: Asking for a delay and keeping one

/// The delay of a pair of headphones and microphone is measured once (Calibrate) and kept here, so every
/// recording made with that pair can be moved back by it.
///
///     settings.setDelay(0.0123, for: devices, wireless: false)    // after a calibration
///     settings.delay(for: devices)                               // 0.0123, also after the app is restarted
///     settings.removeDelay(for: devices)                         // "Remove" in the settings
///
/// A wireless output (AirPods) is different: its delay changes every time it connects. So a wireless delay
/// is used only in the connection it was measured in:
///
///     settings.setDelay(0.217, for: airPods, wireless: true)
///     settings.delay(for: airPods)                                // 0.217
///     settings.endWirelessConnections(except: connectedNow)       // the AirPods are not among them any more
///     settings.delay(for: airPods)                                // nil, until it is measured again
///
/// and after a restart of the app it is nil as well. The row stays in the list either way, with its old value,
/// so Max sees that the pair was measured and can measure it again.
extension AppSettings {
    /// The delay to take off recordings made with this pair, in seconds, or nil when there is none to use:
    /// the pair was never measured, or it is a wireless pair that was measured in an earlier connection. With
    /// nil, a new recording gets delay 0 and the window reads "Not calibrated".
    ///
    /// A view that reads it is drawn again when the answer changes.
    public func delay(for devices: DevicePair) -> Double? {
        guard let entry = self[.measuredDelays].entries[devices.key] else { return nil }
        if entry.wireless, !wirelessDelaysInUse.contains(devices.key) { return nil }
        return entry.delay
    }

    /// Keeps a delay that was just measured for this pair, in place of an earlier one. It is in use at once.
    ///
    /// - Parameters:
    ///   - delay: in seconds. Something that is not a delay (negative, or not a number) is not kept.
    ///   - devices: the pair it was measured with. A pair without ids is not kept.
    ///   - wireless: whether the sound output is a Bluetooth device (`CalibrationOutcome` says). Such a delay
    ///     stops being used when the output disconnects and when the app is closed.
    ///   - measured: when it was measured. Now, unless a test says otherwise.
    public func setDelay(_ delay: Double, for devices: DevicePair, wireless: Bool, measured: Date = Date()) {
        guard delay.isFinite, delay >= 0, !devices.outputUID.isEmpty, !devices.inputUID.isEmpty else { return }
        var table = self[.measuredDelays]
        table.entries[devices.key] = MeasuredDelay(devices: devices, delay: delay, measured: measured, wireless: wireless)
        self[.measuredDelays] = table
        if wireless {
            wirelessDelaysInUse.insert(devices.key)
        } else {
            wirelessDelaysInUse.remove(devices.key)
        }
    }

    /// Forgets the delay of this pair. Recordings that already have it keep it.
    public func removeDelay(for devices: DevicePair) {
        var table = self[.measuredDelays]
        table.entries[devices.key] = nil
        self[.measuredDelays] = table
        wirelessDelaysInUse.remove(devices.key)
    }

    /// Every measured delay, for the list in the settings: by the name of the output, then of the microphone.
    /// A wireless row is listed also while its delay is not in use.
    public var measuredDelays: [MeasuredDelay] {
        self[.measuredDelays].entries.values.sorted { one, other in
            let names = (one.devices.outputName, one.devices.inputName, one.id)
            return names < (other.devices.outputName, other.devices.inputName, other.id)
        }
    }

    /// Call when the Mac's sound devices have changed: a wireless delay whose output is not connected any
    /// more stops being used, and stays unused when the output connects again, until it is measured again.
    ///
    /// - Parameter connected: the ids of every sound device connected now (`AudioDevices.connectedUIDs()`).
    public func endWirelessConnections(except connected: Set<String>) {
        let table = self[.measuredDelays].entries
        let still = wirelessDelaysInUse.filter { key in
            table[key].map { connected.contains($0.devices.outputUID) } ?? false
        }
        // Changed only when something ended, so views that show a delay are not drawn again for nothing.
        if still != wirelessDelaysInUse {
            wirelessDelaysInUse = still
        }
    }
}
