import Cog
import CogStorefront
import StorefrontWorkload
import SwiftUI

/// How many detail screens this launch has opened.
///
/// Platform-ephemeral session bookkeeping, and deliberately not graph state.
/// `CogOps.openProduct(_:rank:)` takes the rank as a parameter for exactly this
/// reason: "how recently did I look at this product" is a fact about a product
/// and lives in the graph, while "how many products have I looked at so far"
/// is a counter belonging to one run of one process. Putting the counter in the
/// graph would add a source nothing renders and invalidate a keyed value on
/// every navigation.
@MainActor private var storefrontOpenedProductCount = 0

/// Hands out the next recency rank.
///
/// - Returns: A rank larger than every rank handed out before it.
@MainActor private func nextProductViewRank() -> Int {
  storefrontOpenedProductCount += 1
  return storefrontOpenedProductCount
}

/// One product's detail screen: its async payload, its variants, and a
/// personalized recommendation shelf.
///
/// This is the leaf of the workload's async graph. Nothing on the browse screen
/// reads `storefrontDetailCogs`, so the payload is demanded when this screen
/// appears and released once the screen goes away and its grace elapses — which
/// is the lifetime claim the headless driver measures and this screen exercises
/// through a real navigation.
struct StorefrontProductDetailScreen: View {
  /// The singular graph inherited from ``StorefrontApp``.
  @Environment(\.cogs) private var cogs

  /// Which product this screen shows.
  let productID: ProductID

  /// Renders the payload, the variant picker, and the recommendation shelf.
  var body: some View {
    // The status lens, because this screen is where a shopper is entitled to
    // see that something is still arriving. Creating the local observes no
    // field by itself: the getters below register `value` and `isLoading`, and
    // nothing else in the status participates in this body's invalidation.
    let storefrontDetail = cogs.status[storefrontDetailCogs[productID]]
    let storefrontProductRow = cogs[storefrontProductRowCogs[productID]]
    let storefrontService = cogs[storefrontServiceCog]
    let variantCount = storefrontService.profile.variantCount

    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        VStack(alignment: .leading, spacing: 4) {
          Text(storefrontProductRow.name)
            .font(.title2.bold())
          Text(storefrontProductRow.categoryName)
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }

        HStack(alignment: .firstTextBaseline, spacing: 10) {
          Text(StorefrontFormat.money(storefrontProductRow.priceCents))
            .font(.title3.weight(.semibold))
            .monospacedDigit()

          Text(StorefrontFormat.money(storefrontProductRow.listPriceCents))
            .font(.subheadline)
            .strikethrough()
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .opacity(storefrontProductRow.priceCents < storefrontProductRow.listPriceCents ? 1 : 0)

          Spacer(minLength: 0)

          ProgressView()
            .opacity(storefrontDetail.isLoading ? 1 : 0)
        }

        StorefrontBadgeStrip(badges: storefrontProductRow.badges)

        Picker(
          "Variant",
          selection: cogs.selectedVariantBinding(for: productID)
        ) {
          ForEach(0..<variantCount, id: \.self) { index in
            Text("Variant \(index + 1)").tag(index)
          }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("detail.variant")

        Text(storefrontDetail.value.summary)
          .font(.body)
          .frame(maxWidth: .infinity, alignment: .leading)

        Text("\(storefrontDetail.value.reviewCount) reviews")
          .font(.footnote)
          .foregroundStyle(.secondary)
          .monospacedDigit()

        Button {
          cogs.addToCart(productID, quantity: 1)
        } label: {
          Label("Add to cart", systemImage: "cart.badge.plus")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier("detail.addToCart")

        StorefrontRecommendationShelf()
      }
      .padding(16)
    }
    .navigationTitle("Details")
    .navigationBarTitleDisplayMode(.inline)
    .accessibilityIdentifier(StorefrontAccessibility.detailScreen)
    .task {
      cogs.openProduct(productID, rank: nextProductViewRank())
    }
    .onDisappear {
      cogs.closeProduct()
    }
  }
}

/// The personalized recommendation shelf.
///
/// A horizontal `ScrollView` over a `LazyHStack`, so only the cards on screen
/// build their bodies — and only those cards demand a product row, an
/// inventory reading, and an offer. A plain `HStack` would demand all of them
/// the moment the detail screen appeared, which is the request storm the
/// workload's funnel exists to avoid.
private struct StorefrontRecommendationShelf: View {
  /// The singular graph inherited from ``StorefrontApp``.
  @Environment(\.cogs) private var cogs

  /// Renders the shelf.
  var body: some View {
    let storefrontRecommendations = cogs[storefrontRecommendationsCog]

    VStack(alignment: .leading, spacing: 8) {
      Text("Recommended for you")
        .font(.headline)

      ScrollView(.horizontal, showsIndicators: false) {
        LazyHStack(spacing: 10) {
          ForEach(storefrontRecommendations, id: \.self) { id in
            StorefrontRecommendationCard(productID: id)
          }
        }
        .padding(.vertical, 2)
      }
      .frame(height: StorefrontMetrics.recommendationCardHeight + 8)
    }
    .accessibilityIdentifier(StorefrontAccessibility.recommendationShelf)
  }
}

/// One recommendation card.
private struct StorefrontRecommendationCard: View {
  /// The singular graph inherited from ``StorefrontApp``.
  @Environment(\.cogs) private var cogs

  /// Which product this card draws.
  let productID: ProductID

  /// Draws the card from the same one keyed row value the browse list uses.
  var body: some View {
    let storefrontProductRow = cogs[storefrontProductRowCogs[productID]]

    VStack(alignment: .leading, spacing: 4) {
      Text(storefrontProductRow.name)
        .font(.caption.weight(.semibold))
        .lineLimit(2)

      Spacer(minLength: 0)

      Text(StorefrontFormat.money(storefrontProductRow.priceCents))
        .font(.caption)
        .monospacedDigit()
    }
    .padding(8)
    .frame(
      width: StorefrontMetrics.recommendationCardWidth,
      height: StorefrontMetrics.recommendationCardHeight,
      alignment: .topLeading
    )
    .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
  }
}
