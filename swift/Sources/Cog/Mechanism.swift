/// One bundled family of side effects, registered at assembly.
///
/// A mechanism watches cogs and performs work outside the graph, such as
/// alerts, logs, file writes, or system calls. It owns the services and clocks
/// used by its reactions and tasks. App-wide reactions and tasks live only in
/// mechanisms (§6.2).
///
/// Dependencies are normal stored properties. Use a struct for a stateless
/// mechanism or a class for one that owns a connection or similar resource.
/// The runtime retains each mechanism until its registration scope has been
/// cancelled, so class-owned resources outlive their last task or reaction.
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
/// List mechanisms in `Cogs.assemble(mechanisms:)` or the matching `CogTesting`
/// factory parameter. Each `operate` runs in list order before assembly returns.
/// A mechanism left out of the list never runs (§6.3).
@MainActor
public protocol Mechanism {
  /// Names this mechanism in debug history, task names, and diagnostics.
  ///
  /// Registration names build on it. A task named `hourlyRefresh` in `Weather`
  /// appears as `Weather.hourlyRefresh`, and turns opened by this mechanism also
  /// record its name.
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
