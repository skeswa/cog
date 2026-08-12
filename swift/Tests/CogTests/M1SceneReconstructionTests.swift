import Cog
import CogTesting
import Testing

@MainActor
@Test func `ONE-06 rebuilding a scene preserves manual state in the app context`() {
  Cogtext.withBootstrappedApp { app in
    weak var discardedScene: M1WeatherSceneFixture?

    do {
      let firstScene = M1WeatherSceneFixture(cogs: app)
      discardedScene = firstScene

      #expect(firstScene.cogs === app)
      #expect(firstScene.selectedZip == nil)

      firstScene.selectZip("10001")
      #expect(firstScene.selectedZip == "10001")
    }

    // The transient owner is really gone before its replacement is built.
    #expect(discardedScene == nil)
    #expect(Cogtext.isBootstrappedApp(app))

    let rebuiltScene = M1WeatherSceneFixture(cogs: app)
    #expect(rebuiltScene.cogs === app)
    #expect(rebuiltScene.selectedZip == "10001")

    // Independent graph changes flow back into the rebuilt owner, proving it
    // did not preserve the value in a scene-local mirror.
    app.selectZip("90210")
    #expect(rebuiltScene.selectedZip == "90210")

    // The same live boundary works in the other direction too.
    rebuiltScene.selectZip("30301")
    #expect(SettingsFeature.selectedWeatherZip(in: app) == "30301")
  }
}
