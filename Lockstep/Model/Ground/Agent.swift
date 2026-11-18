import Foundation

/// The agent that started Lockstep, in a run with launch arguments: it reads what Lockstep
/// did on standard error. Every part tells it through here, so the lines look the same.
enum Agent {
    /// One line on standard error, for the agent that started Lockstep.
    static func tell(_ line: String) {
        FileHandle.standardError.write(Data("Lockstep: \(line)\n".utf8))
    }
}
