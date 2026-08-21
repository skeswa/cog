import CogTesting
import Testing

@testable import Cog

@MainActor
@Test func `ReactionReaderInfrastructure peek settles without adding a dependency`() {
  let cogs = Cogs.forTesting()
  let trigger = ManualCog<Int>(0)
  let source = ManualCog<Int>(1)
  let projectedSource = source.readOnly
  let doubled = Cog<Int> { c in c[source] * 2 }
  var seen: [(Int, Int)] = []

  let token = cogs.runForTesting { c in
    _ = c[trigger]
    seen.append((c.peek(projectedSource), c.peek(doubled)))
  }
  defer { token.cancel() }

  #expect(seen.map { $0.0 } == [1])
  #expect(seen.map { $0.1 } == [2])

  cogs.turn { c in c[source] = 3 }
  #expect(seen.count == 1)

  cogs.turn { c in c[trigger] = 1 }
  #expect(seen.map { $0.0 } == [1, 3])
  #expect(seen.map { $0.1 } == [2, 6])
}

extension Cogs {
  /// Registers a bare reaction through the internal door.
  ///
  /// Infrastructure tests exercise registration machinery directly; the
  /// public registration surface lives on `MechanismController`.
  fileprivate func runForTesting(
    _ body: @escaping @MainActor (ReactionReader) -> Void
  ) -> ReactionToken {
    register(label: CogLabel(name: nil, fileID: #fileID, line: #line), body: body)
  }
}
