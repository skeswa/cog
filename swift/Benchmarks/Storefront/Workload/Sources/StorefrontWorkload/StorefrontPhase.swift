/// The eleven phases of the standard interaction trace.
///
/// Named so a benchmark cut, a correctness test, and a failure message can all
/// refer to the same step by the same word.
public nonisolated enum StorefrontPhase: String, Sendable, CaseIterable {
  /// Bootstrap, and the loading shell before any response.
  case bootstrap
  /// Accepting catalog and account data and materializing the first viewport.
  case rootData
  /// Resolving the first viewport's inventory and offers, out of order.
  case initialRowData
  /// Scrolling through the session's distinct rows, down and partly back up.
  case scroll
  /// Typing the search query one character at a time.
  case search
  /// Toggling stock, category, and sort filters.
  case filters
  /// Favoriting products and adding three of them to the cart.
  case cart
  /// Opening a product, changing a variant, and returning.
  case detail
  /// Editing quantities, applying a coupon, and changing shipping.
  case checkout
  /// Publishing an inventory burst over visible and offscreen products.
  case burst
  /// Navigating away, then advancing the clock through lifetime grace.
  case teardown
}
