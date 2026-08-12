import Cog
import CogTesting
import Testing

// MARK: - The scoped bootstrap seam

// Not a scenario: this is the containment the ONE-01 proof depends on. If
// the seam ever stopped removing its install, `ONE-01` would still pass while
// quietly poisoning the rest of the suite, so the property gets its own test
// rather than riding along as an assumption.

@MainActor
@Test func `AppBootstrapInfrastructure installs for the scope and leaves nothing behind`() {
  #expect(Cogtext.hasBootstrappedApp == false)

  Cogtext.withBootstrappedApp { _ in
    #expect(Cogtext.hasBootstrappedApp == true)
  }

  #expect(Cogtext.hasBootstrappedApp == false)
}

@MainActor
@Test func `AppBootstrapInfrastructure gives each scope its own context`() {
  // Consecutive scopes are consecutive app runtimes, not one install handed
  // out twice. A test that installs cannot see what an earlier test installed.
  let first = Cogtext.withBootstrappedApp { $0 }
  let second = Cogtext.withBootstrappedApp { $0 }

  #expect(first !== second)
}

@MainActor
@Test func `AppBootstrapInfrastructure removes its install when the body throws`() {
  struct Failure: Error {}

  #expect(throws: Failure.self) {
    try Cogtext.withBootstrappedApp { _ in
      throw Failure()
    }
  }

  #expect(Cogtext.hasBootstrappedApp == false)
}
