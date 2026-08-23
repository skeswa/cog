// scenario: HIST-04
// configuration: release
//
// Release builds pay nothing for history. This fixture proves the visible
// half directly against the release-built modules: the `debugHistory`
// accessor and the `CogHistory` type are absent, not merely empty. The
// recording calls live behind the same `#if DEBUG` gate as these types, so a
// release build that regressed into recording could not compile without
// resurfacing them here.

import Cog

enum ReleaseHasNoHistory {
  static func cannotReadHistory(cogs: Cogs) {
    // expect-error: value of type 'Cogs' has no member 'debugHistory'
    _ = cogs.debugHistory
  }

  // expect-error: cannot find type 'CogHistory' in scope
  static func cannotNameHistory(log: CogHistory) {}
}
