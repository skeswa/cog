import Cog
import SwiftUI

@main
struct WeatherApp: App {
  @State private var cogs: Cogtext

  init() {
    let cogs = Cogtext.bootstrapApp()
    _cogs = State(initialValue: cogs)
  }

  var body: some Scene {
    WindowGroup {
      Text("Weather")
        .environment(\.cogs, cogs)
    }
  }
}
