import Foundation
import Testing

@testable import Cog

// Core and edge choices are library build settings selected by a test runner.
// The sentinel closes both silent-failure paths: the manifest must mirror the
// requested values into this target, and the library must report the same
// selection rather than compiling every command as the default core.

#if COG_LEG_CORE_SIMPLE && COG_LEG_CORE_ARENA
#error("Package.swift defined two core implementations for the test target")
#elseif !COG_LEG_CORE_SIMPLE && !COG_LEG_CORE_ARENA
#error("Package.swift defined no core implementation for the test target")
#endif

#if COG_LEG_CORE_SIMPLE && (COG_LEG_EDGE_POOL || COG_LEG_EDGE_PREFIX)
#error("Package.swift selected an arena edge beside the simple test core")
#elseif COG_LEG_CORE_ARENA && !COG_LEG_EDGE_POOL && !COG_LEG_EDGE_PREFIX
#error("Package.swift defined no edge implementation for the arena test core")
#endif

/// Core spelling the manifest mirrored into this test target.
private let compiledTestCore: String = {
  #if COG_LEG_CORE_SIMPLE
  "simple"
  #else
  "arena"
  #endif
}()

/// Edge spelling the manifest mirrored into this test target.
private let compiledTestEdge: String? = {
  #if COG_LEG_EDGE_POOL
  "pool"
  #elseif COG_LEG_EDGE_PREFIX
  "prefix"
  #else
  nil
  #endif
}()

@MainActor
@Test func `CoreSelectorInfrastructure compiles the core and edge the environment requested`() {
  let environment = ProcessInfo.processInfo.environment
  let requestedCore = environment["COG_TEST_CORE"] ?? "simple"
  let requestedEdge = requestedCore == "arena" ? environment["COG_TEST_EDGE"] ?? "pool" : nil

  #expect(compiledTestCore == requestedCore)
  #expect(compiledTestEdge == requestedEdge)
}

@MainActor
@Test func `CoreSelectorInfrastructure builds the library with the same core and edge`() {
  #expect(CogCoreImplementation.compiled.rawValue == compiledTestCore)
  #expect(CogEdgeImplementation.compiled?.rawValue == compiledTestEdge)
}
