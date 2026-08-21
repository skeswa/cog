import Cog
import CogStorefront
import SwiftUI

/// The cart and its checkout summary.
///
/// This screen is where the workload's deepest chain surfaces: a quantity
/// change moves a line, which moves the subtotal, which re-runs the bounded
/// promotion optimizer, which moves the discounted subtotal, which **replaces**
/// both the shipping and the tax request. The two quotes are read through the
/// status lens because a shopper is entitled to know a total is still being
/// priced, and the total itself is read as an ordinary value because it is
/// total — it rests on the last accepted quotes rather than blanking out.
struct StorefrontCartScreen: View {
  /// The singular graph inherited from ``StorefrontApp``.
  @Environment(\.cogs) private var cogs

  /// Renders the lines, the coupon and shipping controls, and the summary.
  var body: some View {
    // Every value this screen shows, read flatly and bound to a domain local.
    let storefrontCartLines = cogs[storefrontCartLinesCog]
    let storefrontOrderTotal = cogs[storefrontOrderTotalCog]
    let storefrontCheckoutReadiness = cogs[storefrontCheckoutReadinessCog]
    let storefrontShippingQuote = cogs.status[storefrontShippingQuoteCog]
    let storefrontTaxQuote = cogs.status[storefrontTaxQuoteCog]

    NavigationStack {
      List {
        Section("Items") {
          ForEach(storefrontCartLines) { cartLine in
            StorefrontCartLineRow(cartLine: cartLine)
          }
        }

        Section("Checkout") {
          TextField("Coupon code", text: cogs.couponBinding)
            .textInputAutocapitalization(.characters)
            .autocorrectionDisabled()
            .accessibilityIdentifier(StorefrontAccessibility.couponField)

          Picker("Shipping", selection: cogs.shippingMethodBinding) {
            ForEach(ShippingMethod.allCases, id: \.self) { method in
              Text(method.displayName).tag(method)
            }
          }
          .pickerStyle(.segmented)
          .accessibilityIdentifier("cart.shipping")

          StorefrontMoneyRow(title: "Subtotal", cents: storefrontOrderTotal.subtotalCents)
          StorefrontMoneyRow(title: "Discount", cents: -storefrontOrderTotal.discountCents)

          HStack {
            Text("Shipping")
            Spacer()
            ProgressView()
              .opacity(storefrontShippingQuote.isLoading ? 1 : 0)
            Text(StorefrontFormat.money(storefrontShippingQuote.value.costCents))
              .monospacedDigit()
          }

          HStack {
            Text("Tax")
            Spacer()
            ProgressView()
              .opacity(storefrontTaxQuote.isLoading ? 1 : 0)
            Text(StorefrontFormat.money(storefrontTaxQuote.value.taxCents))
              .monospacedDigit()
          }

          HStack {
            Text("Total")
              .font(.headline)
            Spacer()
            Text(StorefrontFormat.money(storefrontOrderTotal.totalCents))
              .font(.headline)
              .monospacedDigit()
              .accessibilityIdentifier(StorefrontAccessibility.orderTotal)
          }

          Text(storefrontCheckoutReadiness.blockers.first ?? "Ready to check out.")
            .font(.caption)
            .foregroundStyle(storefrontCheckoutReadiness.isReady ? Color.secondary : Color.red)
        }
      }
      .navigationTitle("Cart")
      .navigationBarTitleDisplayMode(.inline)
      .accessibilityIdentifier(StorefrontAccessibility.cartSummary)
    }
  }
}

/// One cart line and its quantity stepper.
private struct StorefrontCartLineRow: View {
  /// The singular graph inherited from ``StorefrontApp``.
  @Environment(\.cogs) private var cogs

  /// The line to draw, already settled by the screen that read it.
  let cartLine: CartLine

  /// Draws the line.
  ///
  /// The stepper writes through the named op rather than a binding, because
  /// there is no value to bind: `setCartQuantity` is a domain verb that also
  /// removes the line at zero, and a `Binding` would hide that behind an
  /// assignment.
  var body: some View {
    HStack(spacing: 10) {
      VStack(alignment: .leading, spacing: 2) {
        Text(cartLine.name)
          .font(.subheadline.weight(.semibold))
          .lineLimit(1)
        Text(StorefrontFormat.money(cartLine.unitPriceCents))
          .font(.caption)
          .foregroundStyle(.secondary)
          .monospacedDigit()
      }

      Spacer(minLength: 0)

      Text("\(cartLine.quantity)")
        .font(.subheadline)
        .monospacedDigit()

      Stepper {
        Text("Quantity")
      } onIncrement: {
        cogs.setCartQuantity(cartLine.quantity + 1, for: cartLine.productID)
      } onDecrement: {
        cogs.setCartQuantity(cartLine.quantity - 1, for: cartLine.productID)
      }
      .labelsHidden()
      .accessibilityIdentifier(StorefrontAccessibility.cartStepper(cartLine.productID))
    }
  }
}

/// One labelled money row in the checkout summary.
private struct StorefrontMoneyRow: View {
  /// What the amount is.
  let title: String

  /// The amount, in cents.
  let cents: Int

  /// Draws the row.
  var body: some View {
    HStack {
      Text(title)
      Spacer()
      Text(StorefrontFormat.money(cents))
        .monospacedDigit()
    }
  }
}
