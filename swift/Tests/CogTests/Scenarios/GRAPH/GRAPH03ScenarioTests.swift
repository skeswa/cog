import Cog
import CogTesting
import Testing

/// Flat ownership keeps GRAPH-03 about graph traversal instead of recursive
/// release of a descriptor-closure chain after the assertion has passed.
@MainActor
private final class Graph03ChainStorage {
  var valueReferences: [Cog<Int>] = []
  var recordsSettlement = false
  var settlementOrder: [Int] = []
}

@MainActor
@Test func `GRAPH-03 a deep changed chain settles source to root without exhausting the stack`() {
  let depth = 20_000
  var cogs: Cogtext? = Cogtext.forTesting()
  weak let releasedContext = cogs
  let source = ManualCog<Int>(0)
  let storage = Graph03ChainStorage()
  storage.valueReferences.reserveCapacity(depth)
  storage.settlementOrder.reserveCapacity(depth)

  let first = Cog<Int> { [unowned storage] c in
    if storage.recordsSettlement {
      storage.settlementOrder.append(0)
    }
    return c[source] + 1
  }
  storage.valueReferences.append(first)
  _ = cogs?.peek(first)

  for index in 1..<depth {
    let parentIndex = index - 1
    let next = Cog<Int> { [unowned storage] c in
      if storage.recordsSettlement {
        storage.settlementOrder.append(index)
      }
      return c[storage.valueReferences[parentIndex]] + 1
    }
    storage.valueReferences.append(next)
    _ = cogs?.peek(next)
  }

  let root = storage.valueReferences[depth - 1]
  #expect(cogs?.peek(root) == depth)

  storage.recordsSettlement = true
  cogs?.commit { c in c[source] = 1 }
  let settledValue = cogs?.peek(root)
  storage.recordsSettlement = false

  #expect(settledValue == depth + 1)
  #expect(storage.settlementOrder.count == depth)
  #expect(
    storage.settlementOrder.indices.allSatisfy {
      storage.settlementOrder[$0] == $0
    }
  )

  // Make destruction part of the public stack-safety proof. Keeping the flat
  // descriptor storage alive isolates context-owned graph edges from user
  // closure ownership, while the weak reference proves teardown completed.
  cogs = nil
  #expect(releasedContext == nil)
}
