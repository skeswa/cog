/// Which durable observers a Storefront session registers.
///
/// Each member corresponds to one screen a real shopper would have open, so a
/// hold set is a statement about what the session is looking at rather than a
/// benchmark knob. An unheld screen must demand nothing, start no request, and
/// keep nothing alive; several of the interaction trace's sharpest checkpoints
/// are claims about exactly that.
///
/// Top-level and runtime-neutral on purpose. It was nested inside
/// `StorefrontMechanism`, which conforms to Cog's `Mechanism`, so naming it
/// used to require importing Cog. Every state-management runtime the workload
/// is ported to has to be told which observers to register, and none of them
/// may be made to import Cog to say so, hoisting the type out is what keeps
/// this vocabulary neutral. `StorefrontMechanism.Holds` survives as a
/// typealias so existing Cog call sites keep reading the way they did.
///
/// A plain `OptionSet` over an `Int` bitfield: `Sendable` and trivially
/// copyable, so it crosses isolation boundaries and lands in a runtime's
/// bootstrap without ceremony.
public nonisolated struct StorefrontHolds: OptionSet, Sendable {
  /// The bit field that records which observers stay registered.
  public let rawValue: Int

  /// Creates a hold set from its observer bit field.
  public init(rawValue: Int) {
    self.rawValue = rawValue
  }

  /// Accept the account response into the signed-in-shopper source.
  ///
  /// Effectively always wanted: pricing, offers, and recommendations all read
  /// the shopper, and nothing else writes it.
  public static let account = StorefrontHolds(rawValue: 1 << 0)

  /// Hold the visible rows, and demand the prefetch margin.
  public static let browse = StorefrontHolds(rawValue: 1 << 1)

  /// Hold the search suggestions the search field displays.
  public static let search = StorefrontHolds(rawValue: 1 << 2)

  /// Hold the cart's money and readiness.
  public static let cart = StorefrontHolds(rawValue: 1 << 3)

  /// Hold the open product's detail payload and the recommendation shelf.
  public static let detail = StorefrontHolds(rawValue: 1 << 4)

  /// Everything a headless driver wants.
  public static let all: StorefrontHolds = [.account, .browse, .search, .cart, .detail]

  /// The browse-only subset the quiescent interaction cut uses.
  ///
  /// Deliberately excludes `.cart`'s downstream quotes and `.search`'s
  /// suggestion requests, because a measured region that starts async work is
  /// not a region process-global allocation counters may be attached to.
  public static let quiescentBrowse: StorefrontHolds = [.account, .browse]
}
