/// Registers the application-shaped Storefront benchmark suite.
///
/// Counting cuts run first because Benchmark's allocation and ARC counters are
/// process-global. Timing cuts can drop runtimes whose cancellation work
/// finishes later, so registering them afterwards prevents that background
/// teardown from contaminating a later counting sample.
let benchmarks: @Sendable () -> Void = {
  storefrontCountingBenchmarks()
  storefrontRuntimeCountingBenchmarks()
  storefrontTimingBenchmarks()
  storefrontRuntimeTimingBenchmarks()
}
