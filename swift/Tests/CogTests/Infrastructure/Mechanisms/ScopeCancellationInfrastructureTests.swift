import CogTesting
import Testing

@testable import Cog

// MARK: - Scope cancellation infrastructure
//
// These infrastructure tests cover terminal, idempotent scope cancellation.
// A scope unregisters once. A new registration on a cancelled scope is
// cancelled at once and not retained. Nothing can reopen the scope.
//
// Two layers are deliberately distinguished. `MechanismScope.add` is the
// terminal ownership defense: by the time a finished token reaches it, its
// initial tracking run has already happened, and `add` can only refuse to keep
// it. `MechanismController.register` is the capability check, and it runs
// earlier — before the registration is built — which is what keeps a retired
// scope from executing application code once on its way to being rejected.

@MainActor
@Test func `ScopeCancellationInfrastructure cancel unregisters reactions exactly once`() {
  let cogs = Cogs.forTesting()
  let source = Cog<Int>.Manual { 0 }
  var runs = 0

  let scope = MechanismScope()
  scope.add(
    cogs.register(label: CogLabel(name: nil, fileID: #fileID, line: #line)) { c in
      _ = c[source]
      runs += 1
    }
  )
  #expect(runs == 1)

  scope.cancel()
  cogs.turn { c in c[source] = 1 }
  #expect(runs == 1)
  #expect(cogs.reactions.isEmpty)

  // Repeated cancellation does nothing.
  scope.cancel()
  #expect(cogs.reactions.isEmpty)
}

@MainActor
@Test func `ScopeCancellationInfrastructure a late registration is cancelled synchronously`() {
  let cogs = Cogs.forTesting()
  let source = Cog<Int>.Manual { 0 }
  var runs = 0

  let scope = MechanismScope()
  scope.cancel()

  // Registration still performs its initial tracking run before the terminal
  // scope cancels it; nothing reopens the scope and nothing is retained.
  let token = cogs.register(
    label: CogLabel(name: nil, fileID: #fileID, line: #line)
  ) { c in
    _ = c[source]
    runs += 1
  }
  scope.add(token)
  #expect(runs == 1)
  #expect(token.reaction.isCancelled)

  cogs.turn { c in c[source] = 1 }
  #expect(runs == 1)
  #expect(cogs.reactions.isEmpty)
}

@MainActor
@Test func `ScopeCancellationInfrastructure a cancelled parent sweeps adopted children`() {
  let cogs = Cogs.forTesting()
  let source = Cog<Int>.Manual { 0 }
  var childRuns = 0

  let parent = MechanismScope()
  let child = MechanismScope()
  child.add(
    cogs.register(label: CogLabel(name: nil, fileID: #fileID, line: #line)) { c in
      _ = c[source]
      childRuns += 1
    }
  )
  parent.adopt(child: child)

  parent.cancel()
  cogs.turn { c in c[source] = 1 }
  #expect(childRuns == 1)

  // A child handed to an already-cancelled parent is cancelled on arrival.
  let lateChild = MechanismScope()
  var lateRuns = 0
  lateChild.add(
    cogs.register(label: CogLabel(name: nil, fileID: #fileID, line: #line)) { c in
      _ = c[source]
      lateRuns += 1
    }
  )
  parent.adopt(child: lateChild)
  cogs.turn { c in c[source] = 2 }
  #expect(lateRuns == 1)
}

@MainActor
@Test func `ScopeCancellationInfrastructure revocation reaches descendants before teardown`() {
  // `cancel` marks the whole subtree retired before it releases anything, so a
  // grandchild answers "retired" from the first moment its ancestor starts,
  // rather than at whatever point the walk happens to reach it.
  let parent = MechanismScope()
  let child = MechanismScope()
  let grandchild = MechanismScope()
  child.adopt(child: grandchild)
  parent.adopt(child: child)

  #expect(!grandchild.isRetired)
  parent.revoke()
  #expect(parent.isRetired)
  #expect(child.isRetired)
  #expect(grandchild.isRetired)

  // Revocation alone releases nothing, and the teardown that follows still
  // happens exactly once.
  parent.cancel()
  parent.cancel()
  #expect(grandchild.isRetired)
}

@MainActor
@Test func `ScopeCancellationInfrastructure a retired controller registers nothing at all`() {
  // The controller-level guard, contrasted with the `add`-level one above: no
  // registration is constructed, so no baseline read and no initial body run
  // happen before the rejection.
  let cogs = Cogs.forTesting()
  let source = Cog<Int>.Manual { 0 }
  var runs = 0

  let scope = MechanismScope()
  let controller = MechanismController(cogs: cogs, namePath: "Probe", scope: scope)
  scope.retain(controller: controller)
  scope.cancel()

  controller.run { c in
    _ = c[source]
    runs += 1
  }
  #expect(runs == 0)
  #expect(cogs.reactions.isEmpty)
}
