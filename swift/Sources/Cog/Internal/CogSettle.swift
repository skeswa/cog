extension Cogs {
  /// How many arena settle walks may nest before Cog stops and explains itself.
  ///
  /// The fixed limit makes the same graph fail the same way on every device.
  /// Measurements from 2026-08-16 reached about 6,100 cold links on an 8 MiB
  /// macOS stack, 770 in iOS release, and 240 in iOS debug on a 1 MiB stack. A
  /// device-based limit could pass in the simulator and crash on a phone. This
  /// value stays below the smallest measured ceiling and above a reasonable UI
  /// chain.
  internal static let maximumSettleDepth = 128

  /// What Cog says when a first read nests further than it will follow.
  ///
  /// Names the innermost declarations so the caller can see which chain
  /// stacked, and says the two things that actually resolve it: read from the
  /// source end, or shorten the chain.
  internal func coldSettleDepthMessage(innermostComputingNames: [String]) -> String {
    let chain = innermostComputingNames.joined(separator: " -> ")
    return """
      Reading a Cog needed \(settleDepth) nested computations, past the limit \
      of \(Self.maximumSettleDepth). Cog computes an automatic cog the first time \
      something reads it, and a first computation that reads a cog which has \
      never been computed has to compute that one inline — so reading the far \
      end of a long chain of never-read cogs nests one computation per link \
      and would exhaust the stack. The innermost links were: \(chain). Read \
      the chain from its source end first, so each link is already computed \
      when the next one reads it, or make the chain shorter. Cogs that have \
      been computed once never nest again: later changes settle iteratively, \
      however deep the graph is.
      """
  }
}
