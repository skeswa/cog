/// Core implementation compiled into the Cog library.
///
/// The build-time selector is internal and changes no public API. M6's measured
/// decision retains the simple class-state core as the shipping default and
/// the arena behind explicit behavior and benchmark comparison builds.
internal nonisolated enum CogCoreImplementation: String, Sendable {
  /// The class-state correctness core shipped through 0.1.x.
  case simple

  /// The data-oriented arena retained as a selector-only comparison build.
  case arena

  /// The implementation selected by `COG_TEST_CORE` in `Package.swift`.
  static var compiled: CogCoreImplementation {
    #if COG_CORE_SIMPLE && COG_CORE_ARENA
    #error("Package.swift defined two Cog core implementations")
    #elseif COG_CORE_SIMPLE
    .simple
    #elseif COG_CORE_ARENA
    .arena
    #else
    #error("Package.swift defined no Cog core implementation")
    #endif
  }
}

/// Edge representation compiled for an arena build.
///
/// A simple-core build has no selected arena edge representation. Pool remains
/// the implicit arena default; the other cases are explicit benchmark candidates.
internal nonisolated enum CogEdgeImplementation: String, Sendable {
  /// Shared linked edges owned by one indexed pool.
  case pool

  /// Per-state dependency and subscriber arrays with prefix recapture.
  case prefix

  /// One inline dependency per state with ordered overflow for additional parents.
  case inline

  /// The edge candidate selected by `COG_TEST_EDGE`, or `nil` for simple.
  static var compiled: CogEdgeImplementation? {
    #if COG_CORE_SIMPLE && (COG_EDGE_POOL || COG_EDGE_PREFIX || COG_EDGE_INLINE)
    #error("Package.swift selected an arena edge beside the simple core")
    #elseif COG_CORE_SIMPLE
    nil
    #elseif COG_CORE_ARENA && COG_EDGE_POOL
    .pool
    #elseif COG_CORE_ARENA && COG_EDGE_PREFIX
    .prefix
    #elseif COG_CORE_ARENA && COG_EDGE_INLINE
    .inline
    #elseif COG_CORE_ARENA
    #error("Package.swift defined no edge implementation for the arena core")
    #else
    #error("Package.swift defined no Cog core implementation")
    #endif
  }
}
