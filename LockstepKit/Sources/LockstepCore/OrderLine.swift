/// A line of things to do, done one after the other in the order they were asked for.
///
/// Lockstep's player works away from the main thread, so what it is told could overtake each
/// other. Everything it is told stands in a line like this one instead: each thing starts when
/// the one before it is over. The line counts what is still to do, and says so once whenever
/// nothing is left, which is when the window may believe what the player says about itself.
///
///     let line = OrderLine()
///     line.nothingLeft = { showWhereThePlayerIs() }
///     line.tell { try await engine.seek(to: 12) }
///     line.tell { try await engine.play(from: 12) }   // starts when the seek is over
///
/// The line lives on the main actor: asking, counting and reporting all happen there, and only
/// the things themselves run elsewhere.
@MainActor
public final class OrderLine {
    /// How many things were asked for and are not over yet.
    public private(set) var ordersInFlight = 0

    /// Called every time the last thing in the line is over and nothing is left to do. While
    /// more is waiting it is not called, so a row of orders reports once, at its end.
    public var nothingLeft: (@MainActor () -> Void)?

    /// Called when an order given with `tell` threw, after `nothingLeft` had its say. The line
    /// goes on with the next thing all the same.
    public var orderFailed: (@MainActor (any Error) -> Void)?

    /// The last thing that was asked for, as the next one waits for it.
    private var last: Task<Void, Never>?

    public init() {}

    /// Puts an order at the end of the line. It runs when everything asked for before it is over.
    public func tell(_ order: @escaping @Sendable () async throws -> Void) {
        turn { () async -> (any Error)? in
            do {
                try await order()
                return nil
            } catch {
                return error
            }
        } afterNothingLeft: { [self] (failure: (any Error)?) in
            if let failure {
                orderFailed?(failure)
            }
        }
    }

    /// Waits until everything asked for so far is over.
    public func allDone() async {
        await last?.value
    }

    /// Takes a turn in the line with work that has something to say when it is over.
    ///
    /// The work starts when everything asked for before it is over, and the next thing waits
    /// for the whole turn. When the work is over the line counts it as done at once, and then,
    /// without anything else getting in between:
    ///
    /// 1. hands what the work found to `beforeNothingLeft`,
    /// 2. calls `nothingLeft` if the line is empty,
    /// 3. hands what the work found to `afterNothingLeft`.
    ///
    /// So the one who took the turn chooses whether its result is known before or after the
    /// line reports that nothing is left. What `beforeNothingLeft` puts in the line itself
    /// counts: the line is then not empty, and reports when that is over.
    ///
    /// - Parameters:
    ///   - work: what the turn does. It is called on the main actor, so it can read what the
    ///     things before it left behind, and waits there for what it does elsewhere.
    ///   - beforeNothingLeft: gets the work's result before the line reports.
    ///   - afterNothingLeft: gets the work's result after the line reported. What it gives back
    ///     is what the turn's task gives.
    /// - Returns: The turn's own task. Cancelling it reaches the work, which may look at
    ///   `Task.isCancelled`; the turn is counted and reported all the same. A turn that gives
    ///   nothing back is itself what the next thing waits for. A turn that gives a value back
    ///   is waited for through a task of its own that ends just after it, so whoever waits
    ///   for the value hears of it before the next thing in the line starts.
    @discardableResult
    public func turn<Found: Sendable, Given: Sendable>(
        _ work: @escaping @MainActor () async -> Found,
        beforeNothingLeft: @escaping @MainActor (Found) -> Void = { _ in },
        afterNothingLeft: @escaping @MainActor (Found) -> Given
    ) -> Task<Given, Never> {
        ordersInFlight += 1
        let before = last
        let turn = Task {
            await before?.value
            let found = await work()
            ordersInFlight -= 1
            beforeNothingLeft(found)
            if ordersInFlight == 0 {
                nothingLeft?()
            }
            return afterNothingLeft(found)
        }
        last = turn as? Task<Void, Never> ?? Task { _ = await turn.value }
        return turn
    }
}
