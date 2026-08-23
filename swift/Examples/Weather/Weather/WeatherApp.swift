import Cog
import SwiftUI

@main
struct WeatherApp: App {
  @State private var cogs: Cogs

  init() {
    let cogs = Cogs.assemble(mechanisms: [
      WeatherMechanism(
        notifier: .live,
        hourlyRefreshInterval: .seconds(5)
      )
    ])
    _cogs = State(initialValue: cogs)
  }

  var body: some Scene {
    WindowGroup {
      WeatherDashboard()
        .cogEnvironment(cogs)
    }
  }
}
