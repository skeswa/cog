import Cog
import CogTesting
import Testing

// The type itself is explicitly nonisolated and has no Sendable conformance.
// Construction and state access are MainActor-bound instead. Declaring the
// whole class @MainActor would make it implicitly Sendable and weaken ACTOR-03.
private nonisolated final class Actor03MainActorValue {
  @MainActor private(set) var number: Int

  @MainActor
  init(_ number: Int) {
    self.number = number
  }
}

private nonisolated func actor03IsSendable<T>(_: T.Type) -> Bool { false }
private nonisolated func actor03IsSendable<T: Sendable>(_: T.Type) -> Bool { true }

@MainActor
@Test func `ACTOR-03 manual and automatic cogs hold a MainActor-bound non-Sendable value directly`()
{
  #expect(actor03IsSendable(Int.self))
  #expect(actor03IsSendable(Actor03MainActorValue.self) == false)

  let cogs = Cogs.forTesting()
  let value = Actor03MainActorValue(21)
  let source = ManualCog<Actor03MainActorValue>(value)
  let doubled = Cog<Int> { c in c[source].number * 2 }

  #expect(cogs.peek(source) === value)
  #expect(cogs.peek(doubled) == 42)
}
