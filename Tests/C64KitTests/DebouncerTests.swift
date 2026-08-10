import XCTest

@testable import C64Kit

/// The debounce contract, pinned by observing which operations actually ran
/// rather than how long the waits took.
///
/// Timing here is deliberately loose: the debounce window is 50 ms, the
/// inter-submit spacing is 10 ms (well inside the window), and the final wait
/// is 200 ms (well past it). Nothing asserts on elapsed time — only on the
/// identity and count of the submitted operations that ended up executing.
final class DebouncerTests: XCTestCase {

    /// Records which submitted operations ran, in order. An actor so the
    /// operations can hop into it from whatever task the debouncer schedules
    /// them on without a data race.
    private actor Recorder {
        private(set) var runs: [Int] = []
        func record(_ id: Int) { runs.append(id) }
    }

    func testCoalescesRapidSubmitsIntoOnlyTheLast() async throws {
        // Three submits spaced 10 ms apart, well inside a 50 ms debounce
        // window: each one should cancel its predecessor, and only the third
        // should ever fire.
        let debouncer = Debouncer(delay: .milliseconds(50))
        let recorder = Recorder()

        for id in 1...3 {
            await debouncer.submit { await recorder.record(id) }
            try await Task.sleep(for: .milliseconds(10))
        }

        // 200 ms is comfortably past the 50 ms window, so if any scheduled
        // work were going to fire it would have fired by now.
        try await Task.sleep(for: .milliseconds(200))

        let runs = await recorder.runs
        XCTAssertEqual(runs, [3], "only the last-submitted operation should have run")
    }

    func testAcceptsFurtherSubmitsAfterCompletion() async throws {
        // A submit that is allowed to complete before the next submit lands
        // must not swallow that next submit — both should run.
        let debouncer = Debouncer(delay: .milliseconds(50))
        let recorder = Recorder()

        await debouncer.submit { await recorder.record(1) }
        try await Task.sleep(for: .milliseconds(200))

        await debouncer.submit { await recorder.record(2) }
        try await Task.sleep(for: .milliseconds(200))

        let runs = await recorder.runs
        XCTAssertEqual(runs, [1, 2], "a submit after completion must also run")
    }
}
