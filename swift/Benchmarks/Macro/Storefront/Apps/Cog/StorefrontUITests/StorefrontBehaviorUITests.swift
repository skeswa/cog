import XCTest

/// The one non-measuring test in this bundle, and the reason the rest of it can
/// be trusted.
///
/// A UI performance test measures whatever the app happens to do. An app that
/// rendered an empty list, ignored the search field, and never updated the cart
/// would still produce five perfectly reproducible numbers per metric — and
/// they would mean nothing. This test proves the three behaviours every
/// measurement below depends on: rows render, adding to the cart reaches the
/// cart tab, and search filters the list. If it fails, the timings are noise
/// and should not be read.
///
/// See `StorefrontUITestSupport.swift` for what simulator measurements do and
/// do not establish.
@MainActor
final class StorefrontBehaviorUITests: XCTestCase {
  /// Stops the whole class at the first failure, because every later assertion
  /// in a run assumes the earlier screens actually appeared.
  override func setUp() {
    continueAfterFailure = false
  }

  /// Proves rows render, that the cart updates, and that search narrows the
  /// list.
  ///
  /// The cart is checked **before** the search, deliberately: typing raises the
  /// software keyboard, which covers the tab bar, so a tab switch afterwards
  /// would be testing the keyboard rather than the app.
  func testStorefrontRendersSearchesAndAddsToCart() {
    let app = StorefrontUITestSession.launch()

    // 1. Rows render, and they carry real catalog content rather than a
    //    resting default: a product name in the label, and more than one row.
    let firstRow = StorefrontUITestSession.firstProductRow(in: app)
    XCTAssertTrue(firstRow.exists, "the browse list rendered no product row")
    XCTAssertFalse(firstRow.label.isEmpty, "the first row rendered no product name")
    XCTAssertGreaterThan(
      StorefrontUITestSession.productRows(in: app).count,
      1,
      "the browse list rendered only one row"
    )

    // 2. Adding to the cart from a row reaches the cart tab. The cart is a
    //    different screen reading different declarations off the same turn, so
    //    this is the end-to-end proof that one write settles everywhere.
    let addToCart = app.buttons["\(firstRow.identifier).addToCart"]
    XCTAssertTrue(
      addToCart.waitForExistence(timeout: StorefrontUITestSession.timeout),
      "the first row had no add-to-cart button"
    )
    addToCart.tap()

    app.tabBars.buttons["Cart"].tap()

    let line = app.steppers.element(boundBy: 0)
    XCTAssertTrue(
      line.waitForExistence(timeout: StorefrontUITestSession.timeout),
      "the cart tab showed no line after adding a product"
    )
    // The total specifically, addressed by identifier. Several summary rows are
    // legitimately zero — there is no coupon, and the quotes rest at their
    // pending defaults until they land — so "is any zero on screen" would be a
    // question about the wrong text.
    let total = app.staticTexts[StorefrontUITestIdentifiers.orderTotal]
    XCTAssertTrue(
      total.waitForExistence(timeout: StorefrontUITestSession.timeout),
      "the cart showed no order total"
    )
    XCTAssertNotEqual(
      total.label,
      "$0.00",
      "the cart total stayed at zero after adding a product"
    )

    // 3. Search filters the list. "tent" is one of the fixture catalog's
    //    product nouns, so a working search index puts a matching product at
    //    the top of the results and a broken one does not.
    app.tabBars.buttons["Browse"].tap()

    let searchField = StorefrontUITestSession.searchField(in: app)
    XCTAssertTrue(searchField.waitForExistence(timeout: StorefrontUITestSession.timeout))
    searchField.tap()
    searchField.typeText("tent")

    let matched = expectation(
      for: NSPredicate(format: "label CONTAINS[c] 'tent'"),
      evaluatedWith: StorefrontUITestSession.firstProductRow(in: app)
    )
    wait(for: [matched], timeout: StorefrontUITestSession.timeout)
  }

  /// Proves the benchmark overlay is not part of an ordinary launch.
  ///
  /// The overlay publishes inventory bursts and resets session state. Those are
  /// measurement instruments, not shop features, and the launch-argument gate is
  /// the only thing keeping them out of the interface a shopper sees — the
  /// Release image contains their code either way. That makes this the one
  /// property of the gate worth asserting rather than assuming.
  func testBenchmarkControlsAreAbsentFromAnOrdinaryLaunch() {
    let app = StorefrontUITestSession.launch(benchmarkControls: false)

    XCTAssertFalse(
      app.buttons[StorefrontUITestIdentifiers.benchmarkBurst].exists,
      "the inventory-burst control appeared without its launch argument"
    )
    XCTAssertFalse(
      app.buttons[StorefrontUITestIdentifiers.benchmarkReset].exists,
      "the session-reset control appeared without its launch argument"
    )
  }
}
