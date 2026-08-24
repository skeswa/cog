internal import Cog

// The cellx lattice from `js-reactivity-benchmark`, by Milo Mighdoll and
// contributors (https://github.com/milomg/js-reactivity-benchmark,
// `packages/core/src/benches/cellxBench.ts`), which is itself a port of Riim's
// original cellx `perf.html`.
//
// Four sources feed a stack of four-wide layers, each layer defined only in
// terms of the one above it:
//
// ```text
// p1 = m.p2          p3 = m.p2 + m.p4
// p2 = m.p1 - m.p3   p4 = m.p3
// ```
//
// The interesting part is that the whole lattice is *one write away* from
// changing: a turn writes all four sources at once, and every node in every
// layer has to be reached exactly once. Where the Kairo diamond catches a
// consumer woken once per changed parent, this catches it a thousand layers
// deep, where a per-arrival wake would cost a multiple rather than a constant.
//
// Two notes on how the port differs, both recorded on the shapes themselves:
// a `peek` stands in for upstream's per-layer `effect`, and the counter counts
// selector runs rather than effect invocations.

extension CogScenario {
  /// The cellx lattice: `layers` four-node layers over four sources, settled
  /// once and then driven by a single turn that rewrites all four sources.
  ///
  /// Nothing prunes. The transform is a linear recurrence whose orbit has
  /// period twelve, and starting it from `(1, 2, 3, 4)` versus `(4, 3, 2, 1)`
  /// produces two orbits that differ in **every** component at **every** layer.
  /// So the equality gate — which the diamond and the sweeps lean on heavily —
  /// stops nothing here by construction, and the count is the clean one:
  ///
  /// ```text
  /// expectedRuns = 4 × layers × 2
  /// ```
  ///
  /// one run per node to settle the lattice, and one per node for the turn.
  /// That is what makes this a good shape to count: any number other than
  /// `8 × layers` is duplicate work or missed work, with no value-dependent
  /// pruning to explain it away.
  ///
  /// As with the deep sweeps, the first settle walks upward a layer at a time.
  /// A cold read nests one Swift frame per uncomputed link and Cog stops that
  /// at 128 (GRAPH-14), so a cold read of the thousand-layer lattice upstream
  /// actually runs would trap by design. Settling upward costs the same runs
  /// and keeps upstream's depth.
  ///
  /// - Parameters:
  ///   - layers: Four-node layers above the sources. Upstream runs 1,000 and
  ///     2,500.
  /// - Returns: A scenario whose final value packs the four end values before
  ///   the turn and the four after it, in that order — see
  ///   ``CogScenario/packCellxValues(_:)``.
  public static func cellxLattice(layers: Int = 1000) -> CogScenario {
    CogScenario(
      name: "COUNT-06-CellxLattice",
      expectedRuns: 8 * layers
    ) { cogs, counter in
      // Flat ownership, for the reason `kairoDeep` gives: a thousand layers of
      // selectors each retaining the layer above would be a chain ARC releases
      // recursively, and the scenario would crash on teardown at depths the
      // graph settles fine.
      let lattice = CellxLattice()
      lattice.sourceCogs = (0..<CellxLattice.width).map { property in
        Cog<Int>.Manual({ property + 1 }, name: "cellx.source.p\(property + 1)")
      }
      lattice.layerCogs.reserveCapacity(max(layers, 0))

      for layer in 0..<max(layers, 0) {
        let nodeCogs = (0..<CellxLattice.width).map { property in
          Cog<Int>(
            { [unowned lattice] c in
              counter.record()
              return lattice.read(c, layer: layer, property: property)
            },
            name: "cellx.\(layer).p\(property + 1)"
          )
        }
        lattice.layerCogs.append(nodeCogs)
      }

      // Settle upward. See the note on the doc comment above.
      for nodeCogs in lattice.layerCogs {
        for nodeCog in nodeCogs { _ = cogs.peek(nodeCog) }
      }

      guard let endCogs = lattice.layerCogs.last else { return 0 }
      let before = endCogs.map { cogs.peek($0) }

      // Upstream's single turn: all four sources, reversed, in one batch.
      cogs.turn("cellx.turn") { c in
        for property in 0..<CellxLattice.width {
          c[lattice.sourceCogs[property]] = CellxLattice.width - property
        }
      }

      let after = endCogs.map { cogs.peek($0) }
      return packCellxValues(before + after)
    }
  }

  /// Packs the cellx end values into one integer, reversibly.
  ///
  /// ``CogScenario`` reports a single number, and cellx's result is eight of
  /// them — four before the turn and four after. A digit-packing rather than a
  /// hash so a failure is readable: subtract the bias and read the values back
  /// out in order.
  ///
  /// The orbit is periodic and every value it visits is small, so base 64 with
  /// a bias of 32 holds eight of them with room to spare.
  ///
  /// - Parameter values: Values to pack, least significant first.
  /// - Returns: The packed integer.
  public static func packCellxValues(_ values: [Int]) -> Int {
    var packed = 0
    for value in values.reversed() {
      precondition(value > -32 && value < 32, "A cellx value left the packable range.")
      packed = packed * 64 + (value + 32)
    }
    return packed
  }
}

/// Flat storage for one cellx lattice, plus the layer transform itself.
///
/// Exists so no node's selector retains the layer above it. See
/// `cellxLattice`.
@MainActor
private final class CellxLattice {
  /// Nodes per layer, and sources. Upstream's `prop1` through `prop4`.
  static let width = 4

  /// The four sources, in property order.
  var sourceCogs: [Cog<Int>.Manual] = []

  /// Layers in build order, each four nodes wide.
  var layerCogs: [[Cog<Int>]] = []

  /// Computes one node from the layer above it, using upstream's transform.
  ///
  /// - Parameters:
  ///   - c: The reader of the node currently computing.
  ///   - layer: The layer this node lives in. Layer 0 reads the sources.
  ///   - property: The node's index within its layer, 0 through 3.
  /// - Returns: The node's value.
  func read(_ c: Reader<Int>, layer: Int, property: Int) -> Int {
    func above(_ index: Int) -> Int {
      guard layer > 0 else { return c[sourceCogs[index]] }
      return c[layerCogs[layer - 1][index]]
    }

    switch property {
    case 0: return above(1)
    case 1: return above(0) - above(2)
    case 2: return above(1) + above(3)
    default: return above(2)
    }
  }
}
