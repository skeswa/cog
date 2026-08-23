import Cog
import CogTesting
import Testing

// MARK: - The scoped assembly seam

// Not a scenario: this is the containment the ONE-01 proof depends on. If
// the seam ever stopped removing its install, `ONE-01` would still pass while
// quietly poisoning the rest of the suite, so the property gets its own test
// rather than riding along as an assumption.

@MainActor
@Test func `AssemblyInfrastructure installs for the scope and leaves nothing behind`() {
  #expect(Cogs.hasAssembledCogs == false)

  Cogs.withAssembledCogs { _ in
    #expect(Cogs.hasAssembledCogs == true)
  }

  #expect(Cogs.hasAssembledCogs == false)
}

@MainActor
@Test func `AssemblyInfrastructure gives each scope its own context`() {
  // Consecutive scopes are consecutive app runtimes, not one install handed
  // out twice. A test that installs cannot see what an earlier test installed.
  let first = Cogs.withAssembledCogs { $0 }
  let second = Cogs.withAssembledCogs { $0 }

  #expect(first !== second)
}

@MainActor
@Test func `AssemblyInfrastructure removes its install when the body throws`() {
  struct Failure: Error {}

  #expect(throws: Failure.self) {
    try Cogs.withAssembledCogs { _ in
      throw Failure()
    }
  }

  #expect(Cogs.hasAssembledCogs == false)
}
