import Foundation

/// The panes of the settings window, in the order of their tabs.
public enum SettingsPane: String, CaseIterable, Sendable {
    case general
    case beatsAndClick
    case recording
    case volume
    case timing
    case davinci
    case shortcuts

    /// The pane's name: the title of its tab, and of the window while it is shown.
    public var title: String {
        switch self {
        case .general: "General"
        case .beatsAndClick: "Beats and Click"
        case .recording: "Recording"
        case .volume: "Volume"
        case .timing: "Timing"
        case .davinci: "DaVinci"
        case .shortcuts: "Shortcuts"
        }
    }
}

/// A kind of value a setting can have, and how the settings store keeps it.
///
/// The store is a property list, so a value is kept as a truth value, a number or a
/// text. A choice (an enum whose raw value is a text) is kept as that text and needs
/// nothing but `extension MyChoice: SettingValue {}`.
public protocol SettingValue: Sendable, Equatable {
    /// The value a stored object stands for, or nil when the object is something else.
    init?(stored: Any)
    /// The value as the store keeps it.
    var storedForm: Any { get }
}

extension Bool: SettingValue {
    public init?(stored: Any) {
        if let value = stored as? Bool {
            self = value
        } else if let text = stored as? String {
            // What `defaults write` leaves when it is not told the kind of value.
            switch text.lowercased() {
            case "1", "true", "yes": self = true
            case "0", "false", "no": self = false
            default: return nil
            }
        } else {
            return nil
        }
    }

    public var storedForm: Any { self }
}

extension Double: SettingValue {
    public init?(stored: Any) {
        let number: Double?
        if let value = stored as? Double {
            number = value
        } else if let text = stored as? String {
            number = Double(text)
        } else {
            number = nil
        }
        guard let number, number.isFinite else { return nil }
        self = number
    }

    public var storedForm: Any { self }
}

extension Int: SettingValue {
    public init?(stored: Any) {
        // A number with decimals, written by hand, counts as the nearest whole number.
        guard let number = Double(stored: stored), abs(number) < 1e15 else { return nil }
        self = Int(number.rounded())
    }

    public var storedForm: Any { self }
}

extension String: SettingValue {
    public init?(stored: Any) {
        guard let text = stored as? String else { return nil }
        self = text
    }

    public var storedForm: Any { self }
}

extension SettingValue where Self: RawRepresentable, RawValue == String {
    public init?(stored: Any) {
        guard let text = stored as? String else { return nil }
        self.init(rawValue: text)
    }

    public var storedForm: Any { rawValue }
}

/// What every setting has, whatever kind of value it holds.
public protocol AnySettingKey: Sendable {
    /// The name the value is stored under, such as "beats.maxGapBeats".
    var name: String { get }
    /// The pane of the settings window the setting is in.
    var pane: SettingsPane { get }
}

/// One setting: its name in the settings store, its pane, what it starts as and how
/// far it can go.
///
///     settings[.maxGapBeats]                  // 32 until Max changes it
///     SettingKey.maxGapBeats.range            // 0...64, for the control in the pane
///     SettingKey.followPlayhead.choices       // to the middle, smooth, off
///
/// The settings themselves are listed in `AppSettings.swift`.
public struct SettingKey<Value: SettingValue>: AnySettingKey, Hashable {
    public let name: String
    public let pane: SettingsPane
    /// What the setting is until Max changes it, and again after Restore Defaults.
    public let defaultValue: Value
    /// The values to choose from, for a setting that is one of a few. Empty otherwise.
    public let choices: [Value]
    /// The distance between two values next to each other, for a setting that goes in
    /// steps. Nil otherwise.
    public let step: Value?

    private let lowest: Value?
    private let highest: Value?
    private let fit: @Sendable (Value) -> Value

    /// A setting that may hold any value of its kind: on or off, or a text.
    public init(_ name: String, pane: SettingsPane, default defaultValue: Value) {
        self.init(name, pane, defaultValue, choices: [], lowest: nil, highest: nil, step: nil) { $0 }
    }

    /// A setting that is one of a few choices. Anything else counts as the default.
    public init(_ name: String, pane: SettingsPane, default defaultValue: Value, choices: [Value]) {
        self.init(name, pane, defaultValue, choices: choices, lowest: nil, highest: nil, step: nil) { value in
            choices.contains(value) ? value : defaultValue
        }
    }

    private init(
        _ name: String,
        _ pane: SettingsPane,
        _ defaultValue: Value,
        choices: [Value],
        lowest: Value?,
        highest: Value?,
        step: Value?,
        fit: @escaping @Sendable (Value) -> Value
    ) {
        self.name = name
        self.pane = pane
        self.defaultValue = defaultValue
        self.choices = choices
        self.lowest = lowest
        self.highest = highest
        self.step = step
        self.fit = fit
    }

    /// The nearest value the setting allows. Every read and every write goes through
    /// it, so no part of the app ever sees a value outside the limits.
    public func fitted(_ value: Value) -> Value {
        fit(value)
    }

    /// Two keys with the same name are the same setting.
    public static func == (one: SettingKey, other: SettingKey) -> Bool {
        one.name == other.name
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(name)
    }
}

extension SettingKey where Value: Comparable {
    /// The lowest and the highest value, for a setting with limits. Nil otherwise.
    public var range: ClosedRange<Value>? {
        guard let lowest, let highest else { return nil }
        return lowest...highest
    }
}

extension SettingKey where Value == Int {
    /// A whole number inside `range`. With a step, only the lowest value and every
    /// `step` above it are allowed: 9...33 in steps of 2 is the odd numbers from 9 to 33.
    public init(
        _ name: String,
        pane: SettingsPane,
        default defaultValue: Int,
        range: ClosedRange<Int>,
        step: Int = 1
    ) {
        let step = max(step, 1)
        self.init(
            name, pane, defaultValue,
            choices: [], lowest: range.lowerBound, highest: range.upperBound, step: step
        ) { value in
            let inside = min(max(value, range.lowerBound), range.upperBound)
            let steps = (Double(inside - range.lowerBound) / Double(step)).rounded()
            return min(range.lowerBound + Int(steps) * step, range.upperBound)
        }
    }
}

extension SettingKey where Value == Double {
    /// A number inside `range`.
    public init(_ name: String, pane: SettingsPane, default defaultValue: Double, range: ClosedRange<Double>) {
        self.init(
            name, pane, defaultValue,
            choices: [], lowest: range.lowerBound, highest: range.upperBound, step: nil
        ) { value in
            min(max(value, range.lowerBound), range.upperBound)
        }
    }
}
