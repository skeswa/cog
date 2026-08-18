// scenario: POLICY-05
//
// Streams are latest-only. Ordered policies accept `RunWork`, whose public
// surface deliberately has no `.stream` factory, so an invalid combination is
// rejected by the selector's result type rather than by a runtime branch.
//
// The legal `.latest` declaration proves `.stream` itself is available. The
// three rejected declarations differ only in policy, covering every ordered
// spelling Cog exposes.

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
    _ = AsyncCog<Int>(.latest, default: 0) { _ in .stream(values()) }
    _ = AsyncCogBox<Int, Int>(.latest, default: 0) { _, _ in .stream(values()) }
  }

  /// Every ordered policy still accepts one-shot work, including keyed work.
  static func declaresOrderedRuns() {
    _ = AsyncCog<Int>(.queue, default: 0) { _ in .run { 1 } }
    _ = AsyncCog<Int>(.exhaustLatest, default: 0) { _ in .run { 1 } }
    _ = AsyncCog<Int>(.merged, default: 0) { _ in .run { 1 } }
    _ = AsyncCogBox<Int, Int>(.queue, default: 0) { _, key in .run { key } }
  }

  /// Queue accepts one-shot run work only.
  static func rejectsQueuedStream() {
    _ = AsyncCog<Int>(.queue, default: 0) { _ in
      // expect-error: type 'RunWork<Int>' has no member 'stream'
      .stream(values())
    }
  }

  /// Exhaust-latest accepts one-shot run work only.
  static func rejectsExhaustedStream() {
    _ = AsyncCog<Int>(.exhaustLatest, default: 0) { _ in
      // expect-error: type 'RunWork<Int>' has no member 'stream'
      .stream(values())
    }
  }

  /// Merged accepts one-shot run work only.
  static func rejectsMergedStream() {
    _ = AsyncCog<Int>(.merged, default: 0) { _ in
      // expect-error: type 'RunWork<Int>' has no member 'stream'
      .stream(values())
    }
  }
}
