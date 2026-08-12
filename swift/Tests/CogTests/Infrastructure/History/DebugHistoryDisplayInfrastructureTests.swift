#if DEBUG

@testable import Cog
import Testing

@MainActor
@Test func `DebugHistoryDisplayInfrastructure formats and emits a bounded snapshot`() {
  let source = CogLabel(name: "display.source", fileID: #fileID, line: #line)
  let derived = CogLabel(name: "display.derived", fileID: #fileID, line: #line)
  let effect = CogLabel(name: "display.effect", fileID: #fileID, line: #line)
  let history = CogHistory(
    ring: [
      CogHistoryEntry(event: .write, turn: 12, subject: .cog(source, nil)),
      CogHistoryEntry(event: .recompute, turn: 12, subject: .cog(derived, nil)),
      CogHistoryEntry(event: .effect, turn: 11, subject: .effect(effect)),
      CogHistoryEntry(event: .turn, turn: 12, subject: .turn("display\nturn")),
    ],
    oldest: 2,
    capacity: 8
  )
  var emitted: [String] = []
  history.log(to: { emitted.append($0) })

  #expect(
    emitted == [
      "Cog history: 4 of 8 entries, oldest first",
      #"[turn 11] effect: "display.effect""#,
      #"[turn 12] turn: "display\nturn""#,
      #"[turn 12] write: "display.source""#,
      #"[turn 12] recompute: "display.derived""#,
    ]
  )

  // Unified-log delivery is asynchronous and environment-dependent. The
  // infrastructure contract is that the real emitter accepts the formatted
  // bounded snapshot without trapping; the synchronous seam above proves the
  // exact content.
  history.log()
}

#endif
