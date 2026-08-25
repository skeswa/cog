import XCTest

// Scrolling, measured twice: once over a settled feed, and once while the graph
// is accepting a deterministic inventory burst.
//
// **Simulator data is a pinned regression signal, not a user-experience
// guarantee.** These numbers are comparable with other numbers from the same
// host, the same pinned Xcode, and the same simulated device. They are not
// evidence about what a person holding an iPhone experiences, and an absolute
// hitch-ratio target belongs on a pinned physical device.
//
// **Apple's published guidance, quoted.** For the Xcode Organizer's Hitches
// metric, Apple writes: "A hitch rate at or below 10 ms/s is good; at or below
// 25 ms/s is a warning; at or below 50 ms/s is critical; and above 50 ms/s
// warrants immediate attention." That is field data from real devices through
// the Organizer — a different instrument from `XCTHitchMetric` in a simulator.
// It is quoted here so nobody invents a threshold.
//
// **No device requirement is claimed.** Apple does not document which
// `XCTMetric` types require a physical device, so this file claims none.
// `XCTOSSignpostMetric.scrollingAndDecelerationMetric` depends on the scroll
// view under test emitting UIKit's scrolling signposts; that SwiftUI's `List`
// emits them is not documented by Apple either, and if a run produces no
// interval data that is reported as an observation rather than papered over.
//
// **What this configuration actually produced**, read out of the result bundle
// rather than assumed — Xcode 26.4 (17E192), iPhone 17 Pro simulator running
// iOS 26.4 (23E244), Release:
//
// - `scrollingAndDecelerationMetric` produced exactly one series,
//   `Duration (Scroll_DraggingAndDeceleration)`. SwiftUI's `List` does emit the
//   signposts. No hitch-time ratio and no frame count came with them.
// - `XCTHitchMetric(application:)` produced **nothing**. It is requested below
//   whenever the runtime is new enough to have it, the availability check
//   passes on this simulator, and the result bundle still carries no hitch
//   series at all.
//
// That is the observation, not a rule: the metric stays in the list because a
// pinned physical device is where a hitch number would mean something, and
// asking for it there costs this suite nothing. Nobody should read a hitch
// figure out of a simulator run of this file, because there is not one.

/// Scrolling the browse feed.
@MainActor
final class StorefrontScrollPerformanceUITests: XCTestCase {
  /// Stops at the first failure; a measurement over a screen that never
  /// appeared is not a measurement.
  override func setUp() {
    continueAfterFailure = false
  }

  /// Measures scrolling a feed that is completely settled.
  ///
  /// The baseline: every visible row's price ladder, inventory reading, and
  /// offer have already landed, so what is being measured is the cost of
  /// realizing new rows and of the graph demanding data for the rows that just
  /// came into the window.
  ///
  /// Apple's own reset pattern (WWDC20, session 10077): `manuallyStop`, an
  /// explicit `stopMeasuring()`, and the scroll-position reset **after** it.
  /// The reset is idempotent — over-scrolling a list that is already at the top
  /// does nothing — which it has to be, because `iterationCount` is not the
  /// invocation count: the block runs one extra time and the first result is
  /// discarded.
  func testSettledFeedScrollingPerformance() {
    let app = StorefrontUITestSession.launch()
    let list = StorefrontUITestSession.browseList(in: app)
    XCTAssertTrue(list.waitForExistence(timeout: StorefrontUITestSession.timeout))

    var metrics: [any XCTMetric] = [XCTOSSignpostMetric.scrollingAndDecelerationMetric]
    if #available(iOS 26.0, *) {
      metrics.append(XCTHitchMetric(application: app))
    }

    measure(metrics: metrics, options: StorefrontUITestSession.measureOptions()) {
      list.swipeUp(velocity: .fast)
      list.swipeUp(velocity: .fast)
      list.swipeUp(velocity: .fast)
      stopMeasuring()

      list.swipeDown(velocity: .fast)
      list.swipeDown(velocity: .fast)
      list.swipeDown(velocity: .fast)
      list.swipeDown(velocity: .fast)
    }
  }

  /// Measures scrolling while the graph accepts an inventory burst.
  ///
  /// The burst is the workload's realistic write storm: one turn advances the
  /// inventory generation of every product currently on screen, which
  /// invalidates each of their keyed inventory requests, their pricing ladders
  /// from the markdown stage down, their badges, and their row values — while
  /// the list is moving.
  ///
  /// It is driven from the benchmark overlay rather than from a timer inside
  /// the app, so the burst happens at a point the test chooses instead of one
  /// the scheduler chooses. The overlay's `Reset` button puts the session's
  /// filters and window back afterwards, and the generation counter is
  /// monotonic, so the extra warm-up invocation changes nothing a later
  /// iteration can observe.
  func testScrollingDuringInventoryBurstPerformance() {
    let app = StorefrontUITestSession.launch()
    let list = StorefrontUITestSession.browseList(in: app)
    XCTAssertTrue(list.waitForExistence(timeout: StorefrontUITestSession.timeout))

    let burst = app.buttons[StorefrontUITestIdentifiers.benchmarkBurst]
    let reset = app.buttons[StorefrontUITestIdentifiers.benchmarkReset]
    XCTAssertTrue(
      burst.waitForExistence(timeout: StorefrontUITestSession.timeout),
      "the benchmark overlay was not present; the launch argument did not take"
    )

    var metrics: [any XCTMetric] = [XCTOSSignpostMetric.scrollingAndDecelerationMetric]
    if #available(iOS 26.0, *) {
      metrics.append(XCTHitchMetric(application: app))
    }

    measure(metrics: metrics, options: StorefrontUITestSession.measureOptions()) {
      burst.tap()
      list.swipeUp(velocity: .fast)
      burst.tap()
      list.swipeUp(velocity: .fast)
      burst.tap()
      list.swipeUp(velocity: .fast)
      stopMeasuring()

      reset.tap()
      list.swipeDown(velocity: .fast)
      list.swipeDown(velocity: .fast)
      list.swipeDown(velocity: .fast)
      list.swipeDown(velocity: .fast)
    }
  }
}
