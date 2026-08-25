import CogStorefront
import StorefrontWorkload
import SwiftUI

/// The fixed geometry the UI performance suite depends on.
///
/// Row height is a measurement input, not a taste decision. `XCUIElement`
/// scrolling moves a fixed fraction of the screen, so the number of rows a
/// swipe crosses — and therefore the number of row bodies SwiftUI evaluates
/// inside a measured region — is a function of this constant and the pinned
/// device. Changing it changes every scrolling number, which is why it lives
/// here with an explanation rather than inline at the call site.
enum StorefrontMetrics {
  /// The exact height of every product row, in points.
  static let rowHeight: CGFloat = 76

  /// The exact height of every recommendation card, in points.
  static let recommendationCardHeight: CGFloat = 96

  /// The exact width of every recommendation card, in points.
  static let recommendationCardWidth: CGFloat = 148
}

/// Text rendering for the workload's integer money.
///
/// Hand-written rather than `NumberFormatter`, for the same reason the workload
/// normalizes its own search text: a formatter consults the host's locale, and
/// a benchmark whose rendered strings changed with a device setting would make
/// two runs incomparable for a reason that has nothing to do with Cog.
enum StorefrontFormat {
  /// Renders integer cents as a fixed two-decimal dollar amount.
  ///
  /// - Parameter cents: The amount, which may be negative.
  /// - Returns: A string such as `$12.30`.
  static func money(_ cents: Int) -> String {
    let sign = cents < 0 ? "-" : ""
    let magnitude = abs(cents)
    let fraction = magnitude % 100
    let padded = fraction < 10 ? "0\(fraction)" : "\(fraction)"
    return "\(sign)$\(magnitude / 100).\(padded)"
  }
}

/// Presentation for the workload's badge set.
extension ProductBadges {
  /// Every badge, in the fixed order a row renders them.
  ///
  /// A row draws all seven slots every time and hides the ones it does not
  /// have, so the badge strip's child count is constant. A conditional strip
  /// would make SwiftUI re-establish the row's structural identity whenever a
  /// badge appeared, which is exactly the cost a benchmark must not measure by
  /// accident.
  static let ordered: [ProductBadges] = [
    .onSale, .lowStock, .soldOut, .offer, .favorite, .recentlyViewed, .inCart,
  ]

  /// The SF Symbol drawn for one badge.
  ///
  /// `ProductBadges` is an `OptionSet`, so a `switch` over it needs a `default`
  /// however many cases it lists. Every one of the seven singletons in
  /// ``ordered`` is spelled out, and the fallback is a symbol that looks wrong
  /// on purpose: the only way to reach it is to add a badge to ``ordered``
  /// without teaching this mapping about it, and a visibly wrong glyph reports
  /// that at a glance where a plausible one would hide it.
  var symbolName: String {
    switch self {
    case .onSale: "tag.fill"
    case .lowStock: "exclamationmark.triangle.fill"
    case .soldOut: "xmark.circle.fill"
    case .offer: "gift.fill"
    case .favorite: "heart.fill"
    case .recentlyViewed: "clock.fill"
    case .inCart: "cart.fill"
    default: "questionmark.diamond.fill"
    }
  }

  /// The tint drawn for one badge.
  ///
  /// Spelled out for the same reason ``symbolName`` is, with the same
  /// deliberately conspicuous fallback.
  var tint: Color {
    switch self {
    case .onSale: .green
    case .lowStock: .orange
    case .soldOut: .red
    case .offer: .purple
    case .favorite: .pink
    case .recentlyViewed: .secondary
    case .inCart: .accentColor
    default: .red
    }
  }
}
