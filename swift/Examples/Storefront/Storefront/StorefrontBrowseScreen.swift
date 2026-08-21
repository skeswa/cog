import Cog
import CogStorefront
import SwiftUI

/// The catalog list: a search field, a filter bar, and every ranked product
/// grouped into sections.
///
/// The list is the shape Apple's own list-performance guidance asks for — a
/// dynamic number of sections, each with a nested `ForEach`, and a **constant**
/// number of views per row. Every row is pinned to one height so the number of
/// rows on screen is a function of the device rather than of the content, which
/// is what makes a scrolling measurement reproducible.
struct StorefrontBrowseScreen: View {
  /// The singular graph inherited from ``StorefrontApp``.
  @Environment(\.cogs) private var cogs

  /// Which flat row indices the list has realized.
  ///
  /// A reference held in `@State` on purpose; see
  /// ``StorefrontRowWindowTracker`` for why two integers would turn every
  /// scroll into a rebuild of this screen.
  @State private var rowWindowTracker = StorefrontRowWindowTracker()

  /// Renders the filter bar above the sectioned catalog list.
  var body: some View {
    // Every value this screen shows, read flatly and bound to a domain local.
    // One settled turn produces all of them, and each registers on its own, so
    // an inventory burst that touches no visible product invalidates nothing
    // here.
    let storefrontSections = cogs[storefrontSectionsCog]
    let sectionRowOffsets = flatRowOffsets(of: storefrontSections)

    NavigationStack {
      VStack(spacing: 0) {
        StorefrontFilterBar()

        List {
          ForEach(Array(storefrontSections.enumerated()), id: \.element.id) { entry in
            Section(entry.element.title) {
              ForEach(Array(entry.element.productIDs.enumerated()), id: \.element) { row in
                StorefrontProductRowView(
                  productID: row.element,
                  flatIndex: sectionRowOffsets[entry.offset] + row.offset,
                  rowWindowTracker: rowWindowTracker
                )
              }
            }
          }
        }
        .listStyle(.plain)
        .accessibilityIdentifier(StorefrontAccessibility.browseList)
      }
      .navigationTitle("Storefront")
      .navigationBarTitleDisplayMode(.inline)
      .navigationDestination(for: ProductID.self) { productID in
        StorefrontProductDetailScreen(productID: productID)
      }
      .searchable(
        text: cogs.searchQueryBinding,
        placement: .navigationBarDrawer(displayMode: .always),
        prompt: "Search the catalog"
      )
    }
    .onChange(of: storefrontSections) { _, _ in
      // A flat row index means something different after a filter than it did
      // before one, so the ledger is emptied rather than carried across. The
      // rows SwiftUI realizes next refill it.
      if let window = rowWindowTracker.reset() {
        cogs.scrollRows(to: window)
      }
    }
  }

  /// The flat index of each section's first row.
  ///
  /// Sections are a presentation grouping; the graph's row window is a single
  /// flat range over the list, exactly as `storefrontVisibleProductIDsCog`
  /// flattens it. Computing the offsets once per section change keeps each row
  /// from having to know anything about the sections above it.
  ///
  /// - Parameter sections: The sections, in list order.
  /// - Returns: One starting flat index per section.
  private func flatRowOffsets(of sections: [StorefrontSection]) -> [Int] {
    var offsets: [Int] = []
    offsets.reserveCapacity(sections.count)
    var next = 0
    for section in sections {
      offsets.append(next)
      next += section.productIDs.count
    }
    return offsets
  }
}

/// The category chips, the sort menu, the stock switch, and the one control
/// that writes all three in a single turn.
private struct StorefrontFilterBar: View {
  /// The singular graph inherited from ``StorefrontApp``.
  @Environment(\.cogs) private var cogs

  /// Renders the filter controls.
  var body: some View {
    let storefrontCategories = cogs[storefrontCategoriesCog]
    let selectedCategory = cogs[selectedCategoryCog]
    let sortMode = cogs[sortModeCog]

    VStack(alignment: .leading, spacing: 8) {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 8) {
          Button("All") {
            cogs.selectCategory(nil)
          }
          .buttonStyle(.bordered)
          .tint(selectedCategory == nil ? .accentColor : .gray)
          .accessibilityIdentifier(StorefrontAccessibility.allCategoriesChip)

          ForEach(storefrontCategories) { category in
            Button(category.name) {
              cogs.selectCategory(category.id)
            }
            .buttonStyle(.bordered)
            .tint(selectedCategory == category.id ? .accentColor : .gray)
            .accessibilityIdentifier(StorefrontAccessibility.categoryChip(category.id))
          }
        }
        .padding(.horizontal, 12)
      }

      HStack(spacing: 12) {
        Menu {
          ForEach(SortMode.allCases, id: \.self) { mode in
            Button(mode.displayName) {
              cogs.selectSortMode(mode)
            }
          }
        } label: {
          Label(sortMode.displayName, systemImage: "arrow.up.arrow.down")
        }
        .accessibilityIdentifier(StorefrontAccessibility.sortMenu)

        Toggle("In stock", isOn: cogs.inStockOnlyBinding)
          .toggleStyle(.button)
          .accessibilityIdentifier(StorefrontAccessibility.inStockToggle)

        Spacer(minLength: 0)

        // One tap, three sources, one turn. A storefront that wrote the
        // category, the sort, and the stock switch as three commits would
        // settle — and render — two screens no shopper ever asked for on the
        // way to the one they did.
        Button("Deals") {
          cogs.applyBrowseFilters(
            category: storefrontCategories.first?.id,
            sortMode: .priceAscending,
            inStockOnly: true
          )
        }
        .accessibilityIdentifier(StorefrontAccessibility.applyFilters)
      }
      .font(.footnote)
      .padding(.horizontal, 12)
      .padding(.bottom, 6)

      Divider()
    }
    .background(.bar)
  }
}
