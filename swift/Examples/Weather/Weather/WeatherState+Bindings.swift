import Cog
import SwiftUI

extension Cogs {
  /// A tracked SwiftUI binding to the singular current-location source.
  ///
  /// The getter is a UI-boundary read, so this stays on the runtime rather
  /// than the shared op surface.
  var currentZipBinding: Binding<ZipCode?> {
    Binding(
      get: {
        let currentZipCode = self[currentZipCodeCog]
        return currentZipCode
      },
      set: { self.selectCurrentLocation($0) }
    )
  }
}
