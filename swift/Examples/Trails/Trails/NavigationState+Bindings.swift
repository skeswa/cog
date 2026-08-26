import Cog
import SwiftUI

// SwiftUI adapters for the navigation containers, kept separate from graph
// declarations and operations. Each binding pairs a tracked getter with a
// named domain operation, so system-driven mutations — tab taps, back
// gestures, interactive sheet dismissal, NavigationLink pushes — enter the
// graph as ordinary turns.

extension Cogs {
  /// Tracked binding for the tab bar's selection.
  ///
  /// The setter routes through `selectTab`, so re-tapping the selected tab
  /// pops that tab to its root.
  var selectedTabBinding: Binding<TrailTab> {
    Binding(
      get: {
        let selectedTab = self[selectedTabCog]
        return selectedTab
      },
      set: { self.selectTab($0) }
    )
  }

  /// Tracked binding for one tab's `NavigationStack` path.
  ///
  /// The system writes the truncated stack through this setter on every back
  /// navigation, which keeps the graph the single source of truth for what
  /// is pushed. Equal writes are discarded by the turn itself.
  ///
  /// - Parameter tab: The tab whose stack the `NavigationStack` drives.
  func tabPathBinding(for tab: TrailTab) -> Binding<[TrailRoute]> {
    Binding(
      get: {
        let tabPath = self[tabPathCogs[tab]]
        return tabPath
      },
      set: { self.setPath($0, in: tab) }
    )
  }

  /// Tracked binding for the presented sheet.
  ///
  /// Interactive dismissal writes `nil` through the setter; presentation in
  /// app code goes through `present` directly.
  var presentedSheetBinding: Binding<TrailSheet?> {
    Binding(
      get: {
        let presentedSheet = self[presentedSheetCog]
        return presentedSheet
      },
      set: { sheet in
        if let sheet {
          self.present(sheet)
        } else {
          self.dismissSheet()
        }
      }
    )
  }
}
