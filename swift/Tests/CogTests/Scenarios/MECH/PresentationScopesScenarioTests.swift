import Cog
import CogTesting
import Testing

// Arbitrary presentation membership through one registration. This is the
// composition an app-owned lifetime registry would otherwise be invented for,
// so the proofs count parent-owned selector registrations as carefully as they
// count child work.

/// One navigation entry. Two entries for the same resource get different IDs.
private struct PresentationID: Hashable {
  let value: Int
}

@MainActor private let _openPresentationsCog = Cog<[PresentationID]>.Manual(
  { [] }, name: "openPresentations")
@MainActor private let _queryCogs = CogBox<String, PresentationID>.Manual({ "" }, name: "query")
@MainActor private let _libraryCog = Cog<[String]>.Manual({ [] }, name: "library")

extension CogOps {
  /// Pushes one entry, minting its identity where the navigation happens.
  fileprivate func pushPresentation(_ id: PresentationID) {
    turn { c in c[_openPresentationsCog] = c[_openPresentationsCog] + [id] }
  }

  /// Removes one entry by identity, leaving every other entry in place.
  fileprivate func removePresentation(_ id: PresentationID) {
    turn { c in c[_openPresentationsCog] = c[_openPresentationsCog].filter { $0 != id } }
  }

  /// Reverses the stack without changing which entries are present.
  fileprivate func reversePresentations() {
    turn { c in c[_openPresentationsCog] = c[_openPresentationsCog].reversed() }
  }

  /// Types into one entry's local query.
  fileprivate func typeQuery(_ text: String, in id: PresentationID) {
    turn { c in c[_queryCogs[id]] = text }
  }

  /// Accepts one library mutation into state a longer-lived owner keeps.
  fileprivate func acceptLibraryMutation(_ entry: String) {
    turn { c in c[_libraryCog] = c[_libraryCog] + [entry] }
  }
}

@MainActor
@Test func `MECH-32 presentation entries open, survive, and retire independently`() {
  var openings: [PresentationID] = []
  var searches: [String] = []
  var instances: [PresentationID: Int] = [:]
  var nextInstance = 0

  let cogs = Cogs.forTesting(mechanisms: [
    MechanismProbe { m in
      m.scope(each: _openPresentationsCog, name: "presentation") { id, s in
        openings.append(id)
        nextInstance += 1
        instances[id] = nextInstance
        let instance = nextInstance
        s.watch(_queryCogs[id], initial: .skip, name: "search") { _, query in
          searches.append("\(id.value)#\(instance):\(query)")
        }
      }
    }
  ])
  #expect(openings.isEmpty)

  // 1. Push P1 for resource R and start its work.
  let p1 = PresentationID(value: 1)
  cogs.pushPresentation(p1)
  #expect(openings == [p1])
  cogs.typeQuery("alpha", in: p1)
  #expect(searches == ["1#1:alpha"])

  // 2. Push P2 for the same resource while P1 remains alive but covered. P1 is
  //    not restarted: its instance number is unchanged and its work continues.
  let p2 = PresentationID(value: 2)
  cogs.pushPresentation(p2)
  #expect(openings == [p1, p2])
  #expect(instances[p1] == 1)

  // 3. Change P2-local state. P1 does not restart and does not react.
  cogs.typeQuery("beta", in: p2)
  #expect(searches == ["1#1:alpha", "2#2:beta"])
  cogs.typeQuery("gamma", in: p1)
  #expect(searches == ["1#1:alpha", "2#2:beta", "1#1:gamma"])

  // Reordering alone is not a membership change: nothing opens, retires, or
  // restarts, and both entries keep working.
  cogs.reversePresentations()
  #expect(openings == [p1, p2])
  cogs.typeQuery("delta", in: p1)
  cogs.typeQuery("epsilon", in: p2)
  #expect(
    searches == [
      "1#1:alpha", "2#2:beta", "1#1:gamma", "1#1:delta", "2#2:epsilon",
    ]
  )

  // 4. Remove P1 while preserving P2's instance and work.
  cogs.removePresentation(p1)
  cogs.typeQuery("zeta", in: p1)
  cogs.typeQuery("eta", in: p2)
  #expect(
    searches == [
      "1#1:alpha", "2#2:beta", "1#1:gamma", "1#1:delta", "2#2:epsilon", "2#2:eta",
    ]
  )

  // 5. Remove P2 as well: no entry reacts to anything afterward.
  cogs.removePresentation(p2)
  cogs.typeQuery("theta", in: p2)
  #expect(searches.count == 6)

  // 6. Repeat with fresh entry IDs. Each push opens exactly one new child, and
  //    re-pushing a previously used identity opens a different instance rather
  //    than reviving the old one.
  for value in 3...12 {
    let id = PresentationID(value: value)
    cogs.pushPresentation(id)
    cogs.removePresentation(id)
  }
  #expect(openings.count == 12)

  cogs.pushPresentation(p1)
  #expect(instances[p1] != 1)
  cogs.typeQuery("iota", in: p1)
  #expect(searches.last == "1#13:iota")
}

@MainActor
@Test func `MECH-32 one registration serves every entry, now and forever`() {
  // The accounting question section 10 of the design discussion raised: who
  // removes the *selector*? Here there is only ever one, so nothing accumulates
  // as entries come and go. `CogTesting`'s probe controller lets the test count
  // effect registrations without reaching into the runtime.
  var childRegistrations = 0
  let (cogs, m) = Cogs.forTestingWithController()

  m.scope(each: _openPresentationsCog, name: "presentation") { _, s in
    s.run { _ in }
    childRegistrations += 1
  }

  // Two hundred pushes and removals later, the only surviving registrations are
  // the one selector and the children the current membership justifies.
  for value in 100..<300 {
    cogs.pushPresentation(PresentationID(value: value))
    cogs.removePresentation(PresentationID(value: value))
  }
  #expect(childRegistrations == 200)
  #expect(cogs.peek(_openPresentationsCog).isEmpty)

  // The selector is still live and still the only one: a new push still opens
  // exactly one child.
  cogs.pushPresentation(PresentationID(value: 500))
  #expect(childRegistrations == 201)
}

@MainActor
@Test func `MECH-34 accepted domain work survives the presentation that asked for it`()
  async
{
  // The library mutation is owned by a session-lifetime mechanism, not by the
  // presentation. Dismissing the presentation ends its feedback and nothing
  // else.
  var feedback: [String] = []
  let gate = ScopeTestGate()
  let (starts, startContinuation) = AsyncStream.makeStream(of: Int.self)
  let (finishes, finishContinuation) = AsyncStream.makeStream(of: Int.self)
  let intent = Cog<String?>.Manual { nil }

  let cogs = Cogs.forTesting(mechanisms: [
    MechanismProbe(name: "Session") { m in
      // The longer-lived owner. It accepts the intent and owns the work.
      m.watch(intent, initial: .skip, name: "accept") { _, submitted in
        guard let submitted else { return }
        m.task(name: "mutate") { [weak m] in
          startContinuation.yield(1)
          await gate.wait(1)
          await MainActor.run { m?.acceptLibraryMutation(submitted) }
          finishContinuation.yield(1)
        }
      }
    },
    MechanismProbe(name: "Presentations") { m in
      m.scope(each: _openPresentationsCog, name: "presentation") { id, s in
        // Presentation-owned feedback only.
        s.watch(_libraryCog, initial: .skip, name: "feedback") { _, library in
          feedback.append("\(id.value):\(library.count)")
        }
      }
    },
  ])

  let p1 = PresentationID(value: 1)
  cogs.pushPresentation(p1)

  // The presentation publishes an intent; the session mechanism accepts it.
  cogs.turn(intent, to: "borrow")
  var startIterator = starts.makeAsyncIterator()
  #expect(await startIterator.next() == 1)

  // The presentation is dismissed while the accepted work is still running.
  cogs.removePresentation(p1)

  gate.release(1)
  var finishIterator = finishes.makeAsyncIterator()
  #expect(await finishIterator.next() == 1)

  // The domain-owned mutation completed and published; the presentation's
  // feedback did not run, because that presentation is gone.
  #expect(cogs.peek(_libraryCog) == ["borrow"])
  #expect(feedback.isEmpty)

  // A new presentation sees the accepted result as ordinary shared state.
  let p2 = PresentationID(value: 2)
  cogs.pushPresentation(p2)
  cogs.acceptLibraryMutation("return")
  #expect(feedback == ["2:2"])
}
