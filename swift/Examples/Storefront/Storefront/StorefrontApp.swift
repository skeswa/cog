import Cog
import CogStorefront
import SwiftUI

/// The Storefront benchmark application's entry point.
///
/// This target contributes only an entry point, views, and the small amount of
/// platform-ephemeral state SwiftUI needs. Every declaration, every domain op,
/// and the one mechanism live in the separate `CogStorefront` package, which
/// the headless benchmark cuts in `swift/Benchmarks` drive through the same
/// verbs. That sharing is the point: a UI result and a headless result that
/// disagreed would otherwise both be defensible, because they would be
/// measuring two similar-looking workloads rather than one.
@main
struct StorefrontApp: App {
  /// The one app-wide graph, retained for the process lifetime.
  @State private var cogs: Cogs

  /// Bootstraps the graph with the workload's mechanism.
  ///
  /// The mechanism, not this initializer, installs initial state: `operate`
  /// runs inside `bootstrapApp`, so the request boundary and the starting row
  /// window settle before the first `body` observes anything. Nothing else
  /// happens here, and the local exists only to be retained.
  ///
  /// The mechanism holds exactly `.account`, and no other lease. A SwiftUI
  /// application's views *are* its observation — the browse list, the cart
  /// screen, and the detail screen each demand what they render, and release
  /// it when they disappear. Registering a browse or cart reaction beside them
  /// would pin state no screen is looking at and quietly turn every scroll
  /// measurement into a measurement of a benchmark artifact. The account
  /// reaction is the exception because nothing renders it: it accepts the
  /// account response into the signed-in-shopper source, which pricing,
  /// offers, and recommendations all read.
  init() {
    let launchOptions = StorefrontLaunchOptions.current
    let cogs = Cogs.bootstrapApp(mechanisms: [
      StorefrontMechanism(
        service: StorefrontService(profile: launchOptions.profile, mode: .immediate),
        initialWindow: RowWindow(offset: 0, length: launchOptions.profile.viewportRowCount),
        holds: [.account],
        sink: StorefrontSink()
      )
    ])
    _cogs = State(initialValue: cogs)
  }

  /// The two-tab shopping interface, over the one runtime.
  var body: some Scene {
    WindowGroup {
      StorefrontRootView()
        .cogEnvironment(cogs)
    }
  }
}

/// The application's tab shell.
///
/// A separate view rather than the scene's body so the benchmark overlay can
/// resolve `Cogs` from the environment the scene installed; a view that reads
/// the graph must inherit it, never receive it.
struct StorefrontRootView: View {
  /// Which tab is showing.
  ///
  /// Platform-ephemeral selection state. It is not a fact about the shop, no
  /// screen outside this one needs it, and putting it in the graph would make
  /// changing tabs a graph turn for no reader's benefit.
  @State private var tab = StorefrontTab.browse

  /// Renders the two tabs, with the benchmark overlay above them when this
  /// launch asked for it.
  var body: some View {
    TabView(selection: $tab) {
      StorefrontBrowseScreen()
        .tabItem { Label("Browse", systemImage: "square.grid.2x2") }
        .tag(StorefrontTab.browse)

      StorefrontCartScreen()
        .tabItem { Label("Cart", systemImage: "cart") }
        .tag(StorefrontTab.cart)
    }
    .overlay(alignment: .bottom) {
      // Constant view count either way: an empty overlay still resolves to one
      // child, so revealing the controls never changes the shape of this tree.
      if StorefrontLaunchOptions.current.showsBenchmarkControls {
        StorefrontBenchmarkControls()
      } else {
        EmptyView()
      }
    }
  }
}

/// The application's two tabs.
enum StorefrontTab: Hashable {
  /// The searchable catalog list.
  case browse

  /// The cart and checkout summary.
  case cart
}
