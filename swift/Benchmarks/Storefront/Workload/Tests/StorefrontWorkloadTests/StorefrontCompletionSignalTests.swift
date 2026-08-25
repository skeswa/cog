import StorefrontWorkload
import Testing

/// The neutral one-shot barrier every non-Cog port fires from its own publish
/// epilogue.
///
/// ``StorefrontCompletionSignal`` is the analogue of Cog's
/// `MainActorCleanupAcknowledgement`, and the whole comparison rests on the two
/// behaving identically: the Cog adapter awaits Cog's primitive while the other
/// three ports await this one, so an ordering difference between them would
/// surface as a flake in exactly one runtime — the hardest kind of benchmark
/// defect to attribute. These three cases pin the barrier's complete ordering
/// contract: buffered before a waiter arrives, suspending until a signal
/// arrives, and one-shot in both directions.
///
/// No `@testable`: every member under test is public API of the workload
/// module, because a port in another module has to fire it.
@Suite("Storefront completion signal")
@MainActor
struct StorefrontCompletionSignalTests {
  @Test("a signal fired before anyone waits resumes the later waiter")
  func signalThenWaitReturnsImmediately() async throws {
    let signal = StorefrontCompletionSignal()

    signal.signal()

    // Nothing was suspended when the decision completed, which is the ordering
    // a scripted release produces: the release resumes the runtime's task and
    // it publishes before `settlingOneAsyncResult` reaches its own `wait()`.
    // The buffered event is what keeps that from being a hang.
    try await signal.wait()
  }

  @Test("a waiter suspended before the signal resumes when the decision lands")
  func waitThenSignalResumesTheWaiter() async throws {
    let signal = StorefrontCompletionSignal()
    let latch = SignallerLatch()

    // This test body is MainActor-isolated, so the task below cannot start
    // until the body suspends. That makes the ordering deterministic rather
    // than a race, and the latch turns that into an assertion instead of an
    // argument: without it this case would also pass under the buffered
    // signal-then-wait ordering the previous case already covers.
    let signaller = Task { @MainActor in
      signal.signal()
      latch.didSignal = true
    }

    #expect(latch.didSignal == false)
    try await signal.wait()
    await signaller.value
    #expect(latch.didSignal)
  }

  @Test("a second signal traps rather than absorbing a second completion")
  func doubleSignalTraps() async {
    let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
      await MainActor.run {
        let signal = StorefrontCompletionSignal()
        signal.signal()
        signal.signal()
      }
    }

    // Asserting on the child's standard error rather than only its exit status:
    // a bare trap and a clear diagnostic are the same exit code, and the
    // repository spells fail-fast traps `fatalError` precisely so the message
    // survives `-O`.
    let standardError = String(decoding: result?.standardErrorContent ?? [], as: UTF8.self)
    #expect(
      standardError.contains("A Storefront completion signal was fired twice"),
      "stderr was: \(standardError)"
    )
  }
}

/// Records whether the signalling task has run yet.
///
/// A MainActor-confined reference rather than a captured local so the waiting
/// test body and the signalling task can share one mutable fact without either
/// escaping the MainActor. `nonisolated deinit` per the repository convention.
@MainActor private final class SignallerLatch {
  /// Whether the signalling task has fired the barrier.
  var didSignal = false

  nonisolated deinit {}
}
