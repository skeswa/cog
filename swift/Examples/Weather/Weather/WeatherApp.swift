import Cog
import SwiftUI

@main
struct WeatherApp: App {
  @State private var cogs: Cogs

  init() {
    let cogs = Cogs.bootstrapApp(mechanisms: [
      WeatherMechanism(
        notifier: .live,
        hourlyRefreshInterval: .seconds(5)
      )
    ])
    cogs.selectCurrentLocation(.newYork)
    _cogs = State(initialValue: cogs)
  }

  var body: some Scene {
    WindowGroup {
      WeatherDashboard()
        .cogEnvironment(cogs)
    }
  }
}
