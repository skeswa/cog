import Cog
import SwiftUI

@main
struct WeatherApp: App {
  @State private var cogs: Cogtext
  @State private var effects: EffectGroup

  init() {
    let cogs = Cogtext.bootstrapApp()
    cogs.useCurrentLocation(.newYork)
    _cogs = State(initialValue: cogs)
    _effects = State(
      initialValue: WeatherEffects(
        notifier: .live,
        hourlyRefreshInterval: .seconds(5)
      ).install(in: cogs)
    )
  }

  var body: some Scene {
    WindowGroup {
      WeatherDashboard()
        .cogEnvironment(cogs)
    }
  }
}
