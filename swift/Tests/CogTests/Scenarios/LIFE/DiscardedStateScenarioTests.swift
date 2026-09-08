import Cog
import CogTesting
import Observation
import Testing
import os

// Explicit release for state whose real owner is a domain lifetime. Every proof
// here uses the UI subscript — the read a view body makes — because that read is
// the one that pins state permanently, and a proof over seeded or watched values
// would not touch the mechanism under test.

/// One presentation lifetime whose keyed state should not outlive it.
private struct ScreenID: Hashable {
  let value: Int
}

@MainActor private let _draftCogs = CogBox<String, ScreenID>.Manual(
  { "" },
  lifetime: .whileObserved(resetToInitial: true),
  name: "draft"
)
@MainActor private let _openScreensCog = Cog<[ScreenID]>.Manual({ [] }, name: "openScreens")
@MainActor private let _sharedLibraryCog = Cog<[String]>.Manual({ [] }, name: "sharedLibrary")
@MainActor private let _permanentCog = Cog<Int>.Manual({ 0 }, name: "permanent")

extension CogOps {
  /// Opens one screen.
  fileprivate func openScreen(_ id: ScreenID) {
    turn { c in c[_openScreensCog] = c[_openScreensCog] + [id] }
  }

  /// Closes one screen and releases the state that screen owned.
  ///
  /// Both halves belong to the op that ends the lifetime: the scope stops the
  /// screen's effects, and this states what happens to its values.
  fileprivate func closeScreen(_ id: ScreenID) {
    turn { c in c[_openScreensCog] = c[_openScreensCog].filter { $0 != id } }
    discard(_draftCogs[id])
  }

  /// Types into one screen's draft.
  fileprivate func typeDraft(_ text: String, on id: ScreenID) {
    turn(_draftCogs[id], to: text)
  }

  /// Deliberately discards a source declared to live for the whole context.
  fileprivate func discardPermanentState() {
    discard(_permanentCog)
  }
}

@MainActor
@Test func `LIFE-13 a discarded state releases the UI boundary that pinned it`() {
  let cogs = Cogs.forTesting()
  let screen = ScreenID(value: 1)
  let baselineBoundaries = cogs.observationBoundaryCount

  cogs.openScreen(screen)
  cogs.typeDraft("half-written", on: screen)

  // The UI subscript is what pins the state. Ordinary release can never undo
  // it, because Observation offers no way to learn the reader has gone.
  #expect(cogs[_draftCogs[screen]] == "half-written")
  #expect(cogs.hasObservationBoundary(for: _draftCogs[screen]))
  #expect(cogs.observationBoundaryCount == baselineBoundaries + 1)

  cogs.closeScreen(screen)

  // The row, its value, and its boundary are all gone, and a later read starts
  // over at the declared starting value rather than returning the draft.
  #expect(!cogs.hasObservationBoundary(for: _draftCogs[screen]))
  #expect(cogs.observationBoundaryCount == baselineBoundaries)
  #expect(cogs.peek(_draftCogs[screen]) == "")
}

@MainActor
@Test func `LIFE-13 a surviving reader is notified before its state disappears`() {
  // The hazard an explicit discard has to avoid: a view still tracking a
  // boundary that can never fire again would freeze on stale content. The
  // notice is what lets it re-render, re-read, and reattach.
  let cogs = Cogs.forTesting()
  let screen = ScreenID(value: 2)
  let notices = OSAllocatedUnfairLock(initialState: 0)

  cogs.openScreen(screen)
  cogs.typeDraft("draft text", on: screen)

  let observed = withObservationTracking {
    cogs[_draftCogs[screen]]
  } onChange: {
    notices.withLock { $0 += 1 }
  }
  #expect(observed == "draft text")

  cogs.closeScreen(screen)
  #expect(notices.withLock { $0 } == 1)

  // The re-read a notified body would perform recreates the state and installs
  // a fresh boundary, so the reader is tracking again rather than stranded.
  #expect(cogs[_draftCogs[screen]] == "")
  #expect(cogs.hasObservationBoundary(for: _draftCogs[screen]))
}

@MainActor
@Test func `LIFE-14 discarding one screen's state leaves every other owner alone`() {
  let cogs = Cogs.forTesting()
  let first = ScreenID(value: 1)
  let second = ScreenID(value: 2)

  cogs.openScreen(first)
  cogs.openScreen(second)
  cogs.typeDraft("first", on: first)
  cogs.typeDraft("second", on: second)
  _ = cogs[_draftCogs[first]]
  _ = cogs[_draftCogs[second]]
  _ = cogs[_sharedLibraryCog]

  cogs.closeScreen(first)

  // The sibling's state and the shared resource state are untouched.
  #expect(cogs[_draftCogs[second]] == "second")
  #expect(cogs.hasObservationBoundary(for: _draftCogs[second]))
  #expect(cogs.hasObservationBoundary(for: _sharedLibraryCog))
  #expect(cogs.peek(_draftCogs[first]) == "")
}

@MainActor
@Test func `LIFE-14 a state another consumer still leases is not discarded`() {
  // A durable lease means someone else owns this state. Discard leaves it, so a
  // departing screen cannot reclaim what a longer-lived watcher is using; the
  // state follows its ordinary release path when its real last owner leaves.
  let screen = ScreenID(value: 3)
  var seen: [String] = []
  let cogs = Cogs.forTesting(mechanisms: [
    MechanismProbe { m in
      m.watch(_draftCogs[screen], initial: .run, name: "audit") { _, draft in
        seen.append(draft)
      }
    }
  ])
  cogs.typeDraft("leased", on: screen)
  _ = cogs[_draftCogs[screen]]
  #expect(seen == ["", "leased"])

  cogs.closeScreen(screen)

  // The value survived, and the other consumer still receives changes.
  #expect(cogs.peek(_draftCogs[screen]) == "leased")
  cogs.typeDraft("still watched", on: screen)
  #expect(seen == ["", "leased", "still watched"])
}

@MainActor
@Test func `LIFE-14 per-screen rows and boundaries return to baseline`() {
  // The accounting the dynamic-presentation migration actually depends on:
  // effect registrations returning to baseline is not the same claim as state
  // returning to baseline, and only the second one bounds memory.
  let cogs = Cogs.forTesting(mechanisms: [
    MechanismProbe { m in
      m.scope(each: _openScreensCog, name: "screen") { id, s in
        s.watch(_draftCogs[id], initial: .skip, name: "draft") { _, _ in }
      }
    }
  ])
  let baselineBoundaries = cogs.observationBoundaryCount

  for value in 1...200 {
    let screen = ScreenID(value: value)
    cogs.openScreen(screen)
    cogs.typeDraft("draft \(value)", on: screen)
    // The read a view body makes while the screen is on screen.
    _ = cogs[_draftCogs[screen]]
    cogs.closeScreen(screen)
  }

  #expect(cogs.observationBoundaryCount == baselineBoundaries)
  #expect(cogs.peek(_draftCogs[ScreenID(value: 1)]) == "")
  #expect(cogs.peek(_draftCogs[ScreenID(value: 200)]) == "")
}

@MainActor
@Test func `LIFE-15 discarding an app-lifetime source traps`() async {
  // Discard releases state; it does not reset it. A source declared to live for
  // the context has no value to come back as, so asking is a declaration
  // mistake rather than a runtime condition.
  let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
    await MainActor.run {
      let cogs = Cogs.forTesting()
      cogs.turn(_permanentCog, to: 7)
      cogs.discardPermanentState()
    }
  }

  let message = String(decoding: result?.standardErrorContent ?? [], as: UTF8.self)
  #expect(message.contains("cannot discard"), "stderr was: \(message)")
  #expect(message.contains("whileObserved(resetToInitial: true)"), "stderr was: \(message)")
}

@MainActor
@Test func `LIFE-14 discard through a retired controller is inert`() {
  // Discard is a primitive like `turn`, so retirement revokes it too: a screen
  // whose scope has ended must not reclaim state its replacement may own.
  let screen = ScreenID(value: 4)
  var retired: MechanismController?
  let cogs = Cogs.forTesting(mechanisms: [
    MechanismProbe { m in
      m.scope(each: _openScreensCog, name: "screen") { id, s in
        if id == screen { retired = s }
      }
    }
  ])

  cogs.openScreen(screen)
  cogs.typeDraft("kept", on: screen)
  _ = cogs[_draftCogs[screen]]
  let controller = try! #require(retired)

  // Close the screen without discarding, then ask the retired controller to.
  cogs.turn { c in c[_openScreensCog] = [] }
  controller.closeScreen(screen)

  #expect(cogs.peek(_draftCogs[screen]) == "kept")
  #expect(cogs.hasObservationBoundary(for: _draftCogs[screen]))

  // The runtime, which is not retired, still can.
  cogs.closeScreen(screen)
  #expect(!cogs.hasObservationBoundary(for: _draftCogs[screen]))
  #expect(cogs.peek(_draftCogs[screen]) == "")
}
