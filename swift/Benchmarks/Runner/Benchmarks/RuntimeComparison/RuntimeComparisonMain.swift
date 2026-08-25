/// Registers the synthetic graph-shape comparison suite.
///
/// Keeping these cuts in their own executable prevents Cog-only benchmark
/// builds from linking StateGraph and makes the comparison boundary visible in
/// both SwiftPM and threshold filenames.
let benchmarks: @Sendable () -> Void = {
  runtimeComparisonBenchmarks()
}
