import XCTest

/// Cold launch, measured with the metric Apple provides for exactly that.
///
/// The application is a single Release image whose workload size and benchmark
/// overlay are decided by launch arguments rather than by a build flag, which
/// is what makes this number about the shipping binary rather than about a
/// benchmark variant of it.
///
/// See `StorefrontUITestSupport.swift` for what simulator measurements do and
/// do not establish.
@MainActor
final class StorefrontLaunchPerformanceUITests: XCTestCase {
  /// Stops at the first failure; a launch that did not happen makes every later
  /// iteration meaningless.
  override func setUp() {
    continueAfterFailure = false
  }

  /// Measures cold launch through to a responsive first frame.
  ///
  /// `waitUntilResponsive: true` is the point of the test. Cog assembles the
  /// whole graph inside `StorefrontApp.init`, and the mechanism's `operate`
  /// settles the installed service and the starting row window before
  /// `assemble` returns — so a launch metric that stopped at process start
  /// would measure everything except the part this repository is responsible
  /// for.
  ///
  /// This test does **not** use `manuallyStop`: `XCTApplicationLaunchMetric`
  /// ends its own measurement when the app becomes responsive, and there is
  /// nothing to undo afterwards because each iteration launches a new process.
  ///
  /// The benchmark overlay is **off** here, and this is the one measuring test
  /// where that matters. What is being measured is the first frame a shopper
  /// sees, so an overlay that no shipping launch renders would put a benchmark
  /// instrument inside the number that is supposed to describe the shipping
  /// binary. The other measured tests keep the default because the inventory
  /// burst is driven from that overlay and because none of them measures the
  /// launch.
  func testColdLaunchPerformance() {
    let app = StorefrontUITestSession.makeApplication(benchmarkControls: false)
    let options = XCTMeasureOptions()
    options.iterationCount = 5

    measure(metrics: [XCTApplicationLaunchMetric(waitUntilResponsive: true)], options: options) {
      app.launch()
    }
  }
}
