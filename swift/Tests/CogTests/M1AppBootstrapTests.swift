import Cog
import CogTesting
import Testing

// `ONE-01`, the app install. Public `Cog` API and the `CogTesting` product
// only — no `@testable`, nothing that could notice how a context stores
// anything (scenarios.md constraint 3).
//
// Every test here runs inside `Cogtext.withBootstrappedApp`, the scoped
// bootstrap seam `CogTesting` vends. The app context is process-global and a
// suite is one process, so a test that installed one and walked away would
// change the world every later test runs in — and, once `M1-29b` lands the
// second-install guard, would make the next bootstrap anywhere in the suite
// fail. The seam installs for the length of one synchronous main-actor scope
// and takes the install back out again; because everything Cog owns is
// MainActor-confined, that scope cannot interleave with another test even
// under `--parallel`.
//
// What these tests cannot yet show: `ONE-01` also asks for an op in a feature
// file to *commit a write* that a read elsewhere then sees. `commit` does not
// exist until `M1-04ab`, so the write is unspellable and is not faked here.
// What is proven is the half the scenario rests on — that bootstrap installs
// one context, that unrelated feature files resolve through that same context
// without being handed it, and that there is no second context anywhere for a
// read to land in. The moment `commit` exists, add the write to
// `WeatherFeature` and the round trip below.

// MARK: - ONE-01

@MainActor
@Test func `ONE-01 app bootstrap installs the one context every feature resolves through`() {
  Cogtext.withBootstrappedApp { cogs in
    // Two feature files, in two other files, neither handed a context and
    // neither knowing the other exists. Both land on the context the app's
    // entry point just made.
    #expect(WeatherFeature.context === cogs)
    #expect(SettingsFeature.context === cogs)

    // And so does anything else that asks. Identity is the assertion that
    // matters: a second context would be a second graph, and a write in one
    // would be invisible in the other.
    #expect(Cogtext.app === cogs)
  }
}

@MainActor
@Test func `ONE-01 a feature reads its own state through the installed context`() {
  Cogtext.withBootstrappedApp { _ in
    // The bootstrap call is the whole setup. Nothing registered these
    // declarations, nothing injected a context into either feature, and
    // nothing seeded a value.
    #expect(WeatherFeature.selectedZip() == nil)
    #expect(SettingsFeature.usesCelsius() == true)
  }
}

@MainActor
@Test func `ONE-01 the app context is the same context however often it is asked for`() {
  Cogtext.withBootstrappedApp { cogs in
    // A launch-time install is not a value the caller has to keep hold of to
    // keep alive, and it is not re-derived per lookup. The tenth read of the
    // app context is the first one.
    for _ in 0..<10 {
      #expect(Cogtext.app === cogs)
      #expect(WeatherFeature.context === cogs)
    }
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
