import CogTesting
import Testing

@testable import Cog

@MainActor
@Test func `ReactionReaderInfrastructure peek settles without adding a dependency`() {
  let cogs = Cogtext.forTesting()
  let trigger = ManualCog<Int>(0)
  let source = ManualCog<Int>(1)
  let projectedSource = source.readOnly
  let doubled = Cog<Int> { c in c[source] * 2 }
  var seen: [(Int, Int)] = []

  let token = cogs.run { c in
    _ = c[trigger]
    seen.append((c.peek(projectedSource), c.peek(doubled)))
  }
  defer { token.cancel() }

  #expect(seen.map { $0.0 } == [1])
  #expect(seen.map { $0.1 } == [2])

  cogs.commit { c in c[source] = 3 }
  #expect(seen.count == 1)

  cogs.commit { c in c[trigger] = 1 }
  #expect(seen.map { $0.0 } == [1, 3])
  #expect(seen.map { $0.1 } == [2, 6])
}

@MainActor
@Test func `ReactionLeaseInfrastructure counts direct derived roots once per reaction`() {
  let cogs = Cogtext.forTesting()
  let source = ManualCog<Int>(1)
  let inner = Cog<Int> { c in c[source] + 1 }
  let root = Cog<Int> { c in c[inner] + 1 }
  let kept = Cog<Int>(keepAlive: true) { _ in 4 }

  let first = cogs.run { c in
    _ = c[root]
    _ = c[root]
    _ = c[source]
    _ = c[kept]
  }
  let second = cogs.run { c in _ = c[root] }

  let rootState = cogs.derivedState(for: root)
  let innerState = cogs.derivedState(for: inner)
  let keptState = cogs.derivedState(for: kept)

  #expect(rootState.externalLeaseCount == 2)
  #expect(innerState.externalLeaseCount == 0)
  #expect(keptState.externalLeaseCount == 0)
  #expect(cogs.manualState(for: source).descriptor.lifetime == .app)
  #expect(first.reaction.leasedDependencies.count == 1)
  #expect(first.reaction.leasedDependencies.first === rootState)
  #expect(second.reaction.leasedDependencies.count == 1)
  #expect(second.reaction.leasedDependencies.first === rootState)

  first.cancel()
  #expect(rootState.externalLeaseCount == 1)

  first.cancel()
  #expect(rootState.externalLeaseCount == 1)

  second.cancel()
  #expect(rootState.externalLeaseCount == 0)
}

@MainActor
@Test func `ReactionLeaseInfrastructure moves leases when a reaction retracks`() {
  let cogs = Cogtext.forTesting()
  let chooseLeft = ManualCog<Bool>(true)
  let left = Cog<Int> { _ in 1 }
  let right = Cog<Int> { _ in 2 }
  let anchor = Cog<Int> { _ in 3 }

  let token = cogs.run { c in
    _ = c[anchor]
    let selected = c[chooseLeft] ? left : right
    _ = c[selected]
    _ = c[selected]
  }

  let leftState = cogs.derivedState(for: left)
  let rightState = cogs.derivedState(for: right)
  let anchorState = cogs.derivedState(for: anchor)

  #expect(leftState.externalLeaseCount == 1)
  #expect(rightState.externalLeaseCount == 0)
  #expect(anchorState.externalLeaseCount == 1)

  cogs.commit { c in c[chooseLeft] = false }
  #expect(leftState.externalLeaseCount == 0)
  #expect(rightState.externalLeaseCount == 1)
  #expect(anchorState.externalLeaseCount == 1)

  cogs.commit { c in c[chooseLeft] = true }
  #expect(leftState.externalLeaseCount == 1)
  #expect(rightState.externalLeaseCount == 0)
  #expect(anchorState.externalLeaseCount == 1)

  token.cancel()
  #expect(leftState.externalLeaseCount == 0)
  #expect(rightState.externalLeaseCount == 0)
  #expect(anchorState.externalLeaseCount == 0)
}

@MainActor
@Test func `ReactionLeaseInfrastructure self cancellation cannot reacquire leases`() {
  let cogs = Cogtext.forTesting()
  let trigger = ManualCog<Int>(0)
  let beforeCancellation = Cog<Int> { _ in 1 }
  let afterCancellation = Cog<Int> { _ in 2 }
  var token: ReactionToken?

  token = cogs.run { c in
    let triggerValue = c[trigger]
    _ = c[beforeCancellation]
    if triggerValue > 0 {
      token?.cancel()
      _ = c[afterCancellation]
    }
  }

  let beforeState = cogs.derivedState(for: beforeCancellation)
  let afterState = cogs.derivedState(for: afterCancellation)
  #expect(beforeState.externalLeaseCount == 1)
  #expect(afterState.externalLeaseCount == 0)

  cogs.commit { c in c[trigger] = 1 }

  #expect(token?.reaction.isCancelled == true)
  #expect(beforeState.externalLeaseCount == 0)
  #expect(afterState.externalLeaseCount == 0)
  #expect(token?.reaction.dependencies.isEmpty == true)
  #expect(token?.reaction.leasedDependencies.isEmpty == true)
}

@MainActor
@Test func `ReactionLeaseInfrastructure balances leases during context teardown`() {
  var cogs: Cogtext? = Cogtext.forTesting()
  weak let releasedContext = cogs
  let root = Cog<Int> { _ in 1 }
  let rootState = cogs?.derivedState(for: root)
  let token = cogs?.run { c in _ = c[root] }
  let reaction = token?.reaction

  #expect(rootState?.externalLeaseCount == 1)
  #expect(reaction?.leasedDependencies.count == 1)

  cogs = nil

  #expect(releasedContext == nil)
  #expect(rootState?.externalLeaseCount == 0)
  #expect(reaction?.leasedDependencies.isEmpty == true)

  token?.cancel()
  #expect(rootState?.externalLeaseCount == 0)
}
