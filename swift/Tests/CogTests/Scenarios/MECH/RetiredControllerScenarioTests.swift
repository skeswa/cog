import Cog
import CogTesting
import Testing

// What a retained controller can and cannot do after its scope is retired. Each
// proof holds the old controller strongly, which is precisely the case a weak
// capture does not cover.

/// A workflow lifetime whose replacement retires the previous controller.
private struct Workflow: Equatable {
  let id: Int
}

@MainActor private let _workflowCog = Cog<Workflow?>.Manual { Workflow(id: 1) }
@MainActor private let _writtenCog = Cog<Int>.Manual { 0 }
@MainActor private let _watchedCog = Cog<Int>.Manual { 0 }

extension CogOps {
  /// A named op whose whole body is one primitive, so inertness is visible.
  fileprivate func recordWorkflowResult(_ value: Int) {
    turn(_writtenCog, to: value)
  }
}

@MainActor
@Test func `MECH-25 a retained retired controller cannot write or register`() async {
  var retired: MechanismController?
  var lateRuns = 0
  var lateTaskRuns = 0
  var lateStatusRuns = 0

  let cogs = Cogs.forTesting(mechanisms: [
    MechanismProbe { m in
      m.scope(_workflowCog, name: "workflow") { workflow, s in
        if workflow.id == 1 { retired = s }
      }
    }
  ])
  let controller = try! #require(retired)

  // Replace the workflow. The controller above is now retired but still
  // strongly held by this test, and so is its status lens.
  let lens = controller.status
  cogs.turn(_workflowCog, to: Workflow(id: 2))

  // Writes are inert. The op runs — it is an ordinary Swift method — but its
  // primitive does nothing.
  controller.recordWorkflowResult(9)
  #expect(cogs.peek(_writtenCog) == 0)

  // Registrations are inert *before* they can run user code: no baseline read,
  // no initial callback, no lease.
  controller.run { _ in lateRuns += 1 }
  controller.watch(_watchedCog, initial: .run, name: "late") { _, _ in lateRuns += 1 }
  lens.watch(lateForecastCog, initial: .run, name: "lateStatus") { _, _ in
    lateStatusRuns += 1
  }
  #expect(lateRuns == 0)
  #expect(lateStatusRuns == 0)

  // A later turn does not wake anything either, because nothing registered.
  cogs.turn(_watchedCog, to: 1)
  #expect(lateRuns == 0)

  // A task is returned so the signature holds, but it is already cancelled and
  // its operation never starts.
  let task = controller.task(name: "late") { @MainActor in lateTaskRuns += 1 }
  _ = await task.result
  #expect(task.isCancelled)
  #expect(lateTaskRuns == 0)

  // A nested scope registration is inert too: its selector is never read and
  // its body never runs.
  var nestedOpenings = 0
  controller.scope(_workflowCog, name: "nested") { _, _ in nestedOpenings += 1 }
  controller.scope(alwaysTrueCog, name: "nestedGate") { _ in nestedOpenings += 1 }
  #expect(nestedOpenings == 0)
}

/// A cog that is always true, used to prove an inert Boolean registration.
@MainActor private let alwaysTrueCog = Cog<Bool> { _ in true }

/// An async declaration for the retired status-lens registration above.
///
/// Its work never starts in these proofs: every registration that names it is
/// made through a controller that is already retired.
@MainActor private let lateForecastCog = Cog<Int>.Async(default: 0, name: "lateForecast") { _ in
  .run { 1 }
}

@MainActor
@Test func `MECH-27 ifLive reads while live and returns nil once retired`() {
  var retired: MechanismController?
  let cogs = Cogs.forTesting(mechanisms: [
    MechanismProbe { m in
      m.scope(_workflowCog, name: "workflow") { workflow, s in
        if workflow.id == 1 { retired = s }
      }
    }
  ])
  let controller = try! #require(retired)

  // While live, `ifLive` is a plain guarded read.
  #expect(controller.ifLive { $0.peek(_watchedCog) } == 0)

  cogs.turn(_workflowCog, to: Workflow(id: 2))

  // Once retired it answers nil instead of trapping, which is what lets an
  // ordinary late completion terminate harmlessly.
  #expect(controller.ifLive { $0.peek(_watchedCog) } == nil)
  #expect(controller.ifLive { $0.status.peek(lateForecastCog).isLoading } == nil)
}

@MainActor
@Test func `MECH-27 ifLive is how a late completion asks for follow-up demand`() async {
  // The other read a stale completion genuinely needs: not "what is the value"
  // but "please load again". A live scope starts the generation and hands back
  // its real handle; a retired one answers nil, so the completion returns
  // instead of trapping or fabricating an outcome.
  let work = ControlledWork<Int>()
  let forecast = Cog<Int>.Async(default: 0, name: "followUp") { _ in work.makeWork() }
  var retired: MechanismController?
  let cogs = Cogs.forTesting(mechanisms: [
    MechanismProbe { m in
      m.scope(_workflowCog, name: "workflow") { workflow, s in
        if workflow.id == 1 { retired = s }
      }
    }
  ])
  let controller = try! #require(retired)

  let handle = controller.ifLive { $0.refresh(forecast) }
  #expect(handle != nil)
  var starts = work.starts.makeAsyncIterator()
  #expect(await starts.next() == 0)
  work.succeed(0, with: 21)
  guard case .success(let value)? = await handle?.outcome else {
    Issue.record("expected the live refresh to report its real outcome")
    return
  }
  #expect(value == 21)

  cogs.turn(_workflowCog, to: Workflow(id: 2))

  // Retired: no new generation is started, and the caller gets nil rather than
  // a fabricated outcome about state it no longer owns.
  #expect(controller.ifLive { $0.refresh(forecast) } == nil)
  #expect(cogs.peek(forecast) == 21)
}

@MainActor
@Test func `MECH-27 ifLive reserves nothing across a turn inside its own body`() async {
  // A live scope whose body retires itself mid-way. `ifLive` checked once, at
  // entry; it is not a lease on the rest of the closure, and the primitives
  // after the turn are the authority.
  var controller: MechanismController?
  let cogs = Cogs.forTesting(mechanisms: [
    MechanismProbe { m in
      m.scope(_workflowCog, name: "workflow") { workflow, s in
        if workflow.id == 1 { controller = s }
      }
    }
  ])
  let live = try! #require(controller)

  let result = live.ifLive { s -> Int in
    // Still live here.
    let before = s.peek(_watchedCog)
    // This op retires this very scope by replacing the identity it selected.
    s.retireThisWorkflow()
    // The scope is retired now, so this write is inert even though the
    // enclosing `ifLive` already decided the scope was live.
    s.recordWorkflowResult(before + 5)
    return before
  }
  #expect(result == 0)
  #expect(cogs.peek(_writtenCog) == 0)
}

extension CogOps {
  /// Replaces the workflow identity, retiring whichever scope selected it.
  fileprivate func retireThisWorkflow() {
    turn(_workflowCog, to: nil)
  }
}

@MainActor
@Test func `MECH-30 a registration body that retires its own scope keeps nothing`() {
  // The scope body ends its own lifetime while it is still initializing. Cog
  // cannot unwind an executing Swift frame, so the remaining statements run —
  // but every primitive after the retirement observes it, and no registration
  // made afterward survives.
  var runsAfterSelfRetirement = 0
  var seen: [Int] = []

  let cogs = Cogs.forTesting(mechanisms: [
    MechanismProbe { m in
      m.scope(_workflowCog, name: "workflow") { _, s in
        s.run { c in seen.append(c[_watchedCog]) }
        s.retireThisWorkflow()

        // Everything below is inside a scope that is already retired.
        s.run { _ in runsAfterSelfRetirement += 1 }
        s.recordWorkflowResult(3)
      }
    }
  ])

  // The registration made before the self-retirement ran once, as ordinary
  // registration does; the ones made after it never ran at all.
  #expect(seen == [0])
  #expect(runsAfterSelfRetirement == 0)
  #expect(cogs.peek(_writtenCog) == 0)

  // Neither registration survives: a later turn wakes nothing.
  cogs.turn(_watchedCog, to: 1)
  #expect(seen == [0])
  #expect(runsAfterSelfRetirement == 0)
}

/// Runs application code exactly when a torn-down scope releases its closures.
///
/// This is the released-capture case the retirement contract has to cover.
/// Cancelling a reaction drops its body, which drops whatever the body captured,
/// which runs that object's deinitializer — application code, synchronously, in
/// the middle of a subtree teardown that has not finished walking.
@MainActor
private final class TeardownProbe {
  /// What to run when the last reference to this probe goes away.
  private let onRelease: @MainActor () -> Void

  /// Creates a probe owned solely by the closure that captures it.
  init(onRelease: @escaping @MainActor () -> Void) {
    self.onRelease = onRelease
  }

  isolated deinit {
    onRelease()
  }
}

@MainActor
@Test func `MECH-31 a released capture cannot act through a not-yet-torn-down cousin`() {
  // Teardown walks children in order. The first child's cleanup releases its
  // reaction body and therefore runs the deinitializer below, while the second
  // child's own cleanup pass has not been reached yet. Retirement is marked
  // across the whole subtree before any of that walking begins, so the cousin
  // is already inert rather than merely unvisited.
  var lateRegistrations = 0
  var cousinReleased = false
  var cousinReportedLive: Bool?
  var seen: [Int] = []

  let cogs = Cogs.forTesting(mechanisms: [
    MechanismProbe { m in
      m.scope(_workflowCog, name: "workflow") { _, parent in
        var cousin: MechanismController?

        // Registration order is teardown order, so `first` is torn down while
        // `second` is still waiting its turn in the same pass. The closure
        // captures `cousin` by reference, so the probe sees the controller the
        // later registration assigns.
        parent.scope(alwaysTrueCog, name: "first") { first in
          let probe = TeardownProbe {
            cousinReleased = true
            guard let cousin else { return }
            // The direct capability question, answered at the exact moment the
            // cousin's own cleanup pass has not been reached: a read here would
            // return a value if the cousin still had authority.
            cousinReportedLive = cousin.ifLive { _ in true }
            cousin.run { _ in lateRegistrations += 1 }
            cousin.recordWorkflowResult(7)
          }
          first.run { [probe] _ in _ = probe }
        }

        parent.scope(alwaysTrueCog, name: "second") { second in
          cousin = second
          second.run { c in seen.append(c[_watchedCog]) }
        }
      }
    }
  ])
  #expect(seen == [0])

  // Retire the shared ancestor.
  cogs.turn(_workflowCog, to: nil)

  // The deinitializer really did run during teardown, so the assertions below
  // measure inertness rather than an unexecuted path.
  #expect(cousinReleased)
  #expect(cousinReportedLive == nil)
  #expect(lateRegistrations == 0)
  #expect(cogs.peek(_writtenCog) == 0)

  // Nothing it tried to register survived, either.
  cogs.turn(_watchedCog, to: 1)
  #expect(lateRegistrations == 0)
  #expect(seen == [0])
}
