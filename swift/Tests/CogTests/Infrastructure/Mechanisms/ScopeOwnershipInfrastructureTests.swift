import CogTesting
import Testing

@testable import Cog

// MARK: - Scope ownership accounting
//
// Exact registration counts, which are representation facts rather than public
// promises. The scenario proofs assert behavior; these assert that the behavior
// is achieved without accumulating registrations behind it.

/// One presentation entry identity for the reconciliation counts below.
private struct EntryID: Hashable {
  let value: Int
}

@MainActor
@Test func `ScopeOwnershipInfrastructure replacement leaves one selector and one child`() {
  let cogs = Cogs.forTesting()
  let session = Cog<Int?>.Manual { nil }
  let scope = MechanismScope()
  let controller = MechanismController(cogs: cogs, namePath: "Probe", scope: scope)
  scope.retain(controller: controller)

  controller.scope(session, name: "session") { _, s in
    s.run { _ in }
  }

  // One selector registration, no child yet.
  #expect(cogs.reactions.count == 1)

  // Fifty replacements in a row. Each retires the previous child before opening
  // the next, so the steady-state count is the selector plus one child.
  for value in 1...50 {
    cogs.turn(session, to: value)
    #expect(cogs.reactions.count == 2)
  }

  // Closing the lifetime leaves only the selector.
  cogs.turn(session, to: nil)
  #expect(cogs.reactions.count == 1)

  // Retiring the owning scope leaves nothing at all.
  scope.cancel()
  #expect(cogs.reactions.isEmpty)
}

@MainActor
@Test func `ScopeOwnershipInfrastructure a collection scope never accumulates selectors`() {
  let cogs = Cogs.forTesting()
  let entries = Cog<[EntryID]>.Manual { [] }
  let scope = MechanismScope()
  let controller = MechanismController(cogs: cogs, namePath: "Probe", scope: scope)
  scope.retain(controller: controller)

  controller.scope(each: entries, name: "entry") { _, s in
    s.run { _ in }
    s.run { _ in }
  }
  #expect(cogs.reactions.count == 1)

  // Membership grows: one selector plus two registrations per live entry.
  cogs.turn(entries, to: (1...5).map(EntryID.init))
  #expect(cogs.reactions.count == 1 + 5 * 2)

  // Reordering is not a membership change, so nothing is torn down or rebuilt.
  cogs.turn(entries, to: (1...5).map(EntryID.init).reversed())
  #expect(cogs.reactions.count == 1 + 5 * 2)

  // Two hundred push-and-remove cycles return the count to the one selector,
  // which is the accumulation question a per-entry selector could not answer.
  for value in 100..<300 {
    cogs.turn(entries, to: [EntryID(value: value)])
    cogs.turn(entries, to: [])
  }
  #expect(cogs.reactions.count == 1)

  scope.cancel()
  #expect(cogs.reactions.isEmpty)
}

@MainActor
@Test func `ScopeOwnershipInfrastructure survivors keep their exact child scope`() {
  // Reconciliation preserves instances, not just identities: an entry that
  // stays present across a membership change keeps the same registration
  // objects, which is what "no restart" means at this layer.
  let cogs = Cogs.forTesting()
  let entries = Cog<[EntryID]>.Manual { [EntryID(value: 1)] }
  let scope = MechanismScope()
  let controller = MechanismController(cogs: cogs, namePath: "Probe", scope: scope)
  scope.retain(controller: controller)

  var registered: [EntryID: CogReaction] = [:]
  controller.scope(each: entries, name: "entry") { id, s in
    s.run { _ in }
    registered[id] = cogs.reactions.last
  }

  let first = try! #require(registered[EntryID(value: 1)])
  cogs.turn(entries, to: [EntryID(value: 2), EntryID(value: 1), EntryID(value: 3)])

  #expect(registered[EntryID(value: 1)] === first)
  #expect(!first.isCancelled)
  #expect(cogs.reactions.contains { $0 === first })

  // Removing the survivor cancels that exact registration.
  cogs.turn(entries, to: [EntryID(value: 2)])
  #expect(first.isCancelled)
  #expect(!cogs.reactions.contains { $0 === first })
}
