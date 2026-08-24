internal import Cog

// The `dynamicBench` sweeps from `js-reactivity-benchmark`, by Milo Mighdoll and
// contributors (https://github.com/milomg/js-reactivity-benchmark,
// `packages/core/src/benches/reactively/dynamicBench.ts` and
// `reactively/dependencyGraph.ts`). Where the Kairo cases are fixed shapes, this
// is a shape *generator*: a rectangular graph parameterized by width, depth,
// fan-in, and how many of its nodes rewire themselves as values change. The
// sweep is over those parameters, and it is the only ported case where the
// graph Cog is asked to settle changes size and connectivity from run to run.
//
// Beyond the two differences every ported case carries — a `peek` in place of
// upstream's `effect`, and selector runs counted rather than effect invocations
// — this port makes three of its own, all in service of an exact count:
//
// Upstream picks which nodes are dynamic with a seeded PRNG. This picks them by
// stride. An exact expectation has to name the graph it is about, and "every
// second node in the row" names one; "whatever `pseudoRandom()` returned"
// names one only if a JS PRNG is ported bit for bit, which would make the port
// harder to read and no more faithful to what is being measured.
//
// Upstream also reads a fraction of the leaves, to measure laziness. This reads
// all of them. A partial-read count is a fact about which leaves the port
// happens to skip rather than about Cog, and Cog's laziness — that an unread
// branch costs nothing — is already proven exactly by GRAPH-04.
//
// Sums accumulate with `&+`. Fan-in multiplies magnitudes layer over layer, so
// upstream's five-wide, five-hundred-deep sweep reaches 1e241; JavaScript
// numbers drift into floating point there, and `Int` would trap. Wrapping keeps
// the arithmetic exact, deterministic, and total, which is all a checksum needs
// to be.

extension CogScenario {
  /// One `dynamicBench` sweep: a `width` × `layers` rectangle where each node
  /// reads `sourcesPerNode` consecutive nodes of the row above it, wrapping.
  ///
  /// One write does not reach the whole graph at once. Row 1 node `j` reads
  /// sources `j ..< j + sourcesPerNode`, so writing source `d` dirties the
  /// `sourcesPerNode` nodes whose window contains it; each row down widens that
  /// arc by `sourcesPerNode - 1` until it wraps the full width. So a settled
  /// turn costs
  ///
  /// ```text
  /// runsPerTurn = Σ over rows L of min(width, L × (sourcesPerNode − 1) + 1)
  /// ```
  ///
  /// and the whole scenario, counting the first settle that runs every node
  /// once:
  ///
  /// ```text
  /// expectedRuns = (layers − 1) × width + turns × runsPerTurn
  /// ```
  ///
  /// That widening arc is the property the sweep exists to police. A push
  /// implementation that woke every consumer of a changed node would cost
  /// `(layers − 1) × width` every turn regardless of `sourcesPerNode`, and no
  /// timing measurement distinguishes the two at these sizes.
  ///
  /// The first settle walks row by row rather than pulling a leaf. A cold read
  /// nests one Swift frame per uncomputed link and Cog stops it at 128
  /// (GRAPH-14), so a cold top-down read of the five-hundred-layer sweep would
  /// trap by design. Settling upward costs the same runs — every node runs
  /// once either way — and lets the sweep keep upstream's depth.
  ///
  /// - Parameters:
  ///   - width: Sources, and computed nodes per row.
  ///   - layers: Source row plus computed rows, so `layers - 1` rows compute.
  ///   - sourcesPerNode: Consecutive nodes of the row above that each node
  ///     reads. Upstream's `nSources`.
  ///   - dynamicStride: Every `dynamicStride`th node rewires itself, dropping
  ///     one input according to its own value, the way upstream's dynamic
  ///     nodes do. `0` builds an entirely static graph.
  ///
  ///     A dynamic node changes which edges exist, not how many nodes run, so
  ///     the expectation above still holds — but only once the arc has
  ///     saturated, because before then a node's reachability from the written
  ///     source depends on which edge it dropped. Pass `dynamicStride > 0`
  ///     only with `sourcesPerNode >= width`, which saturates at row 1.
  ///   - turns: Changing turns after the first settle. Each writes one source,
  ///     cycling through them the way upstream does.
  public static func dynamicSweep(
    width: Int = 10,
    layers: Int = 5,
    sourcesPerNode: Int = 2,
    dynamicStride: Int = 0,
    turns: Int = 100
  ) -> CogScenario {
    let rowCount = max(layers - 1, 0)
    var runsPerTurn = 0
    for row in 1...max(rowCount, 1) where rowCount > 0 {
      runsPerTurn += min(width, (row - 1) * (sourcesPerNode - 1) + sourcesPerNode)
    }

    return CogScenario(
      name: "COUNT-05-DynamicSweep",
      expectedRuns: rowCount * width + turns * runsPerTurn
    ) { cogs, counter in
      // Flat ownership, for the reason `kairoDeep` gives: if a node's selector
      // captured the row above it by value, five hundred rows would form a
      // chain ARC releases recursively and the scenario would crash on
      // teardown at depths the graph settles fine. Every node reads the shared
      // storage by index instead. `unowned` because the storage owns every
      // selector that reads it.
      let graph = DynamicSweepGraph()
      graph.sourceCogs = (0..<width).map { index in
        Cog<Int>.Manual({ index }, name: "sweep.source.\(index)")
      }
      graph.rowCogs.reserveCapacity(rowCount)

      for row in 0..<rowCount {
        let nodeCogs = (0..<width).map { index in
          let isDynamic = dynamicStride > 0 && index.isMultiple(of: dynamicStride)
          return Cog<Int>(
            { [unowned graph] c in
              counter.record()
              return graph.read(
                c,
                row: row,
                index: index,
                fanIn: sourcesPerNode,
                width: width,
                isDynamic: isDynamic
              )
            },
            name: "sweep.\(row).\(index)"
          )
        }
        graph.rowCogs.append(nodeCogs)
      }

      // Settle upward, one row at a time, so the first read of a deep sweep is
      // warm at every step. See the note on the doc comment above.
      var last = 0
      for nodeCogs in graph.rowCogs {
        for nodeCog in nodeCogs { last = cogs.peek(nodeCog) }
      }

      guard let leafCogs = graph.rowCogs.last else { return last }
      for turn in 1...max(turns, 1) where turns > 0 {
        // Upstream cycles the written source and writes `iteration + index`.
        // Every write moves its source by `width`, so no turn is ever gated
        // away as equal and the count above stays exact.
        let index = turn % width
        cogs.turn("sweep.turn") { c in c[graph.sourceCogs[index]] = turn + index }
        for leafCog in leafCogs { last = cogs.peek(leafCog) }
      }
      return last
    }
  }
}

/// Flat storage for one generated sweep graph, plus the node body itself.
///
/// Exists so no node's selector retains the row above it. See `dynamicSweep`.
@MainActor
private final class DynamicSweepGraph {
  /// The source row, in index order.
  var sourceCogs: [Cog<Int>.Manual] = []

  /// Computed rows in build order, each `width` nodes wide.
  var rowCogs: [[Cog<Int>]] = []

  /// Computes one node: the wrapped window of the row above, summed.
  ///
  /// A static node reads its whole window. A dynamic node reads the first
  /// entry, then decides from that value whether to skip exactly one of the
  /// rest — upstream's rule, which makes the node's dependency set a function
  /// of its own input rather than of the graph's shape.
  ///
  /// - Parameters:
  ///   - c: The reader of the node currently computing.
  ///   - row: The computed row this node lives in. Row 0 reads the sources.
  ///   - index: The node's position in its row, and the start of its window.
  ///   - fanIn: How many consecutive entries the window spans.
  ///   - width: Row width, and the modulus the window wraps at.
  ///   - isDynamic: Whether this node may drop one input.
  /// - Returns: The node's value, accumulated with wrapping addition.
  func read(
    _ c: Reader<Int>,
    row: Int,
    index: Int,
    fanIn: Int,
    width: Int,
    isDynamic: Bool
  ) -> Int {
    func input(_ offset: Int) -> Int {
      let position = (index + offset) % width
      guard row > 0 else { return c[sourceCogs[position]] }
      return c[rowCogs[row - 1][position]]
    }

    var sum = input(0)
    let tailCount = fanIn - 1
    guard tailCount > 0 else { return sum }

    // Upstream drops on odd sums only, so half the turns rewire and half do
    // not — which is what makes this a *dynamic* graph rather than a graph
    // with a different fixed shape.
    let shouldDrop = isDynamic && !sum.isMultiple(of: 2)
    let dropOffset = shouldDrop ? Int(sum.magnitude % UInt(tailCount)) : -1
    for offset in 0..<tailCount where offset != dropOffset {
      sum = sum &+ input(offset + 1)
    }
    return sum
  }
}
