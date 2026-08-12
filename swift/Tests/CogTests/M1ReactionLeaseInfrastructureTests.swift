import CogTesting
import Testing

@testable import Cog

@MainActor
@Test func `M1ReactionLeaseInfrastructure counts direct derived roots once per reaction`() {
  let cogs = Cogtext.forTesting()
  let source = ManualCog<Int>(1)
  let inner = Cog<Int> { c in c.get(source) + 1 }
  let root = Cog<Int> { c in c.get(inner) + 1 }
  let kept = Cog<Int>(keepAlive: true) { _ in 4 }

  let first = cogs.run { c in
    _ = c.get(root)
    _ = c.get(root)
    _ = c.get(source)
    _ = c.get(kept)
  }
  let second = cogs.run { c in _ = c.get(root) }

  let rootNode = cogs.derivedNode(for: root)
  let innerNode = cogs.derivedNode(for: inner)
  let keptNode = cogs.derivedNode(for: kept)

  #expect(rootNode.externalLeaseCount == 2)
  #expect(innerNode.externalLeaseCount == 0)
  #expect(keptNode.externalLeaseCount == 0)
  #expect(cogs.manualNode(for: source).descriptor.lifetime == .app)
  #expect(first.reaction.leasedDependencies.count == 1)
  #expect(first.reaction.leasedDependencies.first === rootNode)
  #expect(second.reaction.leasedDependencies.count == 1)
  #expect(second.reaction.leasedDependencies.first === rootNode)

  first.cancel()
  #expect(rootNode.externalLeaseCount == 1)

  first.cancel()
  #expect(rootNode.externalLeaseCount == 1)

  second.cancel()
  #expect(rootNode.externalLeaseCount == 0)
}

@MainActor
@Test func `M1ReactionLeaseInfrastructure moves leases when a reaction retracks`() {
  let cogs = Cogtext.forTesting()
  let chooseLeft = ManualCog<Bool>(true)
  let left = Cog<Int> { _ in 1 }
  let right = Cog<Int> { _ in 2 }
  let anchor = Cog<Int> { _ in 3 }

  let token = cogs.run { c in
    _ = c.get(anchor)
    let selected = c.get(chooseLeft) ? left : right
    _ = c.get(selected)
    _ = c.get(selected)
  }

  let leftNode = cogs.derivedNode(for: left)
  let rightNode = cogs.derivedNode(for: right)
  let anchorNode = cogs.derivedNode(for: anchor)

  #expect(leftNode.externalLeaseCount == 1)
  #expect(rightNode.externalLeaseCount == 0)
  #expect(anchorNode.externalLeaseCount == 1)

  cogs.commit { writer in writer[chooseLeft] = false }
  #expect(leftNode.externalLeaseCount == 0)
  #expect(rightNode.externalLeaseCount == 1)
  #expect(anchorNode.externalLeaseCount == 1)

  cogs.commit { writer in writer[chooseLeft] = true }
  #expect(leftNode.externalLeaseCount == 1)
  #expect(rightNode.externalLeaseCount == 0)
  #expect(anchorNode.externalLeaseCount == 1)

  token.cancel()
  #expect(leftNode.externalLeaseCount == 0)
  #expect(rightNode.externalLeaseCount == 0)
  #expect(anchorNode.externalLeaseCount == 0)
}

@MainActor
@Test func `M1ReactionLeaseInfrastructure self cancellation cannot reacquire leases`() {
  let cogs = Cogtext.forTesting()
  let trigger = ManualCog<Int>(0)
  let beforeCancellation = Cog<Int> { _ in 1 }
  let afterCancellation = Cog<Int> { _ in 2 }
  var token: ReactionToken?

  token = cogs.run { c in
    let triggerValue = c.get(trigger)
    _ = c.get(beforeCancellation)
    if triggerValue > 0 {
      token?.cancel()
      _ = c.get(afterCancellation)
    }
  }

  let beforeNode = cogs.derivedNode(for: beforeCancellation)
  let afterNode = cogs.derivedNode(for: afterCancellation)
  #expect(beforeNode.externalLeaseCount == 1)
  #expect(afterNode.externalLeaseCount == 0)

  cogs.commit { writer in writer[trigger] = 1 }

  #expect(token?.reaction.isCancelled == true)
  #expect(beforeNode.externalLeaseCount == 0)
  #expect(afterNode.externalLeaseCount == 0)
  #expect(token?.reaction.dependencies.isEmpty == true)
  #expect(token?.reaction.leasedDependencies.isEmpty == true)
}

@MainActor
@Test func `M1ReactionLeaseInfrastructure balances leases during context teardown`() {
  var cogs: Cogtext? = Cogtext.forTesting()
  weak let releasedContext = cogs
  let root = Cog<Int> { _ in 1 }
  let rootNode = cogs?.derivedNode(for: root)
  let token = cogs?.run { c in _ = c.get(root) }
  let reaction = token?.reaction

  #expect(rootNode?.externalLeaseCount == 1)
  #expect(reaction?.leasedDependencies.count == 1)

  cogs = nil

  #expect(releasedContext == nil)
  #expect(rootNode?.externalLeaseCount == 0)
  #expect(reaction?.leasedDependencies.isEmpty == true)

  token?.cancel()
  #expect(rootNode?.externalLeaseCount == 0)
}
