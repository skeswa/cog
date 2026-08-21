import Cog
import CogStorefront
import SwiftUI

// The SwiftUI control bindings, and the only helpers this application puts on
// the runtime itself.
//
// A `Binding` is the one shape a graph extension may legitimately take: a
// control needs a getter and a setter in one value, and the alternative is a
// `@State` mirror of a fact the graph already owns — a second source of the
// same thing, which rule 4 forbids outright. Each binding below reads exactly
// one declaration and writes through exactly one named op, so nothing here
// hides a multi-read projection behind a helper.

/// The SwiftUI control bindings.
///
/// Every member is a `Binding` over exactly one declaration and one named op,
/// so nothing here is a value helper that a consumer could read instead of
/// reading the graph flatly. A getter runs inside whichever `body` evaluates
/// it, so the read registers on that view exactly as an inline read would.
extension Cogs {
  /// A tracked binding to the search field's text.
  ///
  /// The getter is a UI-boundary read, which is why this lives on the runtime
  /// rather than on the shared op surface: `CogOps` is what a mechanism holds,
  /// and a mechanism has no search field.
  var searchQueryBinding: Binding<String> {
    Binding(
      get: {
        let searchQuery = self[searchQueryCog]
        return searchQuery
      },
      set: { self.typeSearchQuery($0) }
    )
  }

  /// A tracked binding to the typed coupon.
  ///
  /// A text field cannot hold `nil`, and the graph must not confuse "cleared"
  /// with "typed nothing", so the empty string maps to no coupon in both
  /// directions rather than storing an empty ``CouponCode``.
  var couponBinding: Binding<String> {
    Binding(
      get: {
        let coupon = self[couponCog]
        return coupon?.raw ?? ""
      },
      set: { text in
        self.applyCoupon(text.isEmpty ? nil : CouponCode(text))
      }
    )
  }

  /// A tracked binding to the shipping method the checkout picker shows.
  var shippingMethodBinding: Binding<ShippingMethod> {
    Binding(
      get: {
        let shippingMethod = self[shippingMethodCog]
        return shippingMethod
      },
      set: { self.selectShippingMethod($0) }
    )
  }

  /// A tracked binding to the out-of-stock filter switch.
  var inStockOnlyBinding: Binding<Bool> {
    Binding(
      get: {
        let inStockOnly = self[inStockOnlyCog]
        return inStockOnly
      },
      set: { self.setInStockOnly($0) }
    )
  }
}
