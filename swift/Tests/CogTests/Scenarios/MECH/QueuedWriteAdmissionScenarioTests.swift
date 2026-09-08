import Cog
import CogTesting
import Testing

// A controller's turn that arrives during a flush waits in the ordinary FIFO.
// What happens to it depends on where the replacement sits in that same queue,
// and on nothing else: order is never rearranged to favor a replacement.

/// A session lifetime whose replacement retires the previous child.
private struct Epoch: Equatable {
  let value: Int
}

@MainActor private let _epochCog = Cog<Epoch?>.Manual({ Epoch(value: 1) }, name: "epoch")
@MainActor private let _ledgerCog = Cog<[String]>.Manual({ [] }, name: "ledger")
@MainActor private let _triggerCog = Cog<Int>.Manual({ 0 }, name: "trigger")

/// Counts writer bodies that actually executed, rejected ones included nowhere.
@MainActor private var writerBodyRuns = 0

extension CogOps {
  /// Appends one entry, counting the writer body so rejection is visible.
  fileprivate func appendLedger(_ entry: String) {
    turn("appendLedger") { c in
      writerBodyRuns += 1
      c[_ledgerCog] = c[_ledgerCog] + [entry]
    }
  }

  /// Replaces the session epoch, retiring whichever child selected the old one.
  fileprivate func replaceEpoch(with epoch: Epoch) {
    turn("replaceEpoch") { c in c[_epochCog] = epoch }
  }
}

@MainActor
@Test func `MECH-29 a queued child write is rejected once its scope is retired`() {
  writerBodyRuns = 0
  // Each isolated runtime gives these file-scope declarations their own fresh
  // states, so no setup is needed beyond the declarations' starting values.
  let (cogs, m) = Cogs.forTestingWithController()

  // Registration order is FIFO order for the turns these reactions request.
  // The replacement is registered first, so it drains first.
  m.run { c in
    guard c[_triggerCog] == 1 else { return }
    cogs.replaceEpoch(with: Epoch(value: 2))
  }
  m.scope(_epochCog, name: "session") { epoch, s in
    // `.skip` so that a replacement child, which registers during the very
    // flush being examined, does not append an entry of its own. Anything in
    // the ledger afterward came from a child that was already open.
    s.watch(_triggerCog, initial: .skip, name: "ledger") { _, trigger in
      guard trigger == 1 else { return }
      s.appendLedger("epoch\(epoch.value)")
    }
  }

  cogs.turn("wake both") { c in c[_triggerCog] = 1 }

  // The replacement ran and retired session 1. Session 1's write reached its
  // execution point afterward and was discarded: no entry, and its writer body
  // never ran at all.
  #expect(cogs.peek(_epochCog) == Epoch(value: 2))
  #expect(cogs.peek(_ledgerCog).isEmpty)
  #expect(writerBodyRuns == 0)

  // Rejection happens before the turn starts, so it produced no turn in
  // history — not an empty one — and therefore no revision of its own.
  #if DEBUG
  let turns = cogs.debugHistory.entries.filter { $0.event == .turn }.map(\.name)
  #expect(turns.contains("replaceEpoch"))
  #expect(!turns.contains { $0.hasSuffix("appendLedger") })
  #endif
}

@MainActor
@Test func `MECH-29 an earlier queued child write stays valid after retirement`() {
  writerBodyRuns = 0
  // Each isolated runtime gives these file-scope declarations their own fresh
  // states, so no setup is needed beyond the declarations' starting values.
  let (cogs, m) = Cogs.forTestingWithController()

  // The reverse FIFO order: the child's write is queued before the replacement.
  m.scope(_epochCog, name: "session") { epoch, s in
    // `.skip` so that a replacement child, which registers during the very
    // flush being examined, does not append an entry of its own. Anything in
    // the ledger afterward came from a child that was already open.
    s.watch(_triggerCog, initial: .skip, name: "ledger") { _, trigger in
      guard trigger == 1 else { return }
      s.appendLedger("epoch\(epoch.value)")
    }
  }
  m.run { c in
    guard c[_triggerCog] == 1 else { return }
    cogs.replaceEpoch(with: Epoch(value: 2))
  }

  cogs.turn("wake both") { c in c[_triggerCog] = 1 }

  // The child's write executed before its scope was retired. Retirement is not
  // a retroactive rollback, so the entry stands.
  #expect(cogs.peek(_ledgerCog) == ["epoch1"])
  #expect(writerBodyRuns == 1)
  #expect(cogs.peek(_epochCog) == Epoch(value: 2))
}

@MainActor
@Test func `MECH-29 admission checks the scope instance rather than the identity`() {
  writerBodyRuns = 0
  // Each isolated runtime gives these file-scope declarations their own fresh
  // states, so no setup is needed beyond the declarations' starting values.
  let (cogs, m) = Cogs.forTestingWithController()

  // The replacement turn puts the *same domain identity* back. Matching the
  // selected identity would therefore admit the retired child's write; only the
  // exact scope instance tells the two lifetimes apart.
  m.run { c in
    guard c[_triggerCog] == 1 else { return }
    cogs.replaceEpoch(with: Epoch(value: 2))
    cogs.replaceEpoch(with: Epoch(value: 1))
  }
  m.scope(_epochCog, name: "session") { epoch, s in
    // `.skip` so that a replacement child, which registers during the very
    // flush being examined, does not append an entry of its own. Anything in
    // the ledger afterward came from a child that was already open.
    s.watch(_triggerCog, initial: .skip, name: "ledger") { _, trigger in
      guard trigger == 1 else { return }
      s.appendLedger("epoch\(epoch.value)")
    }
  }

  cogs.turn("wake both") { c in c[_triggerCog] = 1 }

  #expect(cogs.peek(_epochCog) == Epoch(value: 1))
  #expect(cogs.peek(_ledgerCog).isEmpty)
  #expect(writerBodyRuns == 0)
}
