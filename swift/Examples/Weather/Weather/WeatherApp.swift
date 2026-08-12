import Cog
import SwiftUI

@main
struct WeatherApp: App {
  @State private var cogs: Cogtext
  @State private var effects: EffectGroup

  init() {
    let cogs = Cogtext.bootstrapApp()
    _cogs = State(initialValue: cogs)
    _effects = State(initialValue: WeatherEffects(notifier: .live).install(in: cogs))
  }

  var body: some Scene {
    WindowGroup {
      WeatherDashboard()
        .environment(\.cogs, cogs)
    }
  }
}
