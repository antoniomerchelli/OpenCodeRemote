import XCTest
@testable import OpenCodeRemote

// MARK: - Test helpers

/// Contatore actor per verificare quante operazioni sono state eseguite.
private actor Counter {
    private(set) var value = 0

    func inc() {
        value += 1
    }
}

/// Traccia concorrenza: quante operazioni girano in parallelo (max), e quante
/// sono terminate.
private actor ConcurrencyTracker {
    private(set) var current = 0
    private(set) var max = 0
    private(set) var completions = 0

    func begin() {
        current += 1
        max = Swift.max(max, current)
    }

    func end() {
        current -= 1
        completions += 1
    }

    func sleepMS(_ ms: Int) async {
        try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
    }
}

// MARK: - BootstrapQueueTests
//
// Copertura di `BootstrapQueue`: drain in batch di 2, FIFO per-directory,
// suspend/resume, contatori e idempotenza.

final class BootstrapQueueTests: XCTestCase {

    private func waitForIdle(_ queue: BootstrapQueue, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let pending = await queue.pendingCount()
            let running = await queue.runningCount()
            if pending == 0 && running == 0 { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("coda non drenata entro il timeout", file: file, line: line)
    }

    // MARK: - Configurazione

    func testMaxConcurrent_shouldBeTwo() {
        XCTAssertEqual(BootstrapQueue.maxConcurrent, 2)
    }

    // MARK: - Esecuzione

    func testPushThenDrain_shouldExecuteAllOperations() async {
        let counter = Counter()
        let queue = BootstrapQueue()

        for index in 0..<5 {
            await queue.push(directory: "dir-\(index)") { await counter.inc() }
        }
        let initialPending = await queue.pendingCount()
        XCTAssertEqual(initialPending, 5)

        await queue.drain()
        await waitForIdle(queue)

        let executed = await counter.value
        let pendingAfter = await queue.pendingCount()
        let runningAfter = await queue.runningCount()
        XCTAssertEqual(executed, 5)
        XCTAssertEqual(pendingAfter, 0)
        XCTAssertEqual(runningAfter, 0)
    }

    func testDrain_whenCalledTwice_shouldNotDuplicateOperations() async {
        let counter = Counter()
        let queue = BootstrapQueue()

        await queue.push(directory: "a") { await counter.inc() }
        await queue.push(directory: "b") { await counter.inc() }

        await queue.drain()
        await queue.drain() // no-op
        await waitForIdle(queue)

        let executed = await counter.value
        XCTAssertEqual(executed, 2)
    }

    func testDrain_whenEmpty_shouldDoNothing() async {
        let queue = BootstrapQueue()
        await queue.drain()
        let pending = await queue.pendingCount()
        let running = await queue.runningCount()
        XCTAssertEqual(pending, 0)
        XCTAssertEqual(running, 0)
    }

    // MARK: - Concorrenza

    func testSameDirectory_shouldNeverRunConcurrently() async {
        let tracker = ConcurrencyTracker()
        let queue = BootstrapQueue()

        for _ in 0..<4 {
            await queue.push(directory: "dirA") {
                await tracker.begin()
                await tracker.sleepMS(30)
                await tracker.end()
            }
        }

        await queue.drain()
        await waitForIdle(queue)

        let max = await tracker.max
        let completions = await tracker.completions
        XCTAssertEqual(max, 1, "operazioni della stessa directory devono essere seriali")
        XCTAssertEqual(completions, 4)
    }

    func testAcrossDirectories_shouldCapAtMaxConcurrent() async {
        let tracker = ConcurrencyTracker()
        let queue = BootstrapQueue()

        for index in 0..<6 {
            await queue.push(directory: "dir-\(index)") {
                await tracker.begin()
                await tracker.sleepMS(30)
                await tracker.end()
            }
        }

        await queue.drain()
        await waitForIdle(queue)

        let max = await tracker.max
        let completions = await tracker.completions
        XCTAssertEqual(max, 2, "batch di 2 operazioni in parallelo")
        XCTAssertEqual(completions, 6)
    }

    // MARK: - Suspend / Resume

    func testSuspend_whenSuspended_shouldKeepPendingAndResumeRestarts() async {
        let counter = Counter()
        let queue = BootstrapQueue()

        await queue.push(directory: "a") { await counter.inc() }
        await queue.suspend()

        let suspended = await queue.isSuspended
        XCTAssertTrue(suspended)
        await queue.drain() // no-op mentre sospesa
        let pendingWhileSuspended = await queue.pendingCount()
        let runningWhileSuspended = await queue.runningCount()
        XCTAssertEqual(pendingWhileSuspended, 1)
        XCTAssertEqual(runningWhileSuspended, 0)

        await queue.resume()
        await waitForIdle(queue)

        let executedAfterResume = await counter.value
        let resumed = await queue.isSuspended
        XCTAssertEqual(executedAfterResume, 1)
        XCTAssertFalse(resumed)
    }

    // MARK: - Contatori e callback

    func testPendingCount_shouldTrackQueuedOperations() async {
        let queue = BootstrapQueue()
        let initial = await queue.pendingCount()
        XCTAssertEqual(initial, 0)

        await queue.push(directory: "a") {}
        await queue.push(directory: "b") {}
        let queued = await queue.pendingCount()
        XCTAssertEqual(queued, 2)

        await queue.drain()
        await waitForIdle(queue)
        let afterDrain = await queue.pendingCount()
        XCTAssertEqual(afterDrain, 0)
    }

    func testOnError_whenOperationsSucceed_shouldNotBeInvoked() async {
        let flag = ErrorFlag()
        let queue = BootstrapQueue(onError: { _, _ in
            Task { await flag.mark() }
        })

        await queue.push(directory: "a") {}
        await queue.drain()
        await waitForIdle(queue)

        let flagSet = await flag.wasSet
        XCTAssertFalse(flagSet)
    }
}

/// Flag actor per verificare che `onError` non venga invocato.
private actor ErrorFlag {
    private(set) var wasSet = false

    func mark() {
        wasSet = true
    }
}
