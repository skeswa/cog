import Cog
import CogTesting
import Testing

// A selector reads state from another file through its published read-only
// projection.

@MainActor
@Test func `DECL-05 a selector reads a source through its read-only projection`() {
  let cogs = Cogtext.forTesting()

  let source = ManualCog(7, name: "source")
  let exposed = source.readOnly
  let doubled = Cog { c in c.get(exposed) * 2 }

  #expect(cogs.read(doubled) == 14)
  #expect(cogs.read(exposed) == cogs.read(source))
}

@MainActor
@Test func `DECL-05 a read-only projection reads the same as its source in a selector`() {
  let cogs = Cogtext.forTesting()

  let source = ManualCog("hello", name: "greeting")
  let viaProjection = Cog { c in c.get(source.readOnly) }
  let viaSource = Cog { c in c.get(source) }

  #expect(cogs.read(viaProjection) == cogs.read(viaSource))
}

@MainActor
@Test func `DECL-05 a selector reads one key of a read-only box`() {
  let cogs = Cogtext.forTesting()

  let box = ManualCogBox<Int, String>(0, name: "counts")
  let exposed = box.readOnly
  let forA = Cog { c in c.get(exposed["a"]) }

  #expect(cogs.read(forA) == 0)
  #expect(cogs.read(exposed["a"]) == cogs.read(box["a"]))
}
