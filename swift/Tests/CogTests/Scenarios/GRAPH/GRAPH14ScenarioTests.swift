import Cog
import CogTesting
import Testing

/// Flat ownership, for GRAPH-03's reason: links that captured each other by
/// value would form a descriptor chain ARC releases recursively, which would
/// crash these children for a reason unrelated to what they prove.
@MainActor
private final class Graph14ChainStorage {
  var valueReferences: [Cog<Int>] = []
}

/// Builds a chain of `depth` never-read links and reads its top.
///
/// Kept in one place so the passing and trapping cases differ only in depth.
@MainActor
private func readColdChain(depth: Int) -> Int {
  let cogs = Cogs.forTesting()
  let sourceCog = Cog<Int>.Manual(0, name: "graph14.source")
  let storage = Graph14ChainStorage()
  storage.valueReferences.reserveCapacity(depth)

  for link in 0..<depth {
    let belowLink = link - 1
    storage.valueReferences.append(
      Cog<Int>(
        { [unowned storage] c in
          guard belowLink >= 0 else { return c[sourceCog] + 1 }
          return c[storage.valueReferences[belowLink]] + 1
        },
        name: "graph14.link.\(link)"
      )
    )
  }

  // Nothing has been read yet, so this one read computes every link, and each
  // link's computation reads the uncomputed link below it.
  return cogs.peek(storage.valueReferences[depth - 1])
}

@MainActor
@Test func `GRAPH-14 a cold chain within the bound settles normally`() {
  // The bound is not a warning: everything under it must keep working exactly
  // as before, or the guard would be a regression dressed as a diagnostic.
  #expect(readColdChain(depth: 100) == 100)
}

@Test func `GRAPH-14 reading past the cold nesting bound fails with a clear error`() async {
  let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
    await MainActor.run {
      // Deep enough to trip the bound, but far short of the roughly 2,000
      // links that actually smash a debug macOS stack — the guard has to fire
      // long before the crash it exists to prevent.
      _ = readColdChain(depth: 400)
    }
  }

  // Asserting on the message, not merely on the exit status: a bare trap and a
  // diagnosed one both exit non-zero, and the difference between them is the
  // whole point of this task.
  let stderr = String(decoding: result?.standardErrorContent ?? [], as: UTF8.self)
  #expect(stderr.contains("nested computations"), "stderr was: \(stderr)")
  // Names the chain it stopped in, the way the cycle diagnostic names its loop.
  #expect(stderr.contains("graph14.link."), "stderr was: \(stderr)")
  // And says what to do about it.
  #expect(stderr.contains("Read the chain from its source end first"), "stderr was: \(stderr)")
}

@MainActor
@Test func `GRAPH-14 a computed chain settles far past the cold bound`() {
  // The bound is on *cold* nesting alone. A chain many times longer than the
  // limit settles iteratively once its links have run, which is what GRAPH-03
  // proves and what this keeps honest: the guard must not have turned a depth
  // limit into a graph-size limit.
  let depth = 5_000
  let cogs = Cogs.forTesting()
  let sourceCog = Cog<Int>.Manual(0, name: "graph14.warm.source")
  let storage = Graph14ChainStorage()
  storage.valueReferences.reserveCapacity(depth)

  for link in 0..<depth {
    let belowLink = link - 1
    let linkCog = Cog<Int>(
      { [unowned storage] c in
        guard belowLink >= 0 else { return c[sourceCog] + 1 }
        return c[storage.valueReferences[belowLink]] + 1
      },
      name: "graph14.warm.link.\(link)"
    )
    storage.valueReferences.append(linkCog)
    // Reading each link as it is built keeps every computation shallow.
    _ = cogs.peek(linkCog)
  }

  let topCog = storage.valueReferences[depth - 1]
  #expect(cogs.peek(topCog) == depth)

  cogs.turn { c in c[sourceCog] = 1 }
  #expect(cogs.peek(topCog) == depth + 1)
}
