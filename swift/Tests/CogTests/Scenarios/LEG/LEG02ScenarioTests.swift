import Foundation
import Testing

// The isolation matrix runs these test targets four times — {MainActor
// default isolation, nonisolated} × {`NonisolatedNonsendingByDefault` on, off}
// — under environment variables that `Package.swift` reads. Nothing about a
// leg is visible in a passing run, so the matrix's worst failure is silent:
// if the manifest stopped reading the environment, all four legs would compile
// identically and all four would still go green.
//
// The test below closes that hole with two independent comparisons:
//
//   1. the environment the runner asked for, against the `.define()`s the
//      manifest compiled in — this catches a manifest that ignores the
//      environment; and
//   2. those `.define()`s against the isolation the compiler actually applied,
//      observed through `#isolation` — this catches a manifest that mirrors
//      the environment into defines but forgets to apply the settings.
//
// Neither comparison can be satisfied by the other, and neither is a
// tautology: comparison 1 has the environment on one side and the build on the
// other, and comparison 2 has the build's claim on one side and the build's
// behavior on the other.

// MARK: - What the manifest says it compiled

#if COG_LEG_ISOLATION_MAINACTOR && COG_LEG_ISOLATION_NONISOLATED
#error("Package.swift defined both isolation legs at once")
#endif
#if !COG_LEG_ISOLATION_MAINACTOR && !COG_LEG_ISOLATION_NONISOLATED
#error("Package.swift defined no isolation leg")
#endif
#if COG_LEG_NNBD_ON && COG_LEG_NNBD_OFF
#error("Package.swift defined both NonisolatedNonsendingByDefault legs at once")
#endif
#if !COG_LEG_NNBD_ON && !COG_LEG_NNBD_OFF
#error("Package.swift defined no NonisolatedNonsendingByDefault leg")
#endif

/// The isolation leg the manifest mirrored into this target, in the spelling
/// `COG_TEST_ISOLATION` uses.
private let compiledIsolationLeg: String = {
  #if COG_LEG_ISOLATION_MAINACTOR
  "mainactor"
  #else
  "nonisolated"
  #endif
}()

/// The `NonisolatedNonsendingByDefault` leg the manifest mirrored into this
/// target, in the spelling `COG_TEST_NNBD` uses.
private let compiledNonisolatedNonsendingLeg: String = {
  #if COG_LEG_NNBD_ON
  "1"
  #else
  "0"
  #endif
}()

// MARK: - What the compiler actually did

/// The isolation of a function that states none, which is the target's
/// *default* isolation and nothing else.
///
/// `#isolation` is `MainActor` here exactly when this target was compiled with
/// `-default-isolation MainActor`, and `nil` when it was compiled
/// `-default-isolation nonisolated`.
private func isolationOfAnUnannotatedFunction() -> (any Actor)? { #isolation }

/// The isolation an explicitly `nonisolated` async function runs under.
///
/// Under `NonisolatedNonsendingByDefault` this function is nonsending: it
/// inherits its caller's isolation, so `#isolation` is whatever called it.
/// Without the feature it hops to the generic executor and `#isolation` is
/// `nil`. Being spelled `nonisolated` outright, it says the same thing in both
/// isolation legs, which is what makes the two probes independent.
private nonisolated func isolationOfANonisolatedAsyncFunction() async -> (any Actor)? {
  #isolation
}

/// The isolation `isolationOfANonisolatedAsyncFunction` observes when the
/// caller is definitely the main actor.
@MainActor
private func isolationOfANonisolatedAsyncCallFromTheMainActor() async -> (any Actor)? {
  await isolationOfANonisolatedAsyncFunction()
}

private func isTheMainActor(_ actor: (any Actor)?) -> Bool {
  guard let actor else { return false }
  return actor === MainActor.shared
}

// MARK: - What the runner asked for

/// Reads one leg variable, applying the same default the manifest applies.
///
/// The manifest rejects an unrecognized value outright, so a value that is
/// neither expected nor absent means this test and `Package.swift` disagree
/// about the legs themselves.
private func requestedLeg(
  _ variable: String,
  default fallback: String,
  expecting expected: Set<String>
) -> String {
  guard let raw = ProcessInfo.processInfo.environment[variable], !raw.isEmpty else {
    return fallback
  }
  guard expected.contains(raw) else {
    Issue.record("\(variable) is \(raw), which is not one of \(expected.sorted())")
    return fallback
  }
  return raw
}

// MARK: - LEG-02

@Test func `LEG-02 every leg compiled with the settings its environment selected`() async {
  let requestedIsolationLeg = requestedLeg(
    "COG_TEST_ISOLATION",
    default: "mainactor",
    expecting: ["mainactor", "nonisolated"]
  )
  let requestedNonisolatedNonsendingLeg = requestedLeg(
    "COG_TEST_NNBD",
    default: "1",
    expecting: ["0", "1"]
  )

  // 1. The environment reached the manifest.
  #expect(
    compiledIsolationLeg == requestedIsolationLeg,
    """
    COG_TEST_ISOLATION asked for the \(requestedIsolationLeg) leg but this \
    target was compiled for the \(compiledIsolationLeg) leg. Package.swift is \
    not honoring COG_TEST_ISOLATION, or SwiftPM served a stale manifest — see \
    COG_TEST_MANIFEST_CACHE in tools/swift-test.mjs.
    """
  )
  #expect(
    compiledNonisolatedNonsendingLeg == requestedNonisolatedNonsendingLeg,
    """
    COG_TEST_NNBD asked for the \(requestedNonisolatedNonsendingLeg) leg but \
    this target was compiled for the \(compiledNonisolatedNonsendingLeg) leg. \
    Package.swift is not honoring COG_TEST_NNBD, or SwiftPM served a stale \
    manifest — see COG_TEST_MANIFEST_CACHE in tools/swift-test.mjs.
    """
  )

  // 2. The manifest's claim matches the build.
  let defaultIsolationIsTheMainActor = isTheMainActor(isolationOfAnUnannotatedFunction())
  #expect(
    defaultIsolationIsTheMainActor == (compiledIsolationLeg == "mainactor"),
    """
    This target declares the \(compiledIsolationLeg) leg, but a function that \
    states no isolation is \(defaultIsolationIsTheMainActor ? "" : "not ")\
    main-actor-isolated. The .define() and .defaultIsolation() in \
    Package.swift's testSettings have drifted apart.
    """
  )

  let nonisolatedAsyncInheritsItsCaller = isTheMainActor(
    await isolationOfANonisolatedAsyncCallFromTheMainActor()
  )
  #expect(
    nonisolatedAsyncInheritsItsCaller == (compiledNonisolatedNonsendingLeg == "1"),
    """
    This target declares the NonisolatedNonsendingByDefault=\
    \(compiledNonisolatedNonsendingLeg) leg, but a nonisolated async function \
    called from the main actor \(nonisolatedAsyncInheritsItsCaller ? "does" : "does not") \
    inherit its caller's isolation. The .define() and \
    .enableUpcomingFeature() in Package.swift's testSettings have drifted \
    apart.
    """
  )
}
