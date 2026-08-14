import Cog
import CogTesting
import Testing

/// Parks the owned task's continuation so the test can end it after proving
/// cancellation, instead of leaving a suspended task behind.
@MainActor
private final class Group11Suspension {
  var continuation: CheckedContinuation<Void, Never>?
}

@MainActor
@Test func `GROUP-11 a reaction can cancel its own group mid-flush`() async {
  let cogs = Cogs.forTesting()
  let source = ManualCog<Int>(0)
  var seen: [Int] = []
  let (starts, startContinuation) = AsyncStream.makeStream(of: Void.self)
  let (cancellations, cancellationContinuation) = AsyncStream.makeStream(of: Void.self)
  let suspension = Group11Suspension()
  let group = EffectGroup()

  group.add(
    cogs.run { c in
      guard c[source] == 1 else { return }
      group.cancel()
    }
  )
  group.add(cogs.run { c in seen.append(c[source]) })
  group.task(name: "group11.owned") { @MainActor in
    startContinuation.yield()
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        if Task.isCancelled {
          continuation.resume()
        } else {
          suspension.continuation = continuation
        }
      }
    } onCancel: {
      cancellationContinuation.yield()
    }
  }

  #expect(seen == [0])
  var startIterator = starts.makeAsyncIterator()
  guard await startIterator.next() != nil else {
    Issue.record("The owned task never started")
    return
  }

  cogs.commit { c in c[source] = 1 }

  // Cancellation completed inside the flush without re-entrancy trouble: the
  // canceller registered first, so the sibling watch was already cancelled
  // when its turn in the same flush came — it never saw 1 — and the app's
  // state is untouched.
  #expect(seen == [0])
  #expect(cogs.peek(source) == 1)

  var cancellationIterator = cancellations.makeAsyncIterator()
  guard await cancellationIterator.next() != nil else {
    Issue.record("The owned task was never cancelled")
    return
  }
  suspension.continuation?.resume()
  suspension.continuation = nil

  // The group is terminal: a later turn wakes nothing it owned.
  cogs.commit { c in c[source] = 2 }
  #expect(seen == [0])
  withExtendedLifetime(group) {}
}
