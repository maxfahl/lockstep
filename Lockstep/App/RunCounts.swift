import Foundation

/// Three counts of what one run of Lockstep did, for `Scripts/same-behaviour.sh`: how often what the
/// window draws was written (`WindowState.content`), how many orders the player was told
/// (`Player.tell`), and how often the window was worked out (`MainWindow.body`).
///
/// They are there to compare two builds that should behave the same. A change that only moves code
/// leaves all three as they were; one that writes `content` an extra time, tells the player twice or
/// makes the window work itself out more often shows here, although nothing printed or saved differs.
///
/// Each of the three places calls its one function here and nothing else, so the counting follows
/// the code when it is moved. Nothing reads the counts but `tellAgent`, and nothing in the window
/// depends on them: this is a plain object on purpose, not an observed one, so counting never makes
/// a view draw again.
///
/// Only a scratch run prints them, in one line on standard error when Lockstep quits through its
/// own Quit. Max's own run counts too, which costs three additions, and prints nothing.
@MainActor
final class RunCounts {
    static let shared = RunCounts()

    private var contentWrites = 0
    private var playerOrders = 0
    private var windowBodies = 0

    /// `WindowState.content` was written, the whole of it or one field.
    func contentWritten() { contentWrites += 1 }

    /// The player was handed an order through `Player.tell`.
    func playerTold() { playerOrders += 1 }

    /// `MainWindow.body` was worked out.
    func windowWorkedOut() { windowBodies += 1 }

    /// Says the three counts on standard error, in a scratch run. Called once, after everything
    /// else that quitting does.
    ///
    /// - Parameter voices: how many voices were made and read in the run (`VoiceModel.countsForAgent`), added
    ///   to the line when the run had a track with a Voice. A run without one prints the line it always did.
    func tellAgent(voices: String? = nil) {
        guard LaunchOptions.current.isScratch else { return }
        var line = "counted \(contentWrites) writes of what the window shows, \(playerOrders) orders to the player, "
            + "\(windowBodies) times the window was worked out"
        if let voices {
            line += ", \(voices)"
        }
        FileHandle.standardError.write(Data("Lockstep: \(line)\n".utf8))
    }
}
