import Foundation
import Testing

@testable import Cog

// The CompactArena trait is a library build setting. This sentinel closes both
// silent-failure paths: the manifest must mirror the trait into this target,
// and the library must report the same selection.

/// Whether the manifest compiled specialization into this test target.
private let compiledTestArenaSpecialization: Bool = {
  #if COG_LEG_ARENA_COMPACT
  false
  #else
  true
  #endif
}()

@MainActor
@Test func `ArenaSpecializationInfrastructure compiles the trait the runner requested`() {
  let expectsCompactArenaTrait =
    ProcessInfo.processInfo.environment["COG_EXPECT_COMPACT_ARENA_TRAIT"] == "1"

  #expect(compiledTestArenaSpecialization == !expectsCompactArenaTrait)
}

@MainActor
@Test func `ArenaSpecializationInfrastructure builds the library with the same trait`() {
  #expect(CogArenaSpecialization.compiled == compiledTestArenaSpecialization)
}
