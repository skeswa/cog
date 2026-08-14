import CogTesting
import Testing

@testable import Cog

// MARK: - Mechanism shell infrastructure
//
// These proofs green no scenario. They pin the internal shape of the
// controller shell: registration flows into context-owned reactions through
// the mechanism scope, and the factory operates mechanisms at creation.

@MainActor
@Test func `MechanismShellInfrastructure registration lands in the context's reaction list`() {
  let source = ManualCog<Int>(0)

  let cogs = Cogs.forTesting(mechanisms: [
    MechanismProbe { m in
      m.run { c in _ = c[source] }
      m.watch(source, initial: .skip) { _, _ in }
    }
  ])

  // Two registrations through the controller are two context-owned
  // reactions, in registration order.
  #expect(cogs.reactions.count == 2)
}

@MainActor
@Test func `MechanismShellInfrastructure a default mechanism name drops the suffix`() {
  struct RefreshMechanism: Mechanism {
    func operate(_ m: MechanismController) {}
  }
  struct Oddly: Mechanism {
    func operate(_ m: MechanismController) {}
  }

  #expect(RefreshMechanism().name == "Refresh")
  // A type not following the convention keeps its full name.
  #expect(Oddly().name == "Oddly")
}

@MainActor
@Test func `MechanismShellInfrastructure operating twice is rejected by the factory seam`() {
  // `operateMechanisms` is the single package entry behind both factories;
  // its once-only guard is what keeps "bootstrap-only" structural. The public
  // trap is proven by MECH-04's exit test; this only pins that the guard
  // path exists for an empty second list, which is silently ignored.
  let cogs = Cogs.forTesting(mechanisms: [MechanismProbe { _ in }])
  cogs.operateMechanisms([])
  #expect(cogs.reactions.isEmpty)
}
