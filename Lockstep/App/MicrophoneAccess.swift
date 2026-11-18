import AppKit
import AVFoundation

/// The answer to "may Lockstep record?".
enum MicrophoneAnswer: Equatable {
    /// Max allowed the microphone. Recording may start.
    case allowed
    /// The microphone was refused in System Settings or is blocked on this Mac. The alert
    /// that says how to allow it has been shown and closed. Recording does not start.
    case refused
    /// Nobody has decided yet, and this is a `-scratch` run, which never asks: an agent
    /// may be at the Mac with nobody there to answer. A line on standard error says so.
    /// Recording does not start.
    case notAskedInScratchRun
}

/// Asks macOS for the microphone before a recording, at most once, and explains a refusal.
///
/// Record calls `mayRecord()` before it starts anything, and starts only on `.allowed`:
///
///     guard await MicrophoneAccess.mayRecord() == .allowed else { return }
///
/// `isRefused` tells, without asking, whether the microphone is refused right now.
@MainActor
enum MicrophoneAccess {
    /// True when the microphone is refused or blocked. Reading it never asks.
    static var isRefused: Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .denied, .restricted: true
        default: false
        }
    }

    /// Whether recording may start. The first time, macOS asks Max; after that his answer
    /// stands until he changes it in System Settings. While it is refused, every call
    /// shows the alert again and returns `.refused` once it is closed.
    static func mayRecord() async -> MicrophoneAnswer {
        // An agent's run with `-recordTake` records from a sound file. No microphone is opened, so
        // there is nothing to allow, and macOS must not be asked.
        if FileMicrophone.current?.recorder != nil { return .allowed }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return .allowed
        case .notDetermined:
            if LaunchOptions.current.isScratch {
                FileHandle.standardError.write(Data(
                    "Lockstep: did not ask for the microphone because this is a -scratch run, so recording does not start.\n".utf8
                ))
                return .notAskedInScratchRun
            }
            if await askMacOS() { return .allowed }
            await explainRefusal()
            return .refused
        default:
            await explainRefusal()
            return .refused
        }
    }

    /// Shows the permission question of macOS and waits for the answer.
    ///
    /// The answer comes back on a thread of the system's, so the block is made here,
    /// outside the main actor, and only hands the answer on.
    private nonisolated static func askMacOS() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { @Sendable granted in
                continuation.resume(returning: granted)
            }
        }
    }

    /// The alert for a refused microphone, attached to the window when there is one.
    private static func explainRefusal() async {
        let alert = NSAlert()
        alert.messageText = "Lockstep is not allowed to use the microphone."
        alert.informativeText = "Allow Lockstep under Privacy & Security > Microphone in System Settings, then try again."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        let window = NSApp.keyWindow ?? NSApp.mainWindow
            ?? NSApp.windows.first { $0.isVisible && !($0 is NSPanel) }
        let response = if let window {
            await alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
        guard response == .alertFirstButtonReturn else { return }
        NSWorkspace.shared.open(microphoneSettings)
    }

    /// Privacy and Security > Microphone in System Settings.
    private static let microphoneSettings = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
    )!
}
