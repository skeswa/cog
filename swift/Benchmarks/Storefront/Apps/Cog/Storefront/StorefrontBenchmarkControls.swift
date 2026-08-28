import Cog
import CogStorefront
import StorefrontWorkload
import SwiftUI

/// The overlay a measured run drives, and an ordinary launch never sees.
///
/// Its two test-only buttons publish a fixed inventory burst and reset the
/// session's filters and window.
///
/// **Why a launch argument rather than `#if DEBUG`.** The measured
/// configuration is Release, so `#if DEBUG` would remove the controls. A custom
/// build would make launch tests measure a different image. A launch argument
/// keeps one Release binary and shows the controls at startup. The UI-test
/// bundle cannot share a compile-time symbol because it links neither this
/// target nor `CogStorefront`.
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
        // Use `peek` so scrolling does not re-render the overlay inside the
        // measured region.
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
