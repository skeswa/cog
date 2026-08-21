import Cog
import CogTesting
import Testing

@MainActor
@Test func `MECH-11 one turn may wake a scoped reaction and lower its own gate`() async {
  // The scope's teardown replaces a reaction run in the ordinary flush order:
  // the gate watch registered first, so it runs first, and the woken sibling
  // reaction inside the scope never runs after teardown even though the same
  // turn changed its dependency.
  let scopeOpen = ManualCog<Bool>(true)
  let dependency = ManualCog<Int>(0)
  var scopedSeen: [Int] = []
  let (taskStarts, taskStartContinuation) = AsyncStream.makeStream(of: Void.self)
  let (cancellations, cancellationContinuation) = AsyncStream.makeStream(of: Void.self)
  let (holds, holdContinuation) = AsyncStream.makeStream(of: Void.self)

  let cogs = Cogs.forTesting(mechanisms: [
    MechanismProbe { m in
      m.whenever(scopeOpen, name: "scoped") { s in
        s.run { c in scopedSeen.append(c[dependency]) }
        s.task(name: "held") {
          taskStartContinuation.yield()
          var iterator = holds.makeAsyncIterator()
          _ = await iterator.next()
          cancellationContinuation.yield()
        }
      }
    }
  ])
  #expect(scopedSeen == [0])

  // The task is running before the teardown turn, so the cancellation below
  // is a definite later signal rather than a startup race.
  var startIterator = taskStarts.makeAsyncIterator()
  _ = await startIterator.next()

  cogs.turn("drop gate while changing the dependency") { c in
    c[dependency] = 1
    c[scopeOpen] = false
  }

  // Teardown completed safely mid-flush: the sibling reaction never saw the
  // change that woke it, every owned task received cancellation, and the
  // app's state is untouched.
  #expect(scopedSeen == [0])
  var cancellationIterator = cancellations.makeAsyncIterator()
  _ = await cancellationIterator.next()
  #expect(cogs.peek(dependency) == 1)
  #expect(cogs.peek(scopeOpen) == false)

  cogs.turn { c in c[dependency] = 2 }
  #expect(scopedSeen == [0])
  _ = holdContinuation
}
