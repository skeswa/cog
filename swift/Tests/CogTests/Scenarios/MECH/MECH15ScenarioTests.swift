import Cog
import CogTesting
import Testing
import os

/// Milestones recorded from both isolated and nonisolated teardown code.
///
/// A `deinit` is nonisolated in some legs and MainActor-isolated in others, so
/// the log cannot be MainActor state. The lock makes the ordering assertions
/// below true regardless of which leg is running.
private nonisolated final class TeardownLog: @unchecked Sendable {
  private let state = OSAllocatedUnfairLock(initialState: [String]())

  func record(_ milestone: String) {
    state.withLock { $0.append(milestone) }
  }

  var milestones: [String] {
    state.withLock { $0 }
  }
}

/// The class-owned resource whose survival MECH-15 is about.
private nonisolated final class Connection {
  private let log: TeardownLog

  init(log: TeardownLog) {
    self.log = log
  }

  deinit {
    log.record("connection released")
  }
}

/// A class mechanism that owns a resource and one long-lived task.
private final class ConnectedMechanism: Mechanism {
  let name = "Connected"

  /// The resource the runtime must keep alive for as long as the mechanism.
  private let connection: Connection
  private let log: TeardownLog
  private let started: AsyncStream<Void>.Continuation

  init(log: TeardownLog, started: AsyncStream<Void>.Continuation) {
    self.log = log
    self.connection = Connection(log: log)
    self.started = started
  }

  func operate(_ m: MechanismController) {
    let log = log
    let started = started
    m.task(name: "held") {
      // The milestone is the cancellation *request*, recorded in the handler
      // that fires synchronously when the scope cancels this task. Recording
      // it after the sleep returns instead would measure when the task's
      // executor got around to resuming it, which says nothing about the
      // teardown order this scenario is about.
      await withTaskCancellationHandler {
        started.yield()
        // Nothing completes this sleep; only cancellation ends it.
        try? await Task.sleep(for: .seconds(3600))
      } onCancel: {
        log.record("task cancelled")
      }
    }
  }

  deinit {
    log.record("mechanism released")
  }
}

/// Drops the last context reference from another executor.
private actor ContextDropper {
  private var cogs: Cogs?

  init(cogs: consuming Cogs) {
    self.cogs = cogs
  }

  func drop() {
    self.preconditionIsolated()
    cogs = nil
  }
}

@MainActor
@Test func `MECH-15 the runtime retains a mechanism and releases it after its scope`()
  async throws
{
  let log = TeardownLog()
  let (starts, startContinuation) = AsyncStream.makeStream(of: Void.self)
  let cleanup = MainActorCleanupAcknowledgement()

  weak var mechanism: ConnectedMechanism?

  // The mechanism's only strong reference outside the runtime lives in this
  // scope and is gone by the time it closes.
  let cogs = { () -> Cogs in
    let owned = ConnectedMechanism(log: log, started: startContinuation)
    mechanism = owned
    return Cogs.forTesting(mechanisms: [owned])
  }()

  cogs.acknowledgeDeinitCleanup(with: cleanup)

  // Nobody outside the runtime holds the mechanism now, and it is still here:
  // the runtime retains the exact value it was handed, not a copy.
  #expect(mechanism != nil)
  #expect(log.milestones.isEmpty)

  // Its task is running, so the cancellation milestone below is a later event
  // rather than a startup race.
  var startIterator = starts.makeAsyncIterator()
  _ = await startIterator.next()

  let dropper = ContextDropper(cogs: consume cogs)
  let release = Task { await dropper.drop() }
  try await cleanup.wait()
  await release.value

  #expect(mechanism == nil)
  // The whole point of the ordering: the resource a registration might still
  // be using outlives that registration.
  #expect(
    log.milestones == ["task cancelled", "mechanism released", "connection released"]
  )
}
