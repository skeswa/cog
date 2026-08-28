import Cog
import CogTesting
import SwiftUI
import Testing

/// Captures the context resolved by a view body. The test compares its identity
/// with the installed context instead of treating any render as proof.
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

/// Proves an intermediate view need not receive or forward the app context.
@MainActor
private struct ContextProbeHost: View {
  /// The identity recorder passed as ordinary view data.
  let box: ResolvedContextBox

  /// Builds the consuming descendant without resolving `Cogs` itself.
  var body: some View {
    ContextProbe(box: box)
  }
}

@MainActor
@Test func `UI-06 each consuming view resolves cogs without an intermediate forwarding it`() {
  let cogs = Cogs.forTesting()
  let box = ResolvedContextBox()
  let renderer = ImageRenderer(content: ContextProbeHost(box: box).cogEnvironment(cogs))

  // Rendering exercises the real DynamicProperty update. Merely constructing
  // the view would not prove the environment arrives before @Environment reads.
  #expect(renderer.cgImage != nil)

  // The descendant body read the installed context, not a default, fallback,
  // or value forwarded by its parent.
  #expect(box.resolved === cogs)
}
