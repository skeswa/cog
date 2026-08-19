import Cog
import CogStorefront
import SwiftUI

/// The overlay a measured run drives, and an ordinary launch never sees.
///
/// Two buttons, both of them things a shopper must not be able to do and a UI
/// test must be able to do exactly: publish a deterministic inventory burst
/// over the products currently on screen, and put the session back to its
/// starting filters and window.
///
/// **Why a launch argument rather than `#if DEBUG`.** The measured
/// configuration is Release, so a `DEBUG`-gated overlay would not exist in the
/// binary the performance suite runs — the suite would have to measure a debug
/// build, and a debug timing describes `-Onone` and nothing else. A separate
/// `BENCHMARK` configuration would work, but then the launch metric would be
/// measuring an image that is not the one an ordinary launch produces, which is
/// the one property `XCTApplicationLaunchMetric` exists to report. A launch
/// argument keeps a single Release image and decides at startup whether these
/// controls are part of the interface, so the app under measurement is
/// byte-for-byte the app that ships. `XCUIApplication.launchArguments` is also
/// the only channel available: the UI-test bundle links neither this target nor
/// `CogStorefront`, so a compile-time symbol would be invisible to it.
struct StorefrontBenchmarkControls: View {
  /// The singular graph inherited from ``StorefrontApp``.
  @Environment(\.cogs) private var cogs

  /// Which inventory generation the next burst publishes.
  ///
  /// Ephemeral run bookkeeping. Generations must advance, and only this overlay
  /// hands them out, so nothing else has any business reading the counter.
  @State private var burstGeneration = 0

  /// Renders the two controls.
  var body: some View {
    HStack(spacing: 12) {
      Button("Burst") {
        // `peek` rather than a tracked read, deliberately. A body that read the
        // visible products would re-render this overlay on every scroll tick —
        // inside the measured region of the very tests it exists to serve.
        let storefrontVisibleProductIDs = cogs.peek(storefrontVisibleProductIDsCog)
        burstGeneration += 1
        cogs.publishInventoryBurst(storefrontVisibleProductIDs, generation: burstGeneration)
      }
      .accessibilityIdentifier(StorefrontAccessibility.benchmarkBurst)

      Button("Reset") {
        let rowWindow = cogs.peek(rowWindowCog)
        cogs.typeSearchQuery("")
        cogs.applyBrowseFilters(category: nil, sortMode: .relevance, inStockOnly: false)
        cogs.scrollRows(to: RowWindow(offset: 0, length: rowWindow.length))
      }
      .accessibilityIdentifier(StorefrontAccessibility.benchmarkReset)
    }
    .font(.footnote.weight(.semibold))
    .buttonStyle(.borderedProminent)
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .background(.thinMaterial, in: Capsule())
    .padding(.bottom, 56)
  }
}
