import Cog
import CogTesting

/// A test mechanism whose `operate` is supplied by the test.
///
/// Registration is a controller capability, so scenario proofs that need
/// assembly-time registrations — or several distinctly named probes — assemble
/// one of these and register inside the closure. A proof that only needs one
/// controller after assembly uses `Cogs.forTestingWithController()` from
/// `CogTesting` instead.
///
/// The default name is `Probe`; tests that assemble several probes pass
/// distinct names because assembly enforces uniqueness.
@MainActor
struct MechanismProbe: Mechanism {
  /// The unique assembly name for this probe.
  let name: String

  /// The registrations this probe makes, run once at assembly.
  let body: @MainActor (MechanismController) -> Void

  init(name: String = "Probe", _ body: @escaping @MainActor (MechanismController) -> Void) {
    self.name = name
    self.body = body
  }

  func operate(_ m: MechanismController) {
    body(m)
  }
}
