import Cog
import CogTesting
import SwiftUI
import Testing

@MainActor
private struct ContextProbe: View {
  @Environment(\.cogs) private var cogs

  var body: some View {
    Text(String(describing: cogs))
  }
}

@MainActor
@Test func `UI-06 a view resolves the context installed through the cogs environment key`() {
  let cogs = Cogtext.forTesting()
  var environment = EnvironmentValues()

  environment.cogs = cogs

  #expect(environment.cogs === cogs)

  // The exact production composition spelling and @Environment lookup both
  // type-check through the public API.
  _ = ContextProbe().environment(\.cogs, cogs)
}
