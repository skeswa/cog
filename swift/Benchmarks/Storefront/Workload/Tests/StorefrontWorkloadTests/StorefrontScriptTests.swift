import Testing

@testable import StorefrontWorkload

/// The scripted request boundary's own bookkeeping, with no runtime attached.
///
/// ``StorefrontScript`` is what makes the interaction trace deterministic
/// rather than merely repeatable, and it is shared verbatim by every runtime
/// the workload is ported to. It therefore has to be correct on its own terms,
/// before any graph is involved: selection and execution are two different
/// scheduler events, and the script's whole job is to hold the gap between
/// them open so a driver can release work by name.
///
/// `@testable` because the synchronous selection path, `schedule(_:)` on the
/// script and `begin(_:)`, is internal to the workload module: a runtime
/// records selections through ``StorefrontService/schedule(_:)`` and never
/// reaches these directly. This suite is the workload package's own test, not a
/// Cog scenario test, so the repository's rule about `@testable` in scenario
/// tests does not apply.
@Suite("Storefront script")
@MainActor
struct StorefrontScriptTests {
  @Test("an early release consumes the synchronously scheduled request")
  func earlyReleaseConsumesScheduledRequest() async throws {
    let script = StorefrontScript(mode: .scripted)
    script.schedule(.catalog)

    #expect(await script.pendingRequestIDs == [.catalog])
    #expect(await script.outstandingCount == 1)
    await script.release(.catalog)
    try await script.begin(.catalog)

    #expect(await script.startCount(of: .catalog) == 1)
    #expect(await script.outstandingCount == 0)
  }
}
