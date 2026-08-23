import Cog
import CogTesting
import Testing

// A selector reads state from another file through its published read-only
// projection.

@MainActor
@Test func `DECL-05 a selector reads a source through its read-only projection`() {
  let cogs = Cogs.forTesting()

  let source = Cog.Manual(7, name: "source")
  let exposed = source.readOnly
  let doubled = Cog { c in c[exposed] * 2 }

  #expect(cogs.peek(doubled) == 14)
  #expect(cogs.peek(exposed) == cogs.peek(source))
}

@MainActor
@Test func `DECL-05 a selector reads one key of a read-only box`() {
  let cogs = Cogs.forTesting()

  let box = CogBox<Int, String>.Manual(0, name: "counts")
  let exposed = box.readOnly
  let forA = Cog { c in c[exposed["a"]] }

  #expect(cogs.peek(forA) == 0)
  #expect(cogs.peek(exposed["a"]) == cogs.peek(box["a"]))
}
