// scenario: POLICY-05
//
// Streams are latest-only. Ordered policies accept `RunWork`, whose public
// surface deliberately has no `.stream` factory, so an invalid combination is
// rejected by the selector's result type rather than by a runtime branch.
//
// The legal `.latest` declaration proves `.stream` itself is available. All
// ordered spellings are values of one `OrderedPolicy` type resolving to one
// `RunWork` initializer, so one rejected declaration carries the proof for
// `.queue`, `.exhaustLatest`, and `.merged` alike.

import Cog

enum OrderedStreamPolicyRejected {
  /// Produces a finite sequence without introducing another library.
  private static func values() -> AsyncStream<Int> {
    AsyncStream { continuation in
      continuation.yield(1)
      continuation.finish()
    }
  }

  /// Latest work may describe a stream.
  static func declaresLatestStream() {
    _ = Cog<Int>.Async(.latest, default: 0) { _ in .stream(values()) }
    _ = CogBox<Int, Int>.Async(.latest, default: 0) { _, _ in .stream(values()) }
  }

  /// Every ordered policy still accepts one-shot work, including keyed work.
  static func declaresOrderedRuns() {
    _ = Cog<Int>.Async(.queue, default: 0) { _ in .run { 1 } }
    _ = Cog<Int>.Async(.exhaustLatest, default: 0) { _ in .run { 1 } }
    _ = Cog<Int>.Async(.merged, default: 0) { _ in .run { 1 } }
    _ = CogBox<Int, Int>.Async(.queue, default: 0) { _, key in .run { key } }
  }

  /// An ordered policy accepts one-shot run work only.
  static func rejectsQueuedStream() {
    _ = Cog<Int>.Async(.queue, default: 0) { _ in
      // expect-error: type 'RunWork<Int>' has no member 'stream'
      .stream(values())
    }
  }
}
