import Cog
import CogTesting
import Testing

// MARK: - Watch projection infrastructure

@MainActor
@Test func `WatchProjectionInfrastructure watches a source through its read-only projection`() {
  // API-surface coverage rather than a scenario claim: a read-only value reference names
  // the same state its source does, so watching it must be watching the source.
  let cogs = Cogtext.forTesting()
  let source = ManualCog<Int>(1)
  let projection = source.readOnly
  var deliveries: [String] = []

  let token = cogs.watch(projection, initial: .skip) { old, new in
    deliveries.append("\(old)->\(new)")
  }

  cogs.commit { c in c[source] = 2 }

  #expect(deliveries == ["1->2"])
  _ = token
}
