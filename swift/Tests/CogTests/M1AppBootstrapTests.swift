import Cog
import CogTesting
import Testing

// `ONE-01`, the app install. Public `Cog` API and the `CogTesting` product
// only — no `@testable`, nothing that could notice how a context stores
// anything (scenarios.md constraint 3).
//
// The scenario runs inside the scoped bootstrap fixture `CogTesting` vends.
// The app install is process-global while a test suite is one process, so the
// synchronous MainActor scope removes the install before another test can run.

// MARK: - ONE-01

@MainActor
@Test func `ONE-01 an op and a read in separate features share the bootstrapped context`() {
  Cogtext.withBootstrappedApp { cogs in
    #expect(Cogtext.isBootstrappedApp(cogs))
    #expect(SettingsFeature.selectedWeatherZip(in: cogs) == nil)

    cogs.selectZip("10001")

    #expect(SettingsFeature.selectedWeatherZip(in: cogs) == "10001")
    #expect(Cogtext.isBootstrappedApp(cogs))
  }
}

// MARK: - The scoped bootstrap seam

// Not a scenario: this is the containment the two tests above depend on. If
// the seam ever stopped removing its install, `ONE-01` would still pass while
// quietly poisoning the rest of the suite, so the property gets its own test
// rather than riding along as an assumption.

@MainActor
@Test func `M1AppBootstrapSeam installs for the scope and leaves nothing behind`() {
  #expect(Cogtext.hasBootstrappedApp == false)

  Cogtext.withBootstrappedApp { _ in
    #expect(Cogtext.hasBootstrappedApp == true)
  }

  #expect(Cogtext.hasBootstrappedApp == false)
}

@MainActor
@Test func `M1AppBootstrapSeam gives each scope its own context`() {
  // Consecutive scopes are consecutive app runtimes, not one install handed
  // out twice. A test that installs cannot see what an earlier test installed.
  let first = Cogtext.withBootstrappedApp { $0 }
  let second = Cogtext.withBootstrappedApp { $0 }

  #expect(first !== second)
}

@MainActor
@Test func `M1AppBootstrapSeam removes its install when the body throws`() {
  struct Failure: Error {}

  #expect(throws: Failure.self) {
    try Cogtext.withBootstrappedApp { _ in
      throw Failure()
    }
  }

  #expect(Cogtext.hasBootstrappedApp == false)
}
