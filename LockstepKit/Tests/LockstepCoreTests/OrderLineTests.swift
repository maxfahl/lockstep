import Testing
@testable import LockstepCore

/// What happened, in the order it happened.
@MainActor
private final class Log {
    var lines: [String] = []

    func add(_ line: String) {
        lines.append(line)
    }
}

@Suite("OrderLine")
@MainActor
struct OrderLineTests {
    @Test("Each order waits for the one before it, however long that takes")
    func ordersRunInTheOrderTheyWereAskedFor() async {
        let line = OrderLine()
        let log = Log()
        // The first is the slowest: left to themselves the others would overtake it.
        line.tell {
            await log.add("1 starts")
            try await Task.sleep(for: .milliseconds(30))
            await log.add("1 ends")
        }
        line.tell {
            await log.add("2 starts")
            try await Task.sleep(for: .milliseconds(5))
            await log.add("2 ends")
        }
        line.tell { await log.add("3") }

        await line.allDone()
        #expect(log.lines == ["1 starts", "1 ends", "2 starts", "2 ends", "3"])
    }

    @Test("The line counts what is still to do")
    func countsWhatIsLeft() async {
        let line = OrderLine()
        var countsSeen: [Int] = []
        #expect(line.ordersInFlight == 0)

        line.tell { await MainActor.run { countsSeen.append(line.ordersInFlight) } }
        line.tell { await MainActor.run { countsSeen.append(line.ordersInFlight) } }
        line.turn { countsSeen.append(line.ordersInFlight) } afterNothingLeft: { _ in }
        #expect(line.ordersInFlight == 3)

        await line.allDone()
        // Each saw itself and the ones behind it.
        #expect(countsSeen == [3, 2, 1])
        #expect(line.ordersInFlight == 0)
    }

    @Test("Nothing left is told once for a row of orders, and again for the next row")
    func nothingLeftIsToldOncePerRow() async {
        let line = OrderLine()
        var told = 0
        var countsWhenTold: [Int] = []
        line.nothingLeft = {
            told += 1
            countsWhenTold.append(line.ordersInFlight)
        }

        line.tell { try await Task.sleep(for: .milliseconds(5)) }
        line.tell {}
        line.tell {}
        #expect(told == 0)
        await line.allDone()
        #expect(told == 1)

        line.tell {}
        await line.allDone()
        #expect(told == 2)
        #expect(countsWhenTold == [0, 0])
    }

    @Test("An order that fails is reported after nothing left, and the line goes on")
    func failedOrderIsReported() async {
        struct NoSoundOutput: Error {}
        let line = OrderLine()
        let log = Log()
        line.nothingLeft = { log.add("nothing left") }
        line.orderFailed = { error in log.add("failed: \(error is NoSoundOutput)") }

        line.tell { throw NoSoundOutput() }
        await line.allDone()
        #expect(log.lines == ["nothing left", "failed: true"])

        // The one after a failed order runs like any other, and nothing is reported for it.
        line.tell { await log.add("next order") }
        await line.allDone()
        #expect(log.lines == ["nothing left", "failed: true", "next order", "nothing left"])
    }

    @Test("An order that fails with more waiting behind it is reported at once, and nothing left at the end")
    func failedOrderInARow() async {
        struct NoSoundOutput: Error {}
        let line = OrderLine()
        let log = Log()
        line.nothingLeft = { log.add("nothing left") }
        line.orderFailed = { _ in log.add("failed") }

        line.tell { throw NoSoundOutput() }
        line.tell { await log.add("next order") }
        await line.allDone()
        #expect(log.lines == ["failed", "next order", "nothing left"])
    }

    @Test("A turn hands its result on before nothing left is told, after it, or both")
    func turnHandsItsResultOnBeforeAndAfter() async {
        let line = OrderLine()
        let log = Log()
        line.nothingLeft = { log.add("nothing left, \(line.ordersInFlight) in flight") }

        line.tell { await log.add("order before") }
        line.turn {
            log.add("work")
            return 7
        } beforeNothingLeft: { found in
            log.add("before: \(found), \(line.ordersInFlight) in flight")
        } afterNothingLeft: { found in
            log.add("after: \(found)")
        }

        await line.allDone()
        #expect(
            log.lines == [
                "order before",
                "work",
                "before: 7, 0 in flight",
                "nothing left, 0 in flight",
                "after: 7",
            ]
        )
    }

    @Test("What a turn puts in the line before nothing left is told keeps the line from reporting")
    func orderToldFromATurnCounts() async {
        let line = OrderLine()
        let log = Log()
        line.nothingLeft = { log.add("nothing left") }

        // As when the start of a take fails and the player is told to play the clips again.
        line.turn {
            "no microphone"
        } beforeNothingLeft: { found in
            log.add("before: \(found)")
            line.tell { await log.add("order from the turn") }
        } afterNothingLeft: { _ in
            log.add("after")
        }

        // Waiting covers what was asked for so far: the turn, not the order it gave when it ended.
        await line.allDone()
        #expect(log.lines == ["before: no microphone", "after"])
        #expect(line.ordersInFlight == 1)
        await line.allDone()
        #expect(log.lines == ["before: no microphone", "after", "order from the turn", "nothing left"])
    }

    @Test("A turn that gives nothing back is waited for like an order")
    func nextThingWaitsForTheWholeTurn() async {
        let line = OrderLine()
        let log = Log()

        let turn: Task<Void, Never> = line.turn {
            try? await Task.sleep(for: .milliseconds(20))
            return "ended"
        } afterNothingLeft: { found in
            log.add("turn \(found)")
        }
        line.tell { await log.add("next order") }

        await turn.value
        #expect(log.lines == ["turn ended"])
        await line.allDone()
        #expect(log.lines == ["turn ended", "next order"])
    }

    @Test("Whoever waits for the value of a turn hears of it before the next thing starts")
    func valueIsHeardBeforeTheNextThingStarts() async {
        let line = OrderLine()
        let log = Log()

        let measuring = line.turn {
            try? await Task.sleep(for: .milliseconds(20))
            return 5
        } afterNothingLeft: { found in
            found * 2
        }
        // Already waiting in line when the turn ends.
        line.turn { log.add("next thing starts") } afterNothingLeft: { _ in }

        let value = await measuring.value
        log.add("value heard: \(value)")
        await line.allDone()
        #expect(log.lines == ["value heard: 10", "next thing starts"])
    }

    @Test("A turn that is called off is still counted and reported")
    func cancelledTurnStillLeavesTheLine() async {
        let line = OrderLine()
        var told = 0
        line.nothingLeft = { told += 1 }

        let measuring = line.turn {
            // Cut short when the turn is called off.
            try? await Task.sleep(for: .seconds(30))
            return Task.isCancelled ? "called off" : "measured"
        } afterNothingLeft: { found in
            found
        }
        measuring.cancel()

        #expect(await measuring.value == "called off")
        await line.allDone()
        #expect(line.ordersInFlight == 0)
        #expect(told == 1)

        // The line is as good as before.
        var ran = false
        line.turn { ran = true } afterNothingLeft: { _ in }
        await line.allDone()
        #expect(ran)
        #expect(told == 2)
    }
}
