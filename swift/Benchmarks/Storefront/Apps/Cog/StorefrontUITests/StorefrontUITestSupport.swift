import XCTest

// Shared launch, wait, and addressing helpers for Storefront UI performance.
//
// **Simulator data is a pinned regression signal, not a user-experience
// guarantee.** Simulator results are comparable only on the same host, pinned
// Xcode, and simulated device. They can catch regressions but do not describe
// physical iPhone performance. Absolute hitch targets need a pinned device.
//
// **Apple's published guidance, quoted.** For the Xcode Organizer's Hitches
// metric, Apple defines bands at 10, 25, and 50 ms/s. Those thresholds cover
// Organizer field data from real devices, not simulator `XCTHitchMetric`. This
// suite does not gate against them.
//
// **No device requirement is claimed.** Apple does not document which
// `XCTMetric` types require a physical device. This file makes no unsourced
// claim. `StorefrontScrollPerformanceUITests.swift` records one observation:
// `XCTHitchMetric` produced no simulator result series.

/// Every accessibility identifier this suite addresses.
///
/// A deliberate copy of the application's `StorefrontAccessibility`. This
/// bundle links neither the application nor `CogStorefront`: a UI test drives
/// an app through its interface, and a runner that linked the workload would
/// hold a second copy of the workload's globals in its own process for no
/// benefit, nothing asserted here needs a profile number, only a string the
/// interface exposes. The cost of the copy is that renaming an identifier on
/// one side fails a `waitForExistence` on the other, which is a loud failure at
/// the first test rather than a quiet one later.
enum StorefrontUITestIdentifiers {
  /// The browse list, which surfaces as a collection view.
  static let browseList = "browse.list"

  /// The sort menu button.
  static let sortMenu = "browse.sort"

  /// The in-stock-only switch.
  static let inStockToggle = "browse.inStockOnly"

  /// The one control that writes three filter sources in a single turn.
  static let applyFilters = "browse.applyFilters"

  /// The chip that clears the category filter.
  static let allCategoriesChip = "browse.category.all"

  /// The detail screen's add-to-cart button.
  static let detailAddToCart = "detail.addToCart"

  /// The detail screen's variant picker.
  static let detailVariant = "detail.variant"

  /// The cart's coupon field.
  static let couponField = "cart.coupon"

  /// The cart's order total.
  static let orderTotal = "cart.total"

  /// The cart's shipping picker.
  static let cartShipping = "cart.shipping"

  /// The benchmark overlay's inventory-burst button.
  static let benchmarkBurst = "bench.publishInventoryBurst"

  /// The benchmark overlay's session-reset button.
  static let benchmarkReset = "bench.reset"

  /// The prefix every product row identifier starts with.
  static let productRowPrefix = "product."
}

/// Launching and addressing the application under measurement.
///
/// Every test resets the app to an identical starting world **outside** its
/// measured region by launching a fresh process: the graph is app-wide and
/// assembled once per launch, so a new process is the only reset that is
/// genuinely complete. The measured region then contains nothing but the
/// interaction under test.
@MainActor
enum StorefrontUITestSession {
  /// The profile every simulator run uses.
  ///
  /// `smoke` rather than `standard`, deliberately. The reported representative
  /// numbers come from the headless benchmark cuts; what this suite adds is the
  /// behaviour of a real SwiftUI list, a real navigation, and a real search
  /// field, and it must finish quickly enough to run on every pull request. A
  /// launch that wanted the representative workload passes `standard`
  /// explicitly, the application requires that, and defaults to `smoke`
  /// otherwise.
  static let profile = "smoke"

  /// How long a first screen may take before a test gives up.
  static let timeout: TimeInterval = 60

  /// Builds a configured but **unlaunched** application.
  ///
  /// Separate from ``launch(benchmarkControls:)`` because the cold-launch
  /// measurement has to call `launch()` inside its own measured block.
  ///
  /// - Parameter benchmarkControls: Whether to reveal the benchmark overlay.
  /// - Returns: The configured application proxy.
  static func makeApplication(benchmarkControls: Bool = true) -> XCUIApplication {
    let app = XCUIApplication()
    var arguments = ["-cog-storefront-profile", profile]
    if benchmarkControls {
      arguments.append("-cog-storefront-benchmark-controls")
    }
    app.launchArguments = arguments
    return app
  }

  /// Launches the application and waits until the catalog has rendered.
  ///
  /// Waiting on a real product row rather than on the window is what the
  /// synchronous half of the graph settles against: the catalog request, the
  /// search index, the ranking, and the sections have all landed, because a row
  /// cannot exist until they have.
  ///
  /// It is deliberately **not** a claim that every per-row request has landed.
  /// A row's inventory reading and personalized offer are async and rest on
  /// their declared defaults until they arrive, so a row can be on screen with
  /// a resting price for a few milliseconds after this returns. That is the
  /// honest reason `measureOptions(iterations:)` leans on XCTest discarding the
  /// first invocation rather than on a stronger wait here: there is no
  /// identifier on a row that distinguishes a resting price from an arrived
  /// one, and inventing one would put a test hook in the measured view.
  ///
  /// - Parameter benchmarkControls: Whether to reveal the benchmark overlay.
  /// - Returns: The launched application proxy.
  @discardableResult
  static func launch(benchmarkControls: Bool = true) -> XCUIApplication {
    let app = makeApplication(benchmarkControls: benchmarkControls)
    app.launch()
    XCTAssertTrue(
      firstProductRow(in: app).waitForExistence(timeout: timeout),
      "the browse list never rendered a product row"
    )
    return app
  }

  /// The browse list itself.
  ///
  /// - Parameter app: The application under test.
  /// - Returns: The list element.
  static func browseList(in app: XCUIApplication) -> XCUIElement {
    app.collectionViews[StorefrontUITestIdentifiers.browseList]
  }

  /// Every product row currently in the accessibility tree.
  ///
  /// Matched by identifier prefix rather than by an exact product, because
  /// which products rank first is the workload's business and a test that
  /// hard-coded one would be asserting on the ranking rather than on the
  /// interface.
  ///
  /// - Parameter app: The application under test.
  /// - Returns: A query over the row buttons.
  static func productRows(in app: XCUIApplication) -> XCUIElementQuery {
    app.buttons.matching(
      NSPredicate(
        format:
          "identifier BEGINSWITH %@ AND NOT (identifier CONTAINS '.favorite')"
          + " AND NOT (identifier CONTAINS '.addToCart')",
        StorefrontUITestIdentifiers.productRowPrefix
      )
    )
  }

  /// The first product row in the list.
  ///
  /// - Parameter app: The application under test.
  /// - Returns: The row element.
  static func firstProductRow(in app: XCUIApplication) -> XCUIElement {
    productRows(in: app).element(boundBy: 0)
  }

  /// The search field the browse screen installs.
  ///
  /// - Parameter app: The application under test.
  /// - Returns: The search field element.
  static func searchField(in app: XCUIApplication) -> XCUIElement {
    app.searchFields.element(boundBy: 0)
  }

  /// The measure options every performance test in this suite shares.
  ///
  /// `manuallyStop` is Apple's own pattern for a measurement that has to undo
  /// its own effect: the block ends the measured region with `stopMeasuring()`
  /// and then puts the app back where it started. It matters here because
  /// `iterationCount` is **not** the invocation count, the block runs one
  /// extra time and the first result is discarded, so every reset a block
  /// performs has to be idempotent and has to tolerate that extra run.
  ///
  /// - Parameter iterations: How many results to keep.
  /// - Returns: The configured options.
  static func measureOptions(iterations: Int = 5) -> XCTMeasureOptions {
    let options = XCTMeasureOptions()
    options.iterationCount = iterations
    options.invocationOptions = [.manuallyStop]
    return options
  }
}
