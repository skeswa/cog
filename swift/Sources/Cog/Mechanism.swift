/// One bundled family of side effects, registered at assembly.
///
/// A mechanism watches cogs and performs work outside the graph: alerts,
/// haptics, logs, files, system services. It bundles the dependencies that
/// work needs — services, clocks, notifiers — with the reactions and tasks
/// that use them, and it is the only place reactions and tasks exist (§6.2).
///
/// Structs and classes both conform; dependencies are ordinary stored
/// properties. A struct fits a stateless mechanism, while a class fits one
/// that owns a connection or other reference-typed resource. The runtime
/// retains the exact mechanism values supplied at assembly alongside their
/// registration scopes, cancels every scope during teardown first, and
/// releases the retained mechanism values only afterward, so a class-owned
/// resource cannot disappear while one of its reactions or tasks is still
/// registered.
///
/// ```swift
/// struct WeatherMechanism: Mechanism {
///   let notifier: Notifier
///
///   func operate(_ m: MechanismController) {
///     m.watch(isNiceOutsideHereCog, initial: .skip, name: "niceAlert") { was, nice in
///       if nice && !was { notifier.alert("It is nice outside!") }
///     }
///   }
/// }
/// ```
///
/// Mechanisms are specified only at `Cogs.assemble(mechanisms:)` — or the
/// `CogTesting` factory's matching parameter — and each `operate` runs
/// synchronously in array order before assembly returns. Declaring a
/// mechanism does nothing by itself; a mechanism left off the assembly list
/// never runs (§6.3).
@MainActor
public protocol Mechanism {
  /// Names this mechanism in debug history, task names, and diagnostics.
  ///
  /// Registration names compose beneath it — a task named `hourlyRefresh` in
  /// a mechanism named `Weather` appears as `Weather.hourlyRefresh` — and a
  /// turn an op opens through the mechanism's controller records this name.
  /// Assembly rejects two mechanisms that share a name, in debug and release
  /// builds, because attribution depends on the name being unambiguous.
  ///
  /// Defaults to the conforming type's name with a trailing "Mechanism"
  /// dropped.
  var name: String { get }

  /// Registers this mechanism's reactions, tasks, and gated scopes.
  ///
  /// Called exactly once, during assembly, in array order. The controller is
  /// the mechanism's entire relationship with the graph: registration, gated
  /// `whenever` scopes, untracked reads, and the shared ``CogOps`` op
  /// surface. Writes made here run as ordinary named turns and settle
  /// before assembly returns, so a later mechanism observes the result.
  ///
  /// `operate` is registration, not a reaction: reads made directly here
  /// never become dependencies, and the body never reruns. Watch the graph
  /// through `m.watch`, `m.run`, or `m.whenever` for anything that should
  /// respond to later turns.
  func operate(_ m: MechanismController)
}

extension Mechanism {
  /// The type's name with a trailing "Mechanism" dropped.
  ///
  /// `WeatherMechanism` is known as `Weather`. A type not following the
  /// naming convention keeps its full type name; a type named exactly
  /// `Mechanism` would compose empty names, so it also keeps the full
  /// spelling.
  public var name: String {
    let typeName = String(describing: Self.self)
    let suffix = "Mechanism"
    guard typeName.hasSuffix(suffix), typeName.count > suffix.count else {
      return typeName
    }
    return String(typeName.dropLast(suffix.count))
  }
}
