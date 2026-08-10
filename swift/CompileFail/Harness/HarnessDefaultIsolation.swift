// scenario: HARNESS-04
//
// Sentinel. Proves the runner really applies the library's build settings
// rather than plain `swiftc` defaults. This file only fails to compile because
// the harness derived BOTH `-swift-version 6` and `-default-isolation
// MainActor` from `Package.swift`; drop either and it compiles cleanly and the
// harness reports `no-diagnostic`.
//
// It is deliberately not ACTOR-02 — that scenario proves the shipped graph API
// is unreachable off the MainActor, and M1 owns its fixture.

enum HarnessDefaultIsolation {
  /// MainActor-isolated by the package-wide default isolation, with no
  /// annotation anywhere in this file saying so.
  static func mainActorOnly() {}

  nonisolated static func fromOffActor() {
    // expect-error: call to main actor-isolated static method 'mainActorOnly()'
    mainActorOnly()
  }
}
