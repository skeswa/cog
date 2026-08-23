import CogTesting
import Testing

@testable import Cog

@MainActor
@Test func `ArenaLifetimePolicyInfrastructure rows retain descriptor lifetime policy`() {
  let cogs = Cogs.forTesting()
  let appSourceCog = Cog<Int>.Manual(0)
  let ephemeralSourceCog = Cog<Int>.Manual(
    0,
    lifetime: .whileObserved(resetToInitial: true, grace: .seconds(7))
  )
  let automaticCog = Cog<Int> { _ in 1 }

  _ = cogs.peek(appSourceCog)
  _ = cogs.peek(ephemeralSourceCog)
  _ = cogs.peek(automaticCog)

  #expect(cogs.arenaCore.lifetimePolicy(for: appSourceCog) == .app)
  #expect(
    cogs.arenaCore.lifetimePolicy(for: ephemeralSourceCog)
      == .whileObserved(grace: .seconds(7))
  )
  #expect(cogs.arenaCore.lifetimePolicy(for: automaticCog) == .whileObserved(grace: nil))
}

@MainActor
@Test func `ArenaLeaseInfrastructure reactions lease only direct observed-lifetime roots`() {
  let cogs = Cogs.forTesting()
  let appSourceCog = Cog<Int>.Manual(1)
  let ephemeralSourceCog = Cog<Int>.Manual(
    2,
    lifetime: .whileObserved(resetToInitial: true)
  )
  let innerCog = Cog<Int> { c in c[appSourceCog] + 1 }
  let rootCog = Cog<Int> { c in c[innerCog] + 1 }

  let first = cogs.runForArenaLifetimeTesting { c in
    _ = c[rootCog]
    _ = c[rootCog]
    _ = c[ephemeralSourceCog]
    _ = c[appSourceCog]
  }
  let second = cogs.runForArenaLifetimeTesting { c in _ = c[rootCog] }

  #expect(cogs.arenaCore.leaseCount(for: rootCog) == 2)
  #expect(cogs.arenaCore.leaseCount(for: innerCog) == 0)
  #expect(cogs.arenaCore.leaseCount(for: ephemeralSourceCog) == 1)
  #expect(cogs.arenaCore.leaseCount(for: appSourceCog) == 0)
  #expect(first.reaction.arenaLeasedDependencies.count == 2)
  #expect(second.reaction.arenaLeasedDependencies.count == 1)

  first.cancel()
  #expect(cogs.arenaCore.leaseCount(for: rootCog) == 1)
  #expect(cogs.arenaCore.leaseCount(for: ephemeralSourceCog) == 0)

  first.cancel()
  #expect(cogs.arenaCore.leaseCount(for: rootCog) == 1)

  second.cancel()
  #expect(cogs.arenaCore.leaseCount(for: rootCog) == 0)
}

@MainActor
@Test func `ArenaLeaseInfrastructure retracking moves leases and retains shared roots`() {
  let cogs = Cogs.forTesting()
  let chooseLeftCog = Cog<Bool>.Manual(true)
  let leftCog = Cog<Int> { _ in 1 }
  let rightCog = Cog<Int> { _ in 2 }
  let anchorCog = Cog<Int> { _ in 3 }

  let token = cogs.runForArenaLifetimeTesting { c in
    _ = c[anchorCog]
    let selectedCog = c[chooseLeftCog] ? leftCog : rightCog
    _ = c[selectedCog]
    _ = c[selectedCog]
  }

  #expect(cogs.arenaCore.leaseCount(for: leftCog) == 1)
  #expect(cogs.arenaCore.leaseCount(for: rightCog) == 0)
  #expect(cogs.arenaCore.leaseCount(for: anchorCog) == 1)

  cogs.turn { c in c[chooseLeftCog] = false }
  #expect(cogs.arenaCore.leaseCount(for: leftCog) == 0)
  #expect(cogs.arenaCore.leaseCount(for: rightCog) == 1)
  #expect(cogs.arenaCore.leaseCount(for: anchorCog) == 1)

  cogs.turn { c in c[chooseLeftCog] = true }
  #expect(cogs.arenaCore.leaseCount(for: leftCog) == 1)
  #expect(cogs.arenaCore.leaseCount(for: rightCog) == 0)
  #expect(cogs.arenaCore.leaseCount(for: anchorCog) == 1)

  token.cancel()
  #expect(cogs.arenaCore.leaseCount(for: leftCog) == 0)
  #expect(cogs.arenaCore.leaseCount(for: rightCog) == 0)
  #expect(cogs.arenaCore.leaseCount(for: anchorCog) == 0)
}

@MainActor
@Test func `ArenaLeaseInfrastructure a UI boundary pins once and composes with reactions`() {
  let cogs = Cogs.forTesting()
  let automaticCog = Cog<Int> { _ in 1 }
  let token = cogs.runForArenaLifetimeTesting { c in _ = c[automaticCog] }

  #expect(cogs.arenaCore.leaseCount(for: automaticCog) == 1)

  #expect(cogs[automaticCog] == 1)
  #expect(cogs[automaticCog] == 1)
  #expect(cogs.arenaCore.leaseCount(for: automaticCog) == 2)

  token.cancel()
  #expect(cogs.arenaCore.leaseCount(for: automaticCog) == 1)
}

@MainActor
@Test func `ArenaLeaseInfrastructure self cancellation cannot reacquire a lease`() {
  let cogs = Cogs.forTesting()
  let triggerCog = Cog<Int>.Manual(0)
  let beforeCancellationCog = Cog<Int> { _ in 1 }
  let afterCancellationCog = Cog<Int> { _ in 2 }
  var token: ReactionToken?

  token = cogs.runForArenaLifetimeTesting { c in
    let trigger = c[triggerCog]
    _ = c[beforeCancellationCog]
    if trigger > 0 {
      token?.cancel()
      _ = c[afterCancellationCog]
    }
  }

  #expect(cogs.arenaCore.leaseCount(for: beforeCancellationCog) == 1)
  #expect(cogs.arenaCore.leaseCount(for: afterCancellationCog) == 0)

  cogs.turn { c in c[triggerCog] = 1 }

  #expect(token?.reaction.isCancelled == true)
  #expect(cogs.arenaCore.leaseCount(for: beforeCancellationCog) == 0)
  #expect(cogs.arenaCore.leaseCount(for: afterCancellationCog) == 0)
  #expect(token?.reaction.arenaLeasedDependencies.isEmpty == true)
}

@MainActor
@Test func `ArenaLeaseInfrastructure context teardown clears retained reaction roots`() {
  var cogs: Cogs? = Cogs.forTesting()
  weak let releasedContext = cogs
  let rootCog = Cog<Int> { _ in 1 }
  let token = cogs?.runForArenaLifetimeTesting { c in _ = c[rootCog] }
  let reaction = token?.reaction

  #expect(cogs?.arenaCore.leaseCount(for: rootCog) == 1)
  #expect(reaction?.arenaLeasedDependencies.count == 1)

  cogs = nil

  #expect(releasedContext == nil)
  #expect(reaction?.arenaLeasedDependencies.isEmpty == true)

  token?.cancel()
  #expect(reaction?.arenaLeasedDependencies.isEmpty == true)
}

extension Cogs {
  /// Registers a bare reaction for arena lifetime infrastructure tests.
  fileprivate func runForArenaLifetimeTesting(
    _ body: @escaping @MainActor (ReactionReader) -> Void
  ) -> ReactionToken {
    register(label: CogLabel(name: nil, fileID: #fileID, line: #line), body: body)
  }
}
