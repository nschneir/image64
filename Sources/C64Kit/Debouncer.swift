/// Coalesces a burst of asynchronous requests into a single deferred call.
///
/// The app's live preview re-runs the conversion on every slider tick, every
/// crop-handle drag, every colour-adjustment nudge. Running the pipeline on
/// each of those events would burn CPU on frames the user never sees, so the
/// engine's front end funnels them through a debouncer: only the *last*
/// request in a quiet window actually fires.
///
/// This lives in `C64Kit` rather than the app so the behaviour is testable
/// without a window — `DebouncerTests` verifies the supersede-and-wait
/// contract against a real actor, not a mocked timer.
///
/// ## Invariant
///
/// At most one scheduled `Task` exists at a time. Each `submit` cancels the
/// previous one before scheduling its own, so a caller that fires ten
/// `submit`s in rapid succession ends up with exactly one operation running,
/// `delay` after the tenth call. Once that operation completes the stored
/// handle is cleared, so a later `submit` starts a fresh scheduled run
/// rather than being folded into a stale one.
public actor Debouncer {
    private let delay: Duration
    private var pending: Task<Void, Never>?
    /// Monotonically increasing id for each scheduled task. Used at
    /// completion time to tell "I am the latest" from "a newer submit
    /// already replaced me" — without it, a task that finishes after a
    /// supersede would clear the newer task's handle.
    private var generation: UInt64 = 0

    public init(delay: Duration) {
        self.delay = delay
    }

    /// Cancels any pending work and schedules `operation` after `delay`.
    ///
    /// If another `submit` arrives before the sleep completes, the previously
    /// scheduled task is cancelled and its `operation` is never invoked.
    public func submit(_ operation: @escaping @Sendable () async -> Void) {
        pending?.cancel()
        generation &+= 1
        let token = generation
        let delay = self.delay
        pending = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            if Task.isCancelled { return }
            await operation()
            await self?.finish(token: token)
        }
    }

    /// Drops the stored handle if it still points at the task that just
    /// finished. A racing `submit` that already installed a newer handle
    /// bumps `generation`, so this becomes a no-op — that newer task owns
    /// the slot now and will clear it in its own turn.
    private func finish(token: UInt64) {
        if token == generation {
            pending = nil
        }
    }
}
