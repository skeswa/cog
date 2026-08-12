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
  let renderer = ImageRenderer(content: ContextProbe().cogEnvironment(cogs))

  // Rendering exercises the real DynamicProperty update. Merely constructing
  // the view would not prove the environment arrives before @Environment reads.
  #expect(renderer.cgImage != nil)
}
