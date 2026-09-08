import Cog
import CogTesting
import Testing

// Both `scope` families accept every reference shape a mechanism can hold, and
// keyed selections stay independent of one another.

/// A keyed workflow lifetime, distinct per opening.
private struct Workflow: Equatable {
  let id: String
}

@MainActor private let _gateCog = Cog<Bool>.Manual { false }
@MainActor private let gateCog = _gateCog.readOnly
@MainActor private let _identityCog = Cog<Workflow?>.Manual { nil }
@MainActor private let identityCog = _identityCog.readOnly

@MainActor
@Test func `MECH-21 every reference shape registers through both scope families`() {
  let manualGate = Cog<Bool>.Manual { false }
  let derivedGate = Cog<Bool> { c in c[manualGate] }
  let manualIdentity = Cog<Workflow?>.Manual { nil }
  let derivedIdentity = Cog<Workflow?> { c in c[manualIdentity] }

  var openings: [String] = []

  let cogs = Cogs.forTesting(mechanisms: [
    MechanismProbe { m in
      // The Bool family: automatic, manual, and read-only projection. Each body
      // receives only its sub-controller, with no caller-invented identity.
      m.scope(derivedGate, name: "derivedGate") { _ in openings.append("derivedGate") }
      m.scope(manualGate, name: "manualGate") { _ in openings.append("manualGate") }
      m.scope(gateCog, name: "projectedGate") { _ in openings.append("projectedGate") }

      // The identity family: the same three shapes, each body receiving the
      // exact nonoptional identity that opened it.
      m.scope(derivedIdentity, name: "derivedIdentity") { workflow, _ in
        openings.append("derivedIdentity:\(workflow.id)")
      }
      m.scope(manualIdentity, name: "manualIdentity") { workflow, _ in
        openings.append("manualIdentity:\(workflow.id)")
      }
      m.scope(identityCog, name: "projectedIdentity") { workflow, _ in
        openings.append("projectedIdentity:\(workflow.id)")
      }
    }
  ])
  #expect(openings.isEmpty)

  cogs.turn("open the gates") { c in
    c[manualGate] = true
    c[_gateCog] = true
  }
  #expect(openings == ["derivedGate", "manualGate", "projectedGate"])

  openings.removeAll()
  cogs.turn("open the identities") { c in
    c[manualIdentity] = Workflow(id: "a")
    c[_identityCog] = Workflow(id: "b")
  }
  #expect(
    openings == [
      "derivedIdentity:a", "manualIdentity:a", "projectedIdentity:b",
    ]
  )
}

@MainActor
@Test func `MECH-21 keyed selections own independent lifetimes`() {
  let sessions = CogBox<Workflow?, String>.Manual { nil }
  var openings: [String] = []

  let cogs = Cogs.forTesting(mechanisms: [
    MechanismProbe { m in
      for slot in ["left", "right"] {
        m.scope(sessions[slot], name: slot) { workflow, s in
          openings.append("\(slot):\(workflow.id)")
          s.run { _ in }
        }
      }
    }
  ])

  cogs.turn(sessions["left"], to: Workflow(id: "one"))
  #expect(openings == ["left:one"])

  // The other key is untouched by the first key's opening.
  cogs.turn(sessions["right"], to: Workflow(id: "two"))
  #expect(openings == ["left:one", "right:two"])

  // Replacing one key's identity does not restart the other.
  cogs.turn(sessions["left"], to: Workflow(id: "three"))
  #expect(openings == ["left:one", "right:two", "left:three"])

  // Closing one key leaves the other's lifetime alone.
  cogs.turn(sessions["right"], to: nil)
  cogs.turn(sessions["left"], to: Workflow(id: "four"))
  #expect(openings == ["left:one", "right:two", "left:three", "left:four"])
}

@MainActor
@Test func `MECH-21 a source that republishes an equal identity does not reopen`() {
  // This source compares unequal to itself for the graph's purposes: it has no
  // `Equatable` conformance Cog can use to gate the write, so every turn
  // publishes and every watch runs. The scope must still refuse to restart an
  // unchanged lifetime, which is why equality is checked at the scope layer as
  // well as by the graph.
  struct LoudWorkflow {
    let id: String
  }
  let loud = Cog<LoudWorkflow?>.Manual { LoudWorkflow(id: "a") }
  let selected = Cog<Workflow?> { c in c[loud].map { Workflow(id: $0.id) } }
  var openings: [String] = []

  let cogs = Cogs.forTesting(mechanisms: [
    MechanismProbe { m in
      m.scope(selected, name: "workflow") { workflow, _ in
        openings.append(workflow.id)
      }
    }
  ])
  #expect(openings == ["a"])

  // The source republishes an equal identity three times.
  cogs.turn(loud, to: LoudWorkflow(id: "a"))
  cogs.turn(loud, to: LoudWorkflow(id: "a"))
  cogs.turn(loud, to: LoudWorkflow(id: "a"))
  #expect(openings == ["a"])

  // A genuinely different identity still replaces the lifetime.
  cogs.turn(loud, to: LoudWorkflow(id: "b"))
  #expect(openings == ["a", "b"])
}
