import CogTesting
import Testing

@testable import Cog

// MARK: - Watch projection infrastructure

@MainActor
@Test func `WatchProjectionInfrastructure watches a source through its read-only projection`() {
  // API-surface coverage rather than a scenario claim: a read-only value reference names
  // the same state its source does, so watching it must be watching the source.
  let cogs = Cogs.forTesting()
  let source = ManualCog<Int>(1)
  let projection = source.readOnly
  var deliveries: [String] = []

  let token = cogs.watchTracked(
    label: CogLabel(name: nil, fileID: #fileID, line: #line),
    initial: .skip,
    read: { c in c[projection] },
    body: { old, new in
      deliveries.append("\(old)->\(new)")
    }
  )

  cogs.turn { c in c[source] = 2 }

  #expect(deliveries == ["1->2"])
  _ = token
}
