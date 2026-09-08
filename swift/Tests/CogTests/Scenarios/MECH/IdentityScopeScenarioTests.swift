import Cog
import CogTesting
import Testing

// The single-identity `scope` family. Every proof here drives the lifecycle
// through settled graph values only: no test inspects a scope, and none waits
// on anything but a value it wrote itself.

/// One presentation lifetime, minted where the domain creates it.
private struct Presentation: Equatable {
  let id: Int
}

@MainActor
@Test func `MECH-17 an identity opens, preserves, replaces, and closes its scope`() {
  let session = Cog<Presentation?>.Manual { Presentation(id: 1) }
  let uploads = Cog<Int>.Manual { 0 }
  var opened: [Int] = []
  var seen: [String] = []

  let cogs = Cogs.forTesting(mechanisms: [
    MechanismProbe { m in
      m.scope(session, name: "session") { presentation, s in
        opened.append(presentation.id)
        s.run { c in seen.append("\(presentation.id):\(c[uploads])") }
      }
    }
  ])

  // An identity already present at `operate` opens once, and its registrations
  // are live when assembly returns.
  #expect(opened == [1])
  #expect(seen == ["1:0"])

  // A distinct but equal identity is the same lifetime: no restart, no second
  // registration, and the existing reaction keeps working.
  cogs.turn(session, to: Presentation(id: 1))
  #expect(opened == [1])
  cogs.turn(uploads, to: 1)
  #expect(seen == ["1:0", "1:1"])

  // A → B replaces the lifetime: the old child's reaction is gone and exactly
  // one new registration exists.
  cogs.turn(session, to: Presentation(id: 2))
  #expect(opened == [1, 2])
  #expect(seen == ["1:0", "1:1", "2:1"])
  cogs.turn(uploads, to: 2)
  #expect(seen == ["1:0", "1:1", "2:1", "2:2"])

  // A → nil retires the child and opens nothing.
  cogs.turn(session, to: nil)
  #expect(opened == [1, 2])
  cogs.turn(uploads, to: 3)
  #expect(seen == ["1:0", "1:1", "2:1", "2:2"])
}

@MainActor
@Test func `MECH-17 a scope that starts nil installs its selector and opens later`() {
  let session = Cog<Presentation?>.Manual { nil }
  let uploads = Cog<Int>.Manual { 0 }
  var opened: [Int] = []
  var seen: [Int] = []

  let cogs = Cogs.forTesting(mechanisms: [
    MechanismProbe { m in
      m.scope(session, name: "session") { presentation, s in
        opened.append(presentation.id)
        s.run { c in seen.append(c[uploads]) }
      }
    }
  ])

  // nil → nil stays absent: the selector is installed but no child exists.
  #expect(opened.isEmpty)
  cogs.turn(session, to: nil)
  #expect(opened.isEmpty)

  // nil → A creates a fresh child and runs the body once.
  cogs.turn(session, to: Presentation(id: 7))
  #expect(opened == [7])
  #expect(seen == [0])
}

@MainActor
@Test func `MECH-18 returning to an earlier identity opens a fresh instance`() {
  let session = Cog<Presentation?>.Manual { Presentation(id: 1) }
  let uploads = Cog<Int>.Manual { 0 }
  var openings = 0
  var seen: [String] = []

  let cogs = Cogs.forTesting(mechanisms: [
    MechanismProbe { m in
      m.scope(session, name: "session") { presentation, s in
        openings += 1
        let instance = openings
        s.run { c in seen.append("\(presentation.id)#\(instance):\(c[uploads])") }
      }
    }
  ])
  #expect(seen == ["1#1:0"])

  // A → nil → A in separate completed turns. The second `1` is a different
  // lifetime instance; nothing from the first comes back.
  cogs.turn(session, to: nil)
  cogs.turn(session, to: Presentation(id: 1))
  #expect(openings == 2)
  cogs.turn(uploads, to: 1)
  #expect(seen == ["1#1:0", "1#2:0", "1#2:1"])

  // A → B → A likewise. Three successive lifetimes exist by the end and none of
  // the earlier ones was revived: only the newest instance reacts.
  cogs.turn(session, to: Presentation(id: 2))
  cogs.turn(session, to: Presentation(id: 1))
  #expect(openings == 4)
  cogs.turn(uploads, to: 2)
  #expect(
    seen == [
      "1#1:0", "1#2:0", "1#2:1", "2#3:1", "1#4:1", "1#4:2",
    ]
  )
}

@MainActor
@Test func `MECH-19 identities staged inside one turn are not transitions`() {
  let session = Cog<Presentation?>.Manual { Presentation(id: 1) }
  var openings: [Int] = []

  let cogs = Cogs.forTesting(mechanisms: [
    MechanismProbe { m in
      m.scope(session, name: "session") { presentation, _ in
        openings.append(presentation.id)
      }
    }
  ])
  #expect(openings == [1])

  // One atomic turn stages nil and another identity but settles back on 1.
  // Only the settled value is observable, so nothing happened at all.
  cogs.turn("churn the session without changing it") { c in
    c[session] = nil
    c[session] = Presentation(id: 2)
    c[session] = Presentation(id: 1)
  }
  #expect(openings == [1])

  // A turn that stages several identities and settles on a new one transitions
  // exactly once, from the previously observed identity to the settled one.
  cogs.turn("replace the session once") { c in
    c[session] = nil
    c[session] = Presentation(id: 5)
    c[session] = Presentation(id: 9)
  }
  #expect(openings == [1, 9])
}

@MainActor
@Test func `MECH-20 only the selected identity is the scope's lifetime dependency`() {
  let sessionID = Cog<Int?>.Manual { 1 }
  let useAlternate = Cog<Bool>.Manual { false }
  let alternateID = Cog<Int?>.Manual { 1 }
  let unrelated = Cog<Int>.Manual { 0 }

  // The selector's own dependency set changes with `useAlternate`, while the
  // identity it returns can stay the same.
  let selectedSession = Cog<Int?> { c in
    c[useAlternate] ? c[alternateID] : c[sessionID]
  }

  var openings = 0
  var peeked: [Int] = []

  let cogs = Cogs.forTesting(mechanisms: [
    MechanismProbe { m in
      m.scope(selectedSession, name: "session") { _, s in
        openings += 1
        // A direct read in the registration body is one-shot: it never becomes
        // a lifetime dependency.
        peeked.append(s.peek(unrelated))
      }
    }
  ])
  #expect(openings == 1)
  #expect(peeked == [0])

  // Changing what the body peeked does not restart the scope.
  cogs.turn(unrelated, to: 1)
  #expect(openings == 1)

  // The selector swaps its upstream dependency but returns the same identity.
  // The lifetime is unchanged, so the child is preserved.
  cogs.turn(useAlternate, to: true)
  #expect(openings == 1)

  // The old dependency no longer selects anything.
  cogs.turn(sessionID, to: 42)
  #expect(openings == 1)

  // The new dependency does, and its change is observed.
  cogs.turn(alternateID, to: 42)
  #expect(openings == 2)
}
