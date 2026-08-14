import Cog
import CogTesting
import SwiftUI
import Testing

/// Captures the context a body actually resolved, so the test can compare it
/// by identity with the installed one instead of trusting that any render
/// implies the right environment value arrived.
@MainActor
private final class ResolvedContextBox {
  var resolved: Cogs?

  func record(_ cogs: Cogs) {
    resolved = cogs
  }
}

@MainActor
private struct ContextProbe: View {
  @Environment(\.cogs) private var cogs

  let box: ResolvedContextBox

  var body: some View {
    let _ = box.record(cogs)
    Text(String(describing: cogs))
  }
}

@MainActor
@Test func `UI-06 a view resolves the context installed through the cogs environment key`() {
  let cogs = Cogs.forTesting()
  let box = ResolvedContextBox()
  let renderer = ImageRenderer(content: ContextProbe(box: box).cogEnvironment(cogs))

  // Rendering exercises the real DynamicProperty update. Merely constructing
  // the view would not prove the environment arrives before @Environment reads.
  #expect(renderer.cgImage != nil)

  // The body read the installed context itself — not a default or fallback
  // context that would also have rendered successfully.
  #expect(box.resolved === cogs)
}
