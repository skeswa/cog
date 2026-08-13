import Cog
import CogTesting
import Testing

@MainActor
private final class Async01WorkProbe {
  private var didRun = false
  private var waiter: CheckedContinuation<Void, Never>?

  func run() -> Int {
    didRun = true
    waiter?.resume()
    waiter = nil
    return 42
  }

  func waitForRun() async {
    guard !didRun else { return }
    await withCheckedContinuation { waiter = $0 }
  }
}

@MainActor
@Test func `ASYNC-01 first tracked read starts work and returns pending`() async {
  let cogs = Cogs.forTesting()
  let probe = Async01WorkProbe()
  let forecast = AsyncCog<Int>(default: 0, name: "forecast") { _ in
    .run { probe.run() }
  }
  var phases: [CogMeta<Int>] = []

  let token = cogs.run { c in
    phases.append(c.meta[forecast])
  }

  #expect(phases.count == 1)
  if let phase = phases.first {
    switch phase {
    case .pending(_, hasSucceeded: false):
      break
    default:
      Issue.record("The first visible phase was not pending without a previous value")
    }
  }

  #if DEBUG
  let pendingTurns = cogs.debugHistory.entries.filter {
    $0.event == .turn && $0.name == "forecast pending"
  }
  #expect(pendingTurns.count == 1)
  #endif

  await probe.waitForRun()
  withExtendedLifetime(token) {}
}
