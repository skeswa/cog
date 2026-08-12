import Cog

/// A scene-level composition owner before M2 adds the actual SwiftUI boundary.
///
/// It owns only the app context it was given. The selected ZIP remains in the
/// weather feature's file-private manual source, so rebuilding this transient
/// owner cannot preserve state by copying or mirroring it locally.
@MainActor
final class ONE06SceneFixture {
  let cogs: Cogtext

  init(cogs: Cogtext) {
    self.cogs = cogs
  }

  func selectZip(_ zip: String?) {
    cogs.selectZip(zip)
  }

  var selectedZip: String? {
    SettingsFeature.selectedWeatherZip(in: cogs)
  }
}
