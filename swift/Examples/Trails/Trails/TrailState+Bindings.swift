import Cog
import SwiftUI

// SwiftUI adapters for the domain state, kept separate from graph
// declarations and operations. Each binding pairs a tracked getter with a
// named domain operation; the navigation containers' bindings live in
// `NavigationState+Bindings.swift`.

extension Cogs {
  /// Tracked binding for the Search tab's text field.
  var searchQueryBinding: Binding<String> {
    Binding(
      get: {
        let searchQuery = self[searchQueryCog]
        return searchQuery
      },
      set: { self.setSearchQuery($0) }
    )
  }
}
