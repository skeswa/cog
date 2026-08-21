import CogStorefront

/// Every accessibility identifier the UI performance suite addresses.
///
/// These strings are the application's test-facing contract and the only thing
/// the UI-test bundle knows about it. That bundle deliberately links neither
/// this target nor `CogStorefront` — a UI test drives an app through its
/// interface, and a runner that linked the workload would hold a second copy of
/// the workload's globals — so `StorefrontUITests` repeats these literals in
/// its own file. Changing one without the other breaks a test loudly at the
/// first `waitForExistence`, which is the failure mode we want; sharing them
/// through a linked module would be worse than the duplication.
///
/// A derived identifier is always built here rather than interpolated at a call
/// site, so there is exactly one spelling of each shape.
enum StorefrontAccessibility {
  /// The browse list itself, and the marker that the first screen is up.
  static let browseList = "browse.list"

  /// The search field wrapper, used to wait for the browse screen.
  static let searchField = "browse.search"

  /// The sort menu button.
  static let sortMenu = "browse.sort"

  /// The in-stock-only toggle.
  static let inStockToggle = "browse.inStockOnly"

  /// The button that applies category, sort, and stock filters in one turn.
  static let applyFilters = "browse.applyFilters"

  /// The button that clears every filter chip back to "All".
  static let allCategoriesChip = "browse.category.all"

  /// The cart screen's checkout summary.
  static let cartSummary = "cart.summary"

  /// The cart's coupon field.
  static let couponField = "cart.coupon"

  /// The cart's order total.
  static let orderTotal = "cart.total"

  /// The detail screen's recommendation shelf.
  static let recommendationShelf = "detail.recommendations"

  /// The detail screen root, used to wait for a completed navigation.
  static let detailScreen = "detail.screen"

  /// The benchmark overlay's inventory-burst button.
  static let benchmarkBurst = "bench.publishInventoryBurst"

  /// The benchmark overlay's session-reset button.
  static let benchmarkReset = "bench.reset"

  /// One product row in the browse list.
  ///
  /// - Parameter id: Which product.
  /// - Returns: That row's identifier.
  static func row(_ id: ProductID) -> String {
    "product.\(id.raw)"
  }

  /// One row's favorite button.
  ///
  /// - Parameter id: Which product.
  /// - Returns: That button's identifier.
  static func favoriteButton(_ id: ProductID) -> String {
    "product.\(id.raw).favorite"
  }

  /// One row's add-to-cart button.
  ///
  /// - Parameter id: Which product.
  /// - Returns: That button's identifier.
  static func addToCartButton(_ id: ProductID) -> String {
    "product.\(id.raw).addToCart"
  }

  /// One category filter chip.
  ///
  /// - Parameter id: Which category.
  /// - Returns: That chip's identifier.
  static func categoryChip(_ id: CategoryID) -> String {
    "browse.category.\(id.raw)"
  }

  /// One cart line's quantity stepper.
  ///
  /// - Parameter id: Which product's line.
  /// - Returns: That stepper's identifier.
  static func cartStepper(_ id: ProductID) -> String {
    "cart.line.\(id.raw).quantity"
  }
}
