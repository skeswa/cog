import XCTest

/// The three non-scrolling interactions: search, navigation, and checkout.
///
/// Each one exercises a different shape of invalidation. Search replaces the
/// query at the top of the funnel and re-ranks the catalog. Navigation demands
/// a leaf async payload and a recommendation shelf that nothing on the browse
/// screen reads. A cart edit moves the deepest chain in the graph — line,
/// subtotal, promotion optimizer, discounted subtotal — and replaces both
/// downstream quote requests.
///
/// See `StorefrontUITestSupport.swift` for what simulator measurements do and
/// do not establish.
@MainActor
final class StorefrontInteractionPerformanceUITests: XCTestCase {
  /// Stops at the first failure; a measurement over a screen that never
  /// appeared is not a measurement.
  override func setUp() {
    continueAfterFailure = false
  }

  /// Measures typing into the search field.
  ///
  /// Wall clock, CPU, and memory together, because this interaction is the one
  /// place the workload does real synchronous work per keystroke: each accepted
  /// character normalizes the query, re-tokenizes it, re-runs the inverted
  /// index, re-scores every candidate, re-ranks them, and regroups the sections
  /// — and starts a new suggestion request generation while it is at it.
  ///
  /// The reset deletes exactly as many characters as the block typed, which is
  /// idempotent against the extra warm-up invocation: deleting from an already
  /// empty field is a no-op.
  func testSearchInteractionPerformance() {
    let app = StorefrontUITestSession.launch()
    let searchField = StorefrontUITestSession.searchField(in: app)
    XCTAssertTrue(searchField.waitForExistence(timeout: StorefrontUITestSession.timeout))
    searchField.tap()

    let query = "trail"
    let deletions = String(
      repeating: XCUIKeyboardKey.delete.rawValue,
      count: query.count
    )

    let metrics: [any XCTMetric] = [
      XCTClockMetric(),
      XCTCPUMetric(application: app),
      XCTMemoryMetric(application: app),
    ]

    measure(metrics: metrics, options: StorefrontUITestSession.measureOptions()) {
      searchField.typeText(query)
      stopMeasuring()

      searchField.typeText(deletions)
    }
  }

  /// Measures pushing and popping the product detail screen.
  ///
  /// `XCTOSSignpostMetric.navigationTransitionMetric` is iOS-only and reports
  /// the system's own navigation-transition intervals; the clock metric is
  /// beside it so the test still produces a number if the transition signposts
  /// are not emitted under this configuration.
  ///
  /// The measured region ends once the detail screen's add-to-cart button
  /// exists, which is the first moment the pushed screen has actually rendered
  /// its content rather than merely begun animating.
  func testDetailNavigationPerformance() {
    let app = StorefrontUITestSession.launch()
    let firstRow = StorefrontUITestSession.firstProductRow(in: app)
    XCTAssertTrue(firstRow.waitForExistence(timeout: StorefrontUITestSession.timeout))

    let detailAddToCart = app.buttons[StorefrontUITestIdentifiers.detailAddToCart]

    let metrics: [any XCTMetric] = [
      XCTOSSignpostMetric.navigationTransitionMetric,
      XCTClockMetric(),
    ]

    measure(metrics: metrics, options: StorefrontUITestSession.measureOptions()) {
      StorefrontUITestSession.firstProductRow(in: app).tap()
      XCTAssertTrue(
        detailAddToCart.waitForExistence(timeout: StorefrontUITestSession.timeout),
        "the detail screen never rendered"
      )
      stopMeasuring()

      app.navigationBars.buttons.element(boundBy: 0).tap()
      XCTAssertTrue(
        StorefrontUITestSession.firstProductRow(in: app)
          .waitForExistence(timeout: StorefrontUITestSession.timeout),
        "the browse list never came back"
      )
    }
  }

  /// Measures editing the cart and re-pricing the order.
  ///
  /// A coupon is applied once, in setup, so every measured iteration runs the
  /// promotion optimizer against a non-trivial promotion set. The measured
  /// region then changes a line quantity twice and switches the shipping
  /// method, which is the interaction that replaces the shipping and tax
  /// requests and rebuilds the whole order total.
  ///
  /// Both edits are undone after `stopMeasuring()` and both undos are
  /// idempotent in effect: the quantity returns to its starting value and the
  /// shipping method returns to `Standard`, so the discarded warm-up
  /// invocation leaves nothing behind.
  func testCartCheckoutInteractionPerformance() {
    let app = StorefrontUITestSession.launch()

    // Put three distinct products in the cart, from the browse list.
    let addButtons = app.buttons.matching(
      NSPredicate(format: "identifier ENDSWITH '.addToCart'")
    )
    XCTAssertTrue(
      addButtons.element(boundBy: 0).waitForExistence(timeout: StorefrontUITestSession.timeout)
    )
    for index in 0..<3 {
      addButtons.element(boundBy: index).tap()
    }

    app.tabBars.buttons["Cart"].tap()

    let stepper = app.steppers.element(boundBy: 0)
    XCTAssertTrue(
      stepper.waitForExistence(timeout: StorefrontUITestSession.timeout),
      "the cart showed no lines"
    )

    let coupon = app.textFields[StorefrontUITestIdentifiers.couponField]
    XCTAssertTrue(coupon.waitForExistence(timeout: StorefrontUITestSession.timeout))
    coupon.tap()
    coupon.typeText("RIDGE10")

    let increment = stepper.buttons.element(boundBy: 1)
    let decrement = stepper.buttons.element(boundBy: 0)
    let express = app.buttons["Express"]
    let standard = app.buttons["Standard"]
    XCTAssertTrue(express.waitForExistence(timeout: StorefrontUITestSession.timeout))

    let metrics: [any XCTMetric] = [
      XCTClockMetric(),
      XCTCPUMetric(application: app),
    ]

    measure(metrics: metrics, options: StorefrontUITestSession.measureOptions()) {
      increment.tap()
      increment.tap()
      express.tap()
      stopMeasuring()

      standard.tap()
      decrement.tap()
      decrement.tap()
    }
  }
}
