public import Cog
public import StorefrontWorkload

/// The Storefront's one mechanism: initial state, the account reaction, and the
/// durable leases a headless driver needs.
///
/// Initial app state lives here rather than in the app entry point, which is
/// both the repository's convention and the only placement that works:
/// `operate` runs inside bootstrap, so the installed service and the starting
/// row window settle before anything observes the graph, and no watcher sees
/// the pre-initial world on its way past.
///
/// The `holds` set is the one thing that differs between the application and
/// the headless driver. A SwiftUI app needs no leases, its views are the
/// observation. A benchmark has no views, so it registers reactions instead,
/// which is also what keeps a measured region quiescent: a reaction lease
/// neither drops the context nor renews a `whileObserved` grace sleeper the way
/// a bare `peek` inside the measured region would.
public struct StorefrontMechanism: Mechanism {
  /// Which durable leases this mechanism registers.
  ///
  /// A typealias rather than a nested type: the set of screens a session holds
  /// open is runtime-neutral vocabulary and now lives in `StorefrontWorkload`
  /// as ``StorefrontHolds``, where a port with no Cog in it can name it. The
  /// alias keeps `StorefrontMechanism.Holds`, and, more importantly, the bare
  /// `[.account]` literal at every existing call site, spelled exactly as it
  /// was.
  public typealias Holds = StorefrontHolds

  /// Attribution in debug history and task names.
  public let name: String

  /// The request boundary to install.
  public let service: StorefrontService

  /// The row window to start at.
  public let initialWindow: RowWindow

  /// Which leases to register.
  public let holds: Holds

  /// Where held reactions deposit what they read.
  public let sink: StorefrontSink

  /// Creates the mechanism.
  ///
  /// - Parameters:
  ///   - name: Attribution; defaults to `Storefront`.
  ///   - service: The request boundary to install.
  ///   - initialWindow: The row window to start at. The application overwrites
  ///     this as soon as SwiftUI reports real geometry; a headless driver keeps
  ///     it, which is why the profile's viewport count is the honest default.
  ///   - holds: Which durable leases to register.
  ///   - sink: Where held reactions deposit what they read.
  public init(
    name: String = "Storefront",
    service: StorefrontService,
    initialWindow: RowWindow,
    holds: Holds = [.account],
    sink: StorefrontSink
  ) {
    self.name = name
    self.service = service
    self.initialWindow = initialWindow
    self.holds = holds
    self.sink = sink
  }

  /// Installs initial state and registers the requested leases.
  ///
  /// - Parameter m: This mechanism's whole relationship with the graph.
  public func operate(_ m: MechanismController) {
    m.installStorefrontService(service)
    m.scrollRows(to: initialWindow)

    let sink = sink

    if holds.contains(.account) {
      // `.run` so the account request is demanded during bootstrap and the
      // resting `nil` is written through immediately, rather than the first
      // screen having to trigger it.
      m.watch(storefrontAccountCog, initial: .run, name: "account") { [weak m] _, shopper in
        sink.recordAccount()
        m?.signIn(as: shopper)
      }
    }

    if holds.contains(.browse) {
      m.run { c in
        let visibleProducts = c[storefrontVisibleProductIDsCog]
        var checksum = 0
        for id in visibleProducts {
          let productRow = c[storefrontProductRowCogs[id]]
          checksum = StorefrontKernels.mix(checksum, id.raw)
          checksum = StorefrontKernels.mix(checksum, productRow.priceCents)
          checksum = StorefrontKernels.mix(checksum, productRow.availableUnits)
          checksum = StorefrontKernels.mix(checksum, productRow.badges.rawValue)
          checksum = StorefrontKernels.mix(checksum, productRow.cartQuantity)
        }
        // Reading the prefetch margin is what starts its rows' inventory and
        // offer requests. A list that demanded only what is on screen would
        // show a price arriving one frame after the row it belongs to.
        let prefetchProducts = c[storefrontPrefetchProductIDsCog]
        for id in prefetchProducts {
          _ = c[storefrontProductRowCogs[id]]
        }
        sink.recordBrowse(
          visible: visibleProducts,
          demanded: prefetchProducts,
          checksum: checksum
        )
      }
    }

    if holds.contains(.search) {
      m.run { c in
        let storefrontSuggestions = c[storefrontSuggestionsCog]
        sink.recordSearch(suggestions: storefrontSuggestions)
      }
    }

    if holds.contains(.cart) {
      m.run { c in
        let orderTotal = c[storefrontOrderTotalCog]
        let checkoutReadiness = c[storefrontCheckoutReadinessCog]
        sink.recordCart(total: orderTotal, readiness: checkoutReadiness)
      }
    }

    if holds.contains(.detail) {
      m.run { c in
        // Reading nothing else when no product is open is what lets the detail
        // payload and the recommendation shelf be *released* after the shopper
        // navigates away and their grace elapses.
        let selectedProduct = c[selectedProductCog]
        guard let selectedProduct else {
          sink.recordDetail(reviewCount: 0, recommendations: [])
          return
        }
        let storefrontDetail = c[storefrontDetailCogs[selectedProduct]]
        let storefrontRecommendations = c[storefrontRecommendationsCog]
        sink.recordDetail(
          reviewCount: storefrontDetail.reviewCount,
          recommendations: storefrontRecommendations
        )
      }
    }
  }
}
