public import Cog

// The Storefront's writable state, and every domain verb that writes it.
//
// Sources and ops share one file for a reason the linter enforces: a manual
// source must be `private` (CogLint `manual-cog-private`), and only code in
// this file can therefore name one on the left of a writer assignment. The
// readable surface leaves through `.readOnly` projections, which every automatic
// and async declaration in the neighbouring files reads.
//
// Nothing here is a primitive at a call site. `turn` and `refresh` appear
// only inside `extension CogOps` verbs, which is both the repository's
// convention and what makes the SwiftUI application and the headless driver
// able to perform *the same* user actions rather than two similar ones.

// MARK: - Sources

/// The injected request boundary, and the profile it serves.
///
/// A source rather than a global so a test, a benchmark cut, and the
/// application can each install a different script without any of them
/// reaching into another's world. Every async declaration reads it
/// synchronously, so replacing it invalidates every demanded async state — the
/// same behavior Weather relies on.
private let _storefrontServiceCog = Cog<StorefrontService>.Manual(
  StorefrontService(profile: .standard),
  name: "storefront.service"
)

/// The raw text in the search field, exactly as typed.
private let _searchQueryCog = Cog<String>.Manual("", name: "storefront.searchQuery")

/// The category chip the shopper selected, or `nil` for all categories.
private let _selectedCategoryCog = Cog<CategoryID?>.Manual(
  nil,
  name: "storefront.selectedCategory"
)

/// How results are ordered.
private let _sortModeCog = Cog<SortMode>.Manual(.relevance, name: "storefront.sortMode")

/// Whether out-of-stock products are hidden.
private let _inStockOnlyCog = Cog<Bool>.Manual(false, name: "storefront.inStockOnly")

/// The signed-in shopper, or `nil` before the account response is accepted.
///
/// Deliberately a source rather than a read of the account async cog: signing
/// out is a local action that must not wait on a request, and the mechanism
/// that accepts the account response writes it here. One writable fact, one
/// writable place.
private let _signedInShopperCog = Cog<Shopper?>.Manual(nil, name: "storefront.shopper")

/// The coupon the shopper typed, or `nil`.
private let _couponCog = Cog<CouponCode?>.Manual(nil, name: "storefront.coupon")

/// Where the order ships.
private let _shippingAddressCog = Cog<ShippingAddress>.Manual(
  StorefrontFixtures.startingAddress,
  name: "storefront.shippingAddress"
)

/// How the order ships.
private let _shippingMethodCog = Cog<ShippingMethod>.Manual(
  .standard,
  name: "storefront.shippingMethod"
)

/// The product whose detail screen is open, or `nil` on the browse screen.
private let _selectedProductCog = Cog<ProductID?>.Manual(
  nil,
  name: "storefront.selectedProduct"
)

/// The window of rows the list has materialized.
private let _rowWindowCog = Cog<RowWindow>.Manual(
  RowWindow(offset: 0, length: 0),
  name: "storefront.rowWindow"
)

/// The products in the cart, in the order they were added.
///
/// The membership list is keyless because a cart screen renders it in order,
/// and a keyed box cannot be enumerated. Quantities stay keyed, so changing
/// one line's quantity does not invalidate the others — which is exactly the
/// split a real cart wants and the reason both declarations exist.
private let _cartContentsCog = Cog<[ProductID]>.Manual([], name: "storefront.cartContents")

// MARK: - Keyed sources

/// Whether each product is favorited.
private let _favoriteCogs = CogBox<Bool, ProductID>.Manual(
  false,
  name: "storefront.favorite"
)

/// How many of each product are in the cart.
private let _cartQuantityCogs = CogBox<Int, ProductID>.Manual(
  0,
  name: "storefront.cartQuantity"
)

/// Which variant of each product is selected.
private let _selectedVariantCogs = CogBox<Int, ProductID>.Manual(
  0,
  name: "storefront.selectedVariant"
)

/// How recently each product was viewed; zero means never.
///
/// A rank rather than a list, so a product row can show a "viewed" badge and
/// the pricing ladder can nudge a viewed product without any screen having to
/// enumerate the history.
private let _recentlyViewedRankCogs = CogBox<Int, ProductID>.Manual(
  0,
  name: "storefront.recentlyViewedRank"
)

/// Which inventory generation each product is asking the service for.
///
/// Keyed rather than one global epoch, and that is the whole point of the
/// inventory burst: a burst turns new generations for exactly the products it
/// touches, in one turn, so a checkpoint can prove that the offscreen half of
/// the burst invalidated nothing on screen. A keyless epoch would invalidate
/// every demanded row and make that claim unprovable.
private let _inventoryGenerationCogs = CogBox<Int, ProductID>.Manual(
  0,
  name: "storefront.inventoryGeneration"
)

// MARK: - Readable surface

/// The installed request boundary.
public let storefrontServiceCog = _storefrontServiceCog.readOnly
/// The raw search text.
public let searchQueryCog = _searchQueryCog.readOnly
/// The selected category, or `nil` for all.
public let selectedCategoryCog = _selectedCategoryCog.readOnly
/// The selected sort mode.
public let sortModeCog = _sortModeCog.readOnly
/// Whether out-of-stock products are hidden.
public let inStockOnlyCog = _inStockOnlyCog.readOnly
/// The signed-in shopper, or `nil`.
public let signedInShopperCog = _signedInShopperCog.readOnly
/// The typed coupon, or `nil`.
public let couponCog = _couponCog.readOnly
/// The shipping address.
public let shippingAddressCog = _shippingAddressCog.readOnly
/// The shipping method.
public let shippingMethodCog = _shippingMethodCog.readOnly
/// The open product, or `nil`.
public let selectedProductCog = _selectedProductCog.readOnly
/// The materialized row window.
public let rowWindowCog = _rowWindowCog.readOnly
/// The cart's membership list, in insertion order.
public let cartContentsCog = _cartContentsCog.readOnly
/// Per-product favorite flags.
public let favoriteCogs = _favoriteCogs.readOnly
/// Per-product cart quantities.
public let cartQuantityCogs = _cartQuantityCogs.readOnly
/// Per-product selected variants.
public let selectedVariantCogs = _selectedVariantCogs.readOnly
/// Per-product recency ranks.
public let recentlyViewedRankCogs = _recentlyViewedRankCogs.readOnly
/// Per-product inventory generations.
public let inventoryGenerationCogs = _inventoryGenerationCogs.readOnly

// MARK: - Domain verbs

extension CogOps {
  /// Installs the request boundary this runtime talks to.
  ///
  /// Called from ``StorefrontMechanism`` inside bootstrap, so it settles before
  /// anything observes the graph. A driver or a UI test that needs a different
  /// script passes a different mechanism rather than writing here later.
  ///
  /// - Parameter service: The boundary to install.
  public func installStorefrontService(_ service: StorefrontService) {
    turn(_storefrontServiceCog, to: service)
  }

  /// Records the account response the graph accepted.
  ///
  /// - Parameter shopper: The signed-in shopper, or `nil` when signed out.
  public func signIn(as shopper: Shopper?) {
    turn(_signedInShopperCog, to: shopper)
  }

  /// Types one more character into the search field.
  ///
  /// A whole-value write rather than an append, because the search field's
  /// value is the fact and reconstructing it from keystrokes would be a second
  /// source of the same thing.
  ///
  /// - Parameter text: The field's new contents.
  public func typeSearchQuery(_ text: String) {
    turn(_searchQueryCog, to: text)
  }

  /// Applies the browse screen's filters and window in one turn.
  ///
  /// The realistic multi-source write: tapping a category chip in a real
  /// storefront changes the filter, resets the sort when the shopper had
  /// chosen a price order that no longer makes sense, and scrolls the list
  /// back to the top. Three sources, one turn, one settle — rather than three
  /// turns, two of which render a screen no shopper ever asked for.
  ///
  /// - Parameters:
  ///   - category: The category to filter to, or `nil` for all.
  ///   - sortMode: How to order results.
  ///   - inStockOnly: Whether to hide out-of-stock products.
  public func applyBrowseFilters(
    category: CategoryID?,
    sortMode: SortMode,
    inStockOnly: Bool
  ) {
    turn { c in
      c[_selectedCategoryCog] = category
      c[_sortModeCog] = sortMode
      c[_inStockOnlyCog] = inStockOnly
      c[_rowWindowCog] = RowWindow(
        offset: 0,
        length: c[_rowWindowCog].length
      )
    }
  }

  /// Selects one category without disturbing the rest of the filter bar.
  ///
  /// - Parameter category: The category, or `nil` for all.
  public func selectCategory(_ category: CategoryID?) {
    turn(_selectedCategoryCog, to: category)
  }

  /// Chooses how results are ordered.
  ///
  /// - Parameter mode: The sort mode.
  public func selectSortMode(_ mode: SortMode) {
    turn(_sortModeCog, to: mode)
  }

  /// Shows or hides out-of-stock products.
  ///
  /// - Parameter isOn: Whether to hide them.
  public func setInStockOnly(_ isOn: Bool) {
    turn(_inStockOnlyCog, to: isOn)
  }

  /// Records the rows the list has materialized.
  ///
  /// - Parameter window: The new window.
  public func scrollRows(to window: RowWindow) {
    turn(_rowWindowCog, to: window)
  }

  /// Applies or clears a coupon.
  ///
  /// - Parameter coupon: The typed coupon, or `nil` to clear it.
  public func applyCoupon(_ coupon: CouponCode?) {
    turn(_couponCog, to: coupon)
  }

  /// Chooses where the order ships.
  ///
  /// - Parameter address: The address.
  public func selectShippingAddress(_ address: ShippingAddress) {
    turn(_shippingAddressCog, to: address)
  }

  /// Chooses how the order ships.
  ///
  /// - Parameter method: The method.
  public func selectShippingMethod(_ method: ShippingMethod) {
    turn(_shippingMethodCog, to: method)
  }

  /// Toggles one product's favorite flag.
  ///
  /// - Parameter id: Which product.
  public func toggleFavorite(_ id: ProductID) {
    turn { c in
      c[_favoriteCogs[id]] = !c[_favoriteCogs[id]]
    }
  }

  /// Opens a product's detail screen and records that it was viewed.
  ///
  /// Two sources in one turn, and the rank is calculated from the writer's own
  /// staged reads: the new rank is one past the highest the session has handed
  /// out, which the caller supplies because a rank counter is session
  /// bookkeeping rather than a fact about a product.
  ///
  /// - Parameters:
  ///   - id: Which product.
  ///   - rank: The recency rank to record; larger is more recent.
  public func openProduct(_ id: ProductID, rank: Int) {
    turn { c in
      c[_selectedProductCog] = id
      c[_recentlyViewedRankCogs[id]] = rank
    }
  }

  /// Returns to the browse screen.
  public func closeProduct() {
    turn(_selectedProductCog, to: nil)
  }

  /// Selects a variant of one product.
  ///
  /// - Parameters:
  ///   - variantIndex: Which variant.
  ///   - id: Which product.
  public func selectVariant(_ variantIndex: Int, for id: ProductID) {
    turn(_selectedVariantCogs[id], to: variantIndex)
  }

  /// Adds a product to the cart, or increases its quantity.
  ///
  /// Membership and quantity are two sources and this is one action, so it is
  /// one turn. Writing them separately would let a settled turn observe a
  /// product that is in the cart with quantity zero.
  ///
  /// - Parameters:
  ///   - id: Which product.
  ///   - quantity: How many to add.
  public func addToCart(_ id: ProductID, quantity: Int = 1) {
    turn { c in
      let existing = c[_cartQuantityCogs[id]]
      c[_cartQuantityCogs[id]] = existing + quantity
      if existing == 0 {
        c[_cartContentsCog] = c[_cartContentsCog] + [id]
      }
    }
  }

  /// Sets one line's quantity, removing the line at zero.
  ///
  /// - Parameters:
  ///   - quantity: The new quantity; zero removes the line.
  ///   - id: Which product.
  public func setCartQuantity(_ quantity: Int, for id: ProductID) {
    turn { c in
      c[_cartQuantityCogs[id]] = max(0, quantity)
      if quantity <= 0 {
        c[_cartContentsCog] = c[_cartContentsCog].filter { $0 != id }
      } else if !c[_cartContentsCog].contains(id) {
        c[_cartContentsCog] = c[_cartContentsCog] + [id]
      }
    }
  }

  /// Publishes one inventory burst.
  ///
  /// Every touched product's generation advances in **one** turn, which is what
  /// a warehouse feed actually looks like and what makes the visible-versus-
  /// offscreen invalidation claim measurable: one turn, one settle, and only
  /// the demanded rows among the touched products recompute.
  ///
  /// - Parameters:
  ///   - ids: The products the feed touched.
  ///   - generation: The generation to advance them to.
  public func publishInventoryBurst(_ ids: [ProductID], generation: Int) {
    turn { c in
      for id in ids {
        c[_inventoryGenerationCogs[id]] = generation
      }
    }
  }

  /// Demands a fresh catalog.
  public func refreshCatalog() {
    refresh(storefrontCatalogCog)
  }

  /// Demands fresh recommendations, and hands back the demand's handle.
  ///
  /// The handle is returned rather than discarded because a superseded
  /// recommendation request is a *definite* signal — `.superseded` resolves
  /// without a clock, a poll, or a timeout — and the session's replacement
  /// checkpoint is built on exactly that.
  @discardableResult
  public func refreshRecommendations() -> CogRefresh<[ProductID]> {
    refresh(storefrontRecommendationsCog)
  }

  /// Demands a fresh inventory reading for one product.
  ///
  /// - Parameter id: Which product.
  public func refreshInventory(for id: ProductID) {
    refresh(storefrontInventoryCogs[id])
  }
}
