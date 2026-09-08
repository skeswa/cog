// scenario: MECH-36
//
// `whenever` was removed outright when `scope` became the sole public name for
// a mechanism-owned lifetime. There is no deprecated alias, forwarding wrapper,
// or renamed availability stub, so every former overload — automatic, manual,
// and read-only projection — fails to compile rather than quietly forwarding.
// The migration is a rename: `m.whenever(gate) { s in ... }` becomes
// `m.scope(gate) { s in ... }`, with the same parameters and closure shape.

import Cog

enum WheneverRemovedFromController {
  static func automaticGate(m: MechanismController, gate: Cog<Bool>) {
    // expect-error: value of type 'MechanismController' has no member 'whenever'
    m.whenever(gate) { _ in }
  }

  static func manualGate(m: MechanismController, gate: Cog<Bool>.Manual) {
    // expect-error: value of type 'MechanismController' has no member 'whenever'
    m.whenever(gate, name: "session") { _ in }
  }

  static func projectedGate(m: MechanismController, gate: Cog<Bool>.Projection) {
    // expect-error: value of type 'MechanismController' has no member 'whenever'
    m.whenever(gate, name: "session") { _ in }
  }
}
