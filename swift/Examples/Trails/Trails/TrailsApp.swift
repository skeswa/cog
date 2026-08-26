import Cog
import SwiftUI

/// Launches Trails with one process-lifetime Cog graph.
///
/// Assembly order matters: persistence installs the restored navigation and
/// domain document first, so the journal mechanism's initial run records the
/// restored screen and the timer scope sees any re-presented logger sheet.
/// Every view then resolves this same runtime through the environment.
@main
struct TrailsApp: App {
  /// The singular graph retained for the lifetime of the application scene.
  @State private var cogs: Cogs

  /// Assembles state, persistence, the journal, and the gated timer.
  init() {
    let cogs = Cogs.assemble(mechanisms: [
      TrailPersistenceMechanism(store: .live),
      TrailJournalMechanism(),
      HikeTimerMechanism(),
    ])
    _cogs = State(initialValue: cogs)
  }

  /// Installs the graph above the complete tabbed interface.
  var body: some Scene {
    WindowGroup {
      TrailsRoot()
        .cogEnvironment(cogs)
    }
  }
}
