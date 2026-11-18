import Foundation
import Testing

/// `Fixtures/voice-engine-lines.jsonl` holds one example of every line Lockstep and the voice helper send
/// each other.
/// The Swift side (`VoiceEngineMessage`) and the Python side (`lockstep_voice.py`) are each tested against
/// that one file. This suite only says that the file itself is whole: it knows nothing of either side.
@Suite("The file of the voice helper's lines")
struct VoiceEngineLinesFixtureTests {
    /// Where the file is, for the tests of the Swift side too.
    static let file = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/voice-engine-lines.jsonl")

    /// The file's lines, without the empty one after the last line break.
    static func lines() throws -> [String] {
        try String(contentsOf: file, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init)
    }

    /// What says which line it is: the event of a line from the helper, or the op of one from Lockstep.
    private func kind(of line: [String: Any]) -> String {
        if let event = line["event"] as? String { return "event \(event)" }
        if let op = line["op"] as? String { return "op \(op)" }
        return "neither"
    }

    @Test func itHasOneExampleOfEveryLineOfTheTableWithExactlyItsFields() throws {
        let lines = try Self.lines().map { text in
            try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any], "not one JSON object: \(text)")
        }
        // In the order of the table.
        let fields: [(kind: String, keys: Set<String>)] = [
            ("event ready", ["event", "protocol", "engine", "revision", "device", "loadSeconds"]),
            ("op convert", ["op", "job", "engine", "revision", "source", "reference", "pitch", "output"]),
            ("event progress", ["event", "job", "fraction"]),
            ("event done", ["event", "job", "samples", "seconds"]),
            ("event failed", ["event", "job", "reason"]),
            ("op cancel", ["op", "job"]),
            ("event cancelled", ["event", "job"]),
            ("op quit", ["op"]),
        ]
        #expect(lines.map(kind(of:)) == fields.map(\.kind))
        for (line, expected) in zip(lines, fields) {
            #expect(Set(line.keys) == expected.keys, "the fields of \(expected.kind)")
        }
    }

    @Test func everyLineIsInTheOneFormBothSidesWrite() throws {
        let text = try String(contentsOf: Self.file, encoding: .utf8)
        #expect(text.hasSuffix("\n"))
        for line in try Self.lines() {
            #expect(line.hasPrefix("{") && line.hasSuffix("}"))
            // No space outside a text, and no escaped slash: what `JSONEncoder` writes with sorted keys and
            // `.withoutEscapingSlashes`, and Python's `json.dumps` with `sort_keys`, compact separators and
            // `ensure_ascii=False`.
            #expect(!line.contains("\": ") && !line.contains(", \"") && !line.contains("\\/"))
            // The keys are in alphabetical order.
            let keys = line.matches(of: /"([A-Za-z]+)":/).map { String($0.1) }
            #expect(keys == keys.sorted(), "the order of the keys in \(line)")
            #expect(Set(keys).count == keys.count)
        }
    }

    @Test func theExamplesAreTheOnesTheSwiftAndThePythonSideCanBothPrint() throws {
        let lines = try Self.lines().map { try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
        // A pitch on a half step, so no side writes it as a whole number and the other with a decimal.
        let convert = lines[1]
        let pitch = try #require(convert["pitch"] as? Double)
        #expect(pitch == -1.5)
        // The job's own id is in the name of its output, which is not the finished voice's name.
        let job = try #require(convert["job"] as? String)
        let output = try #require(convert["output"] as? String)
        #expect(output.hasSuffix(".\(job).partial"))
        #expect(UUID(uuidString: job) != nil)
        // A path with a letter outside ASCII, as a song of Max's can have.
        #expect((convert["source"] as? String)?.contains("å") == true)
        // The answer and the progress belong to that job.
        #expect(lines[2]["job"] as? String == job)
        #expect(lines[3]["job"] as? String == job)
        #expect(lines[3]["samples"] as? Int == 153_600)
        // What is cancelled is what was asked to be.
        #expect(lines[5]["job"] as? String == lines[6]["job"] as? String)
    }
}
