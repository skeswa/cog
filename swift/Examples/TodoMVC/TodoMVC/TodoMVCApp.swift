import Cog
import SwiftUI

/// Launches TodoMVC with one process-lifetime Cog graph.
///
/// The persistence mechanism installs the starting snapshot during assembly,
/// before any view can observe the resting defaults. Every screen then resolves
/// this same runtime through the SwiftUI environment.
@main
struct TodoMVCApp: App {
  /// The singular graph retained for the lifetime of the application scene.
  @State private var cogs: Cogs

  /// Assembles state and persistence as one application runtime.
  init() {
    let cogs = Cogs.assemble(mechanisms: [TodoMechanism(store: .live)])
    _cogs = State(initialValue: cogs)
  }

  /// Installs the graph above the complete TodoMVC interface.
  var body: some Scene {
    WindowGroup {
      TodoDashboard()
        .cogEnvironment(cogs)
    }
  }
}
