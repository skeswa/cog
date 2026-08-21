import Cog
import CogStorefront
import SwiftUI

/// One product row in the browse list.
///
/// The row reads **exactly one** keyed value, `storefrontProductRowCogs[id]`,
/// and maps it to views. That is the whole point of the declaration existing:
/// nine inputs — the price ladder, live inventory, the personalized offer, the
/// favorite flag, the cart quantity, the view history — funnel into one
/// equality-gated value, so this body re-runs when what it draws changed and
/// not when something it does not draw did. An inventory burst that touches an
/// offscreen product reaches no row on screen at all.
///
/// The row's child count is constant. There is no lopsided `if`, no `AnyView`,
/// and no conditional badge strip; hidden badges are drawn at zero opacity so
/// SwiftUI never has to re-establish the row's structural identity because a
/// product went on sale.
struct StorefrontProductRowView: View {
  /// The singular graph inherited from ``StorefrontApp``.
  @Environment(\.cogs) private var cogs

  /// Which product this row draws.
  let productID: ProductID

  /// This row's index across every section, counting rows only.
  ///
  /// The graph's row window is one flat range, so a row must know where it sits
  /// in the flattened list rather than within its section.
  let flatIndex: Int

  /// The browse screen's shared realization ledger.
  ///
  /// A plain object, not the runtime: a row reports that it exists and learns
  /// nothing in return. Passing it is ordinary SwiftUI composition, and it is
  /// what lets the window be committed from the row that actually moved it
  /// without every row owning a copy of the bookkeeping.
  let rowWindowTracker: StorefrontRowWindowTracker

  /// Renders the row and reports its realization to the graph.
  var body: some View {
    let storefrontProductRow = cogs[storefrontProductRowCogs[productID]]

    HStack(spacing: 10) {
      NavigationLink(value: productID) {
        VStack(alignment: .leading, spacing: 2) {
          Text(storefrontProductRow.name)
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)

          Text(storefrontProductRow.categoryName)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)

          StorefrontBadgeStrip(badges: storefrontProductRow.badges)
        }
      }
      .accessibilityIdentifier(StorefrontAccessibility.row(productID))

      VStack(alignment: .trailing, spacing: 2) {
        Text(StorefrontFormat.money(storefrontProductRow.priceCents))
          .font(.subheadline.weight(.semibold))
          .monospacedDigit()

        Text("\(storefrontProductRow.availableUnits) left")
          .font(.caption2)
          .foregroundStyle(.secondary)
          .monospacedDigit()
      }

      Button {
        cogs.toggleFavorite(productID)
      } label: {
        Image(
          systemName: storefrontProductRow.badges.contains(.favorite) ? "heart.fill" : "heart"
        )
      }
      .buttonStyle(.borderless)
      .accessibilityIdentifier(StorefrontAccessibility.favoriteButton(productID))
      .accessibilityLabel("Favorite \(storefrontProductRow.name)")

      Button {
        cogs.addToCart(productID, quantity: 1)
      } label: {
        Image(systemName: "cart.badge.plus")
      }
      .buttonStyle(.borderless)
      .accessibilityIdentifier(StorefrontAccessibility.addToCartButton(productID))
      .accessibilityLabel("Add \(storefrontProductRow.name) to cart")
    }
    .frame(height: StorefrontMetrics.rowHeight)
    .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
    .onAppear {
      if let window = rowWindowTracker.rowAppeared(flatIndex) {
        cogs.scrollRows(to: window)
      }
    }
    .onDisappear {
      if let window = rowWindowTracker.rowDisappeared(flatIndex) {
        cogs.scrollRows(to: window)
      }
    }
  }
}

/// The seven badge slots a row always draws.
///
/// A constant seven children, each either opaque or transparent. Drawing only
/// the badges a product has would change the strip's child count as inventory
/// moved, which is the one thing Apple's list guidance asks a row not to do.
struct StorefrontBadgeStrip: View {
  /// Which badges this product currently has.
  let badges: ProductBadges

  /// Draws every slot, hiding the ones that do not apply.
  var body: some View {
    HStack(spacing: 4) {
      ForEach(ProductBadges.ordered, id: \.rawValue) { badge in
        Image(systemName: badge.symbolName)
          .font(.caption2)
          .foregroundStyle(badge.tint)
          .opacity(badges.contains(badge) ? 1 : 0)
      }
    }
    .accessibilityHidden(true)
  }
}
