import Cog
import SwiftUI

@main
struct WeatherApp: App {
  @State private var cogs: Cogs

  init() {
    let cogs = Cogs.bootstrapApp()
    cogs.selectCurrentLocation(.newYork)
    _cogs = State(initialValue: cogs)
    WeatherEffects(
      notifier: .live,
      hourlyRefreshInterval: .seconds(5)
    ).install(in: cogs)
  }

  var body: some Scene {
    WindowGroup {
      WeatherDashboard()
        .cogEnvironment(cogs)
    }
  }
}
