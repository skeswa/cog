import StorefrontObservationMemo
import StorefrontObservationRaw
import StorefrontWorkload
import Testing

/// The linkage proof for the two plain-Swift comparison runtimes.
///
/// It asserts almost nothing on purpose. What it does assert is the one thing
/// no other suite can: that this test target actually links both port modules
/// and that the guarded wrapper therefore sees a nonzero executed-test count. A
/// package whose tests compile but select nothing would report a green for work
/// it never ran, which is the failure `tools/storefront-runtimes-test.mjs`
/// exists to refuse.
///
/// The slugs it checks are load-bearing rather than decorative: each is the
/// runtime's identity in every number the comparison publishes, since a cut is
/// named `perf-16-storefront-<slug>-<cut>` and a recorded number is only
/// comparable with another recorded under the same slug.
///
/// Not `@testable`: nothing here needs a non-public symbol, and the ports must
/// be held to their public contract.
@Suite("Storefront comparison runtime linkage")
struct StorefrontRuntimesScaffoldTests {
  @Test("both plain-Swift ports report the benchmark slugs their cuts are named for")
  func portsReportTheirBenchmarkSlugs() {
    #expect(RawObservationStorefrontRuntime.descriptor.slug == "observation-raw")
    #expect(MemoObservationStorefrontRuntime.descriptor.slug == "observation-memo")
  }
}
