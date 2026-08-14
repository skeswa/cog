import Cog
import CogTesting

/// A test mechanism whose `operate` is supplied by the test.
///
/// Registration is a controller capability, so scenario proofs that need a
/// reaction, watch, task, or gated scope bootstrap one of these and register
/// inside the closure — or capture the controller for use after bootstrap,
/// which stays legitimate because the runtime's scope retains the controller
/// for the app (here: test) lifetime:
///
/// ```swift
/// var m: MechanismController!
/// let cogs = Cogs.forTesting(mechanisms: [MechanismProbe { m = $0 }])
/// m.run { c in ... }
/// ```
///
/// The default name is `Probe`; tests that bootstrap several probes pass
/// distinct names because bootstrap enforces uniqueness.
@MainActor
struct MechanismProbe: Mechanism {
  /// The unique bootstrap name for this probe.
  let name: String

  /// The registrations this probe makes, run once at bootstrap.
  let body: @MainActor (MechanismController) -> Void

  init(name: String = "Probe", _ body: @escaping @MainActor (MechanismController) -> Void) {
    self.name = name
    self.body = body
  }

  func operate(_ m: MechanismController) {
    body(m)
  }
}

/// An isolated context bootstrapped with one probe whose controller the test
/// keeps.
///
/// Scenario proofs that need a registration mid-story use the returned
/// controller; the runtime's scope retains it for the whole isolated-context
/// lifetime, so holding it here mirrors an app-lifetime mechanism exactly.
@MainActor
func probedContext(
  clock: any Clock<Duration> = ContinuousClock(),
  whileObservedGrace: Duration = .seconds(30),
  seeding: ((Cogs) -> Void)? = nil
) -> (cogs: Cogs, m: MechanismController) {
  var m: MechanismController!
  let cogs = Cogs.forTesting(
    clock: clock,
    whileObservedGrace: whileObservedGrace,
    seeding: seeding,
    mechanisms: [MechanismProbe { m = $0 }]
  )
  return (cogs, m)
}
